# test-secret-launch.ps1 - harness for the "variant B" launch path: provider keys live
# ONLY in the DPAPI vault and are injected into the child environment at launch time.
#
# Pure PowerShell 5.1 (no Pester). exit 0 = every check PASS, exit 1 = at least one FAIL.
#
# Isolation (see AGENTS.md §11 and tests\test-run-with-secrets.ps1 for the pattern):
#   * every vault used here is a THROWAWAY DPAPI vault under %TEMP% exposed through
#     $env:AGENT_HQ_SECRETS - the real vault (%USERPROFILE%\.agent-secrets) is never read;
#   * the dummy plaintext is assembled at runtime and is never printed: only boolean
#     presence is asserted (a test must not need a secret value);
#   * the "npm shim" is a generated probe inside %TEMP%, injected via $env:APPDATA, so
#     the real opencode CLI is never launched;
#   * the registry part runs against a TEMP key under HKCU\Software\agent-hq-tests\...
#     (user zone); the real HKCU\Environment is only READ - never modified;
#   * child processes are spawned through Wait-Job with a hard timeout, so a regression
#     into infinite recursion cannot hang the suite.
#
# HOST NOTE (corporate AV / AMSI, observed 2026-09-17): Kaspersky's AMSI provider flags
# the profile text (ParserError / ScriptContainedMaliciousContent) whenever a PowerShell
# process executes a script FILE (-File, or `-Command "& '<script>'"`), while an inline
# -Command child loads the profile normally — exactly like an interactive shell. C2/C3
# therefore drive the profile through inline child commands; they still prove the real
# contract (profile function -> vault wrapper -> child env) without depending on AV
# behaviour. The AV issue itself is a host/ИБ matter: it is reported, not worked around.

$ErrorActionPreference = 'Continue'

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Engine   = Join-Path $RepoRoot '.agents\scripts\inbox-engine.ps1'
$Wrapper  = Join-Path $RepoRoot '.agents\scripts\run-with-secrets.ps1'
$ClearEnv = Join-Path $RepoRoot '.agents\scripts\clear-plaintext-env.ps1'
$FakeCli  = Join-Path $Here 'fake-opencode.ps1'
$ScriptsDir = Join-Path $RepoRoot '.agents\scripts'
$ProfilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'

$PlainDummy = 'agent-hq-' + 'probe' + '-plain-value'
$TargetEnvNames = @('AIHUBMIX_API_KEY', 'OPENROUTER_API_KEY', 'TOKENROUTER_API_KEY', 'GROQ_API_KEY', 'OPENCODE_API_KEY')
$EnvRegistryPath = 'HKCU:\Environment'

$TempBase = Join-Path $env:TEMP ('agent-hq-launch-' + [guid]::NewGuid().ToString('N'))
$VaultDir = Join-Path $TempBase 'vault'
$FakeAppData = Join-Path $TempBase 'appdata'
$ProbeShim = Join-Path $FakeAppData 'npm\opencode.ps1'
$ProfileProbeFile = Join-Path $TempBase 'probe-profile.txt'
$EngineProbeFile = Join-Path $TempBase 'probe-engine.txt'
$EngineCallScript = Join-Path $TempBase 'call-engine.ps1'

$script:Results = @()

function Add-Result($id, $pass, $note) {
    $script:Results += [pscustomobject]@{ Id = $id; Pass = [bool]$pass; Note = $note }
    Write-Host ("[{0}] {1} — {2}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $id, $note)
}

function Invoke-Capture($scriptBlock) {
    return (& $scriptBlock *>&1 | Out-String)
}

function Invoke-ChildCommand {
    # Run a command string in a NEW powershell.exe (profile loads, unless -NoProfile is
    # inside the script). Guarded by a hard timeout so a recursion bug cannot hang.
    param([string]$Command, [int]$TimeoutSec = 90)
    $job = Start-Job -ScriptBlock {
        param($cmd)
        $out = & powershell.exe -Command $cmd *>&1 | Out-String
        [pscustomobject]@{ Output = $out; Exit = [int]$LASTEXITCODE }
    } -ArgumentList $Command
    $done = Wait-Job -Job $job -Timeout $TimeoutSec
    $res = $null
    if ($done) { $res = @(Receive-Job -Job $job) | Select-Object -Last 1 }
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($null -eq $res) { return [pscustomobject]@{ Output = ''; Exit = -1; TimedOut = $true } }
    return [pscustomobject]@{ Output = [string]$res.Output; Exit = [int]$res.Exit; TimedOut = $false }
}

function Invoke-ChildScript {
    # Run a child powershell.exe with -File <script> in a background job, capturing
    # stdout+stderr and the real exit code. Guarded by a hard timeout so a regression
    # cannot hang the suite.
    param([string]$ScriptPath, [int]$TimeoutSec = 120)
    $job = Start-Job -ScriptBlock {
        param($path)
        $out = & powershell.exe -ExecutionPolicy Bypass -File $path *>&1 | Out-String
        [pscustomobject]@{ Output = $out; Exit = [int]$LASTEXITCODE }
    } -ArgumentList $ScriptPath
    $done = Wait-Job -Job $job -Timeout $TimeoutSec
    $res = $null
    if ($done) { $res = @(Receive-Job -Job $job) | Select-Object -Last 1 }
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($null -eq $res) { return [pscustomobject]@{ Output = ''; Exit = -1; TimedOut = $true } }
    return [pscustomobject]@{ Output = [string]$res.Output; Exit = [int]$res.Exit; TimedOut = $false }
}

function New-DpapiSecret {
    # Write a real DPAPI-protected vault entry exactly the way set-secret.ps1 does.
    param([string]$Vault, [string]$Name, [string]$Plain)
    Add-Type -AssemblyName System.Security
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        [System.Text.Encoding]::UTF8.GetBytes($Plain), $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes((Join-Path $Vault ('secret.' + $Name + '.enc')), $enc)
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-RegistryValueNames {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    return @($key.GetValueNames())
}

function Get-TargetValueSnapshot {
    # name -> value (user scope = HKCU\Environment), kept in memory only and never
    # printed: used to prove that a dry run did not touch the real user environment.
    $snap = @{}
    foreach ($name in $TargetEnvNames) {
        $snap[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    return $snap
}

function Test-SnapshotEqual {
    param([hashtable]$A, [hashtable]$B)
    foreach ($name in $TargetEnvNames) {
        $va = $A[$name]
        $vb = $B[$name]
        if ($null -eq $va -and $null -eq $vb) { continue }
        if ([string]$va -ne [string]$vb) { return $false }
    }
    return $true
}

$saved = @{
    AGENT_HQ_SECRETS        = $env:AGENT_HQ_SECRETS
    AGENT_HQ_OPENCODE       = $env:AGENT_HQ_OPENCODE
    AGENT_HQ_OPENCODE_PATH  = $env:AGENT_HQ_OPENCODE_PATH
    AGENT_HQ_NO_VAULT       = $env:AGENT_HQ_NO_VAULT
    AGENT_HQ_SCRIPTS_DIR    = $env:AGENT_HQ_SCRIPTS_DIR
    AGENT_HQ_ROOT           = $env:AGENT_HQ_ROOT
    AGENT_HQ_PROBE_FILE     = $env:AGENT_HQ_PROBE_FILE
    AGENT_HQ_PROBE_DEPTH    = $env:AGENT_HQ_PROBE_DEPTH
    APPDATA                 = $env:APPDATA
    FAKE_OPENCODE_MODE      = $env:FAKE_OPENCODE_MODE
}
$TempKey = ''
$TempKeyParent = 'HKCU:\Software\agent-hq-tests'

function Reset-Env {
    foreach ($name in @('AGENT_HQ_ROOT', 'AGENT_HQ_OPENCODE', 'AGENT_HQ_OPENCODE_PATH', 'AGENT_HQ_NO_VAULT',
                        'AGENT_HQ_PROBE_FILE', 'AGENT_HQ_PROBE_DEPTH', 'FAKE_OPENCODE_MODE')) {
        Remove-Item -Path ('Env:\' + $name) -ErrorAction SilentlyContinue
    }
}

try {
    # ---------- setup: throwaway vault + probe "npm shim" + child scripts ----------
    foreach ($dir in @($VaultDir, (Join-Path $FakeAppData 'npm'), $TempBase)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    New-DpapiSecret -Vault $VaultDir -Name 'opencode-api-key' -Plain $PlainDummy

    $shimSrc = @'
# probe stand-in for the npm opencode.ps1 shim: reports boolean env presence only.
$depth = 0
if ($env:AGENT_HQ_PROBE_DEPTH) { $depth = [int]$env:AGENT_HQ_PROBE_DEPTH }
if ($depth -gt 0) {
    Write-Output 'PROBE-RECURSION'
    exit 9
}
$env:AGENT_HQ_PROBE_DEPTH = '1'
$keyPresent = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'Process'))
$hubPresent = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('AIHUBMIX_API_KEY', 'Process'))
$lines = @(
    ('present=' + $keyPresent),
    ('aihubmix=' + $hubPresent),
    ('argv=' + (@($args) -join '|'))
)
if ($env:AGENT_HQ_PROBE_FILE) {
    [System.IO.File]::AppendAllText($env:AGENT_HQ_PROBE_FILE, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}
Write-Output 'PROBE-OK'
Write-Output 'STATUS: resolved'
exit 0
'@
    [System.IO.File]::WriteAllText($ProbeShim, $shimSrc, (New-Object System.Text.UTF8Encoding($true)))

    # The launch under test is handed to the child INLINE (not as a script file):
    # on this host an AMSI/AV heuristic blocks the profile as soon as a child
    # executes any script FILE, while an inline -Command child loads the profile
    # exactly like an interactive shell does (verified: Kaspersky
    # ParserError/ScriptContainedMaliciousContent is raised for -File children and
    # for `-Command "& '<script>'"` children, but not for inline commands).
    $CallCommand = 'opencode run --agent testagent hello'

    $engineCallSrc = @'
$ErrorActionPreference = 'Continue'
. '__ENGINE__'
$r = Invoke-OpencodeAttempt -targetAgent 'testagent' -taskPrompt 'hi' -TaskId 'task-1' -AttemptId 'attempt-1'
Write-Output ('ENGINE-EXIT=' + $r.exitCode)
$flatOut = ([string]$r.stdout).Replace("`r", '').Replace("`n", '|')
$flatErr = ([string]$r.stderr).Replace("`r", '').Replace("`n", '|')
Write-Output ('ENGINE-STDOUT<' + $flatOut + '>')
Write-Output ('ENGINE-STDERR<' + $flatErr + '>')
'@
    [System.IO.File]::WriteAllText($EngineCallScript, ($engineCallSrc.Replace('__ENGINE__', $Engine)), (New-Object System.Text.UTF8Encoding($true)))

    # ---------- C1: profile file integrity -------------------------------------
    $profileExists = Test-Path -LiteralPath $ProfilePath -PathType Leaf
    if (-not $profileExists) {
        Add-Result 'C1-profile-file' $false ("profile missing: " + $ProfilePath)
    } else {
        $raw = Get-Content -Raw -LiteralPath $ProfilePath
        $perrs = $null
        [void][System.Management.Automation.PSParser]::Tokenize($raw, [ref]$perrs)
        $bytes = [System.IO.File]::ReadAllBytes($ProfilePath)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
        $crlf = ([regex]::Matches($raw, "`r`n")).Count
        $lf = ([regex]::Matches($raw, "`n")).Count
        $ok = ($null -eq $perrs -or @($perrs).Count -eq 0) -and $bom -and ($crlf -eq $lf) -and
              ($raw -match 'function global:opencode') -and
              ($raw -match 'run-with-secrets\.ps1') -and
              ($raw -match 'npm\\opencode\.ps1') -and
              ($raw -match 'Set-Alias') -and
              ($raw -match 'D:\\Тест\\agent-hq\\\.agents\\scripts')
        Add-Result 'C1-profile-file' $ok ("exists=$profileExists syntaxErr=$(@($perrs).Count) bom=$bom crlf=$crlf lf=$lf fn=$($raw -match 'function global:opencode') path=$($raw -match 'D:\\Тест\\agent-hq')")
    }

    # ---------- C2: new process resolves opencode as a Function (no recursion) ---
    # The command string uses single quotes ONLY: when a string with embedded double
    # quotes is handed to powershell.exe -Command from PowerShell 5.1, the native
    # argument escaping mangles it and the child prints the literal text instead of
    # evaluating it (observed: type='$($f.CommandType)').
    $cmd = '$f = Get-Command opencode -ErrorAction SilentlyContinue; ' +
           '$a = Get-Command oc -ErrorAction SilentlyContinue; ' +
           '''OPENCODE_TYPE='' + $f.CommandType; ''OC_TYPE='' + $a.CommandType; ''OC_DEF='' + $a.Definition'
    $c2 = Invoke-ChildCommand -Command $cmd -TimeoutSec 90
    $ok2 = (-not $c2.TimedOut) -and ($c2.Exit -eq 0) -and
           ($c2.Output -match 'OPENCODE_TYPE=Function') -and
           ($c2.Output -match 'OC_TYPE=Alias') -and
           ($c2.Output -match 'OC_DEF=opencode')
    $t2 = ([regex]::Match($c2.Output, 'OPENCODE_TYPE=(\S*)')).Groups[1].Value
    Add-Result 'C2-newprocess-function' $ok2 ("exit=$($c2.Exit) type='$t2' timeout=$($c2.TimedOut)")

    if ($profileExists) {
        # ---------- C3: profile launch -> wrapper -> shim: env injected, NO recursion --
        if (Test-Path -LiteralPath $ProfileProbeFile) { Remove-Item -LiteralPath $ProfileProbeFile -Force }
        Reset-Env
        $env:APPDATA = $FakeAppData
        $env:AGENT_HQ_SECRETS = $VaultDir
        $env:AGENT_HQ_SCRIPTS_DIR = $ScriptsDir
        $env:AGENT_HQ_PROBE_FILE = $ProfileProbeFile
        # Inline child = interactive-equivalent launch (profile startup + function +
        # vault wrapper + probe shim). A `-File` child would not load this profile on
        # this host (AV/AMSI blocks profile execution as soon as a script FILE is
        # executed) and would silently fall back to the raw npm shim. See the header
        # note and the accompanying report.
        $c3 = Invoke-ChildCommand -Command $CallCommand -TimeoutSec 120
        $probeText = Read-TextFile $ProfileProbeFile
        $invocations = ([regex]::Matches($probeText, 'present=')).Count
        $ok3 = (-not $c3.TimedOut) -and ($c3.Exit -eq 0) -and
               ($c3.Output -match 'PROBE-OK') -and
               ($c3.Output -notmatch 'PROBE-RECURSION') -and
               ($invocations -eq 1) -and
               ($probeText -match 'present=True') -and
               ($probeText -match 'argv=run\|--agent\|testagent\|hello') -and
               (-not $c3.Output.Contains($PlainDummy)) -and (-not $probeText.Contains($PlainDummy))
        Add-Result 'C3-profile-launch-norecursion' $ok3 ("exit=$($c3.Exit) runs=$invocations present=$($probeText -match 'present=True') argv=$($probeText -match 'argv=run\|--agent') timeout=$($c3.TimedOut)")
        if (-not $ok3) { Write-Host ("    debug: out=" + (($c3.Output -replace "`r?`n", ' | ').Trim())) }
    } else {
        Add-Result 'C3-profile-launch-norecursion' $false 'skipped: no profile file'
    }

    # ---------- C4: engine WITH AGENT_HQ_OPENCODE -> raw override, no wrapper -----
    $c4Root = Join-Path $TempBase 'engine-override'
    $c4Vault = Join-Path $TempBase 'vault-empty'
    foreach ($dir in @($c4Root, $c4Vault)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Reset-Env
    $env:AGENT_HQ_ROOT = $c4Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = 'success'
    $env:AGENT_HQ_SECRETS = $c4Vault
    $c4 = Invoke-ChildScript -ScriptPath $EngineCallScript -TimeoutSec 150
    $c4Exit = ([regex]::Match($c4.Output, 'ENGINE-EXIT=(\d+)')).Groups[1].Value
    $c4Stdout = ([regex]::Match($c4.Output, 'ENGINE-STDOUT<(.*?)>')).Groups[1].Value
    # an empty vault proves the wrapper was bypassed: it would exit 2 and start nothing
    $ok4 = (-not $c4.TimedOut) -and ($c4Exit -eq '0') -and
           ($c4Stdout -match 'STATUS: resolved') -and
           ($c4Stdout -notmatch '\[secrets\]') -and
           ($c4Stdout -notmatch 'PROBE')
    Add-Result 'C4-engine-test-override' $ok4 ("exit=$c4Exit marker=$($c4Stdout -match 'STATUS: resolved') wrapper=$($c4Stdout -match '\[secrets\]') timeout=$($c4.TimedOut)")

    # ---------- C5: engine WITHOUT override -> vault wrapper injects the key -----
    if (Test-Path -LiteralPath $EngineProbeFile) { Remove-Item -LiteralPath $EngineProbeFile -Force }
    $c5Root = Join-Path $TempBase 'engine-vault'
    New-Item -ItemType Directory -Path $c5Root -Force | Out-Null
    Reset-Env
    $env:AGENT_HQ_ROOT = $c5Root
    $env:AGENT_HQ_OPENCODE_PATH = $ProbeShim
    $env:AGENT_HQ_SECRETS = $VaultDir
    $env:AGENT_HQ_PROBE_FILE = $EngineProbeFile
    $c5 = Invoke-ChildScript -ScriptPath $EngineCallScript -TimeoutSec 150
    $c5Exit = ([regex]::Match($c5.Output, 'ENGINE-EXIT=(\d+)')).Groups[1].Value
    $c5Stdout = ([regex]::Match($c5.Output, 'ENGINE-STDOUT<(.*?)>')).Groups[1].Value
    $c5Probe = Read-TextFile $EngineProbeFile
    $ok5 = (-not $c5.TimedOut) -and ($c5Exit -eq '0') -and
           ($c5Stdout -match 'PROBE-OK') -and ($c5Stdout -match 'STATUS: resolved') -and
           ($c5Probe -match 'present=True') -and
           (-not $c5Stdout.Contains($PlainDummy)) -and (-not $c5Probe.Contains($PlainDummy))
    Add-Result 'C5-engine-vault-injection' $ok5 ("exit=$c5Exit probe-ok=$($c5Stdout -match 'PROBE-OK') key-present=$($c5Probe -match 'present=True') timeout=$($c5.TimedOut)")
    if (-not $ok5) { Write-Host ("    debug: out=" + (($c5.Output -replace "`r?`n", ' | ').Trim())) }

    # ---------- C6: clear-plaintext-env on the REAL HKCU - read-only -----------
    Reset-Env
    $before = Get-TargetValueSnapshot -Path $EnvRegistryPath
    $out6a = Invoke-Capture { & $ClearEnv -DryRun }
    $code6a = $LASTEXITCODE
    $afterDry = Get-TargetValueSnapshot -Path $EnvRegistryPath
    $out6b = Invoke-Capture { & $ClearEnv }
    $code6b = $LASTEXITCODE
    $afterDefault = Get-TargetValueSnapshot -Path $EnvRegistryPath
    $namesListed = $true
    foreach ($name in $TargetEnvNames) {
        if ($out6a -notmatch [regex]::Escape($name)) { $namesListed = $false }
    }
    $ok6 = ($code6a -eq 0) -and ($code6b -eq 0) -and
           ($out6a -match 'DRY-RUN') -and ($out6b -match 'DRY-RUN') -and
           $namesListed -and
           (Test-SnapshotEqual -A $before -B $afterDry) -and
           (Test-SnapshotEqual -A $before -B $afterDefault)
    Add-Result 'C6-clear-dryrun-readonly' $ok6 ("exit-dry=$code6a exit-default=$code6b names=$namesListed unchanged=$(Test-SnapshotEqual -A $before -B $afterDefault)")

    # ---------- C7: clear-plaintext-env -Apply on a TEMP key -------------------
    $TempKey = Join-Path $TempKeyParent ([guid]::NewGuid().ToString('N'))
    New-Item -Path $TempKey -Force | Out-Null
    New-ItemProperty -Path $TempKey -Name 'AIHUBMIX_API_KEY' -Value $PlainDummy -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $TempKey -Name 'KEEP_ME_KEY' -Value 'keep' -PropertyType String -Force | Out-Null

    $out7dry = Invoke-Capture { & $ClearEnv -DryRun -RegistryPath $TempKey }
    $code7dry = $LASTEXITCODE
    $keptAfterDry = (Get-RegistryValueNames -Path $TempKey) -contains 'AIHUBMIX_API_KEY'

    $out7 = Invoke-Capture { & $ClearEnv -Apply -RegistryPath $TempKey }
    $code7 = $LASTEXITCODE
    $names7 = @(Get-RegistryValueNames -Path $TempKey)
    $targetGone = -not ($names7 -contains 'AIHUBMIX_API_KEY')
    $otherKept = ($names7 -contains 'KEEP_ME_KEY') -and ((Get-ItemProperty -LiteralPath $TempKey).KEEP_ME_KEY -eq 'keep')
    $ok7 = ($code7dry -eq 0) -and $keptAfterDry -and ($code7 -eq 0) -and $targetGone -and $otherKept -and
           (-not $out7.Contains($PlainDummy)) -and (-not $out7dry.Contains($PlainDummy))
    Add-Result 'C7-clear-apply-temp-key' $ok7 ("dry-exit=$code7dry dry-kept=$keptAfterDry apply-exit=$code7 removed=$targetGone other-kept=$otherKept value-leak=$($out7.Contains($PlainDummy))")
    if (-not $ok7) { Write-Host ("    debug: out=" + (($out7 -replace "`r?`n", ' | ').Trim())) }

    # ---------- C8: clear-plaintext-env usage errors ---------------------------
    $out8 = Invoke-Capture { & $ClearEnv -DryRun -Apply }
    $code8 = $LASTEXITCODE
    $out8b = Invoke-Capture { & $ClearEnv -DryRun -RegistryPath '' }
    $code8b = $LASTEXITCODE
    Add-Result 'C8-clear-usage' (($code8 -eq 2) -and ($code8b -eq 2)) ("both-switches=$code8 empty-path=$code8b")
}
catch {
    Write-Host ('STACK: ' + $_.ScriptStackTrace)
    Add-Result 'C-runtime' $false $_.Exception.Message
}
finally {
    # ---------- cleanup: temp key, temp dirs, env ----------
    try {
        if ($TempKey -and (Test-Path -LiteralPath $TempKey)) {
            Remove-Item -LiteralPath $TempKey -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $TempKeyParent) {
            $sub = @(Get-ChildItem -LiteralPath $TempKeyParent -ErrorAction SilentlyContinue)
            if ($sub.Count -eq 0) { Remove-Item -LiteralPath $TempKeyParent -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    foreach ($kv in @($saved.GetEnumerator())) {
        if ($null -ne $kv.Value) {
            [Environment]::SetEnvironmentVariable($kv.Key, [string]$kv.Value, 'Process')
        } else {
            Remove-Item -Path ('Env:\' + $kv.Key) -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $TempBase) {
        Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("ИТОГ: {0}/{1} PASS" -f ($script:Results.Count - $failed.Count), $script:Results.Count)
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
