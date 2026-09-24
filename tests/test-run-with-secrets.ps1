# test-run-with-secrets.ps1 - Independent harness for .agents\scripts\run-with-secrets.ps1.
# Pure PowerShell 5.1 (no Pester), exit 0 = all PASS, exit 1 = at least one FAIL.
#
# Isolation: an empty temporary vault is created and exposed via $env:AGENT_HQ_SECRETS,
# so the REAL vault (%USERPROFILE%\.agent-secrets) is never read or written. The only
# secret used is the well-known test plaintext "test-secret-123", encrypted with DPAPI
# exactly like set-secret.ps1 does. The child process is a tiny probe script generated
# at runtime that reports env presence (boolean) and its own command line — never a value.

$ErrorActionPreference = 'Continue'
$here    = $PSScriptRoot
$repoRoot = Split-Path -Parent $here
$runner  = Join-Path $repoRoot '.agents\scripts\run-with-secrets.ps1'

$TestName  = 'tg-bot-token'        # exercises the DEFAULT mapping -> TG_TOKEN
$TestPlain = 'test-secret-123'
$Missing   = 'no-such-secret-xyz'

$TempBase = Join-Path $env:TEMP ('agent-hq-rws-' + [guid]::NewGuid().ToString('N'))
$VaultDir = Join-Path $TempBase 'vault'
$Child    = Join-Path $TempBase 'child-probe.ps1'

$script:Results = @()
function Add-Result($id, $pass, $note) {
    $script:Results += [pscustomobject]@{ Id = $id; Pass = [bool]$pass; Note = $note }
    Write-Host ("[{0}] {1} — {2}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $id, $note)
}
function Invoke-Capture($scriptBlock) {
    # Capture every PowerShell stream (Write-Host/error included) to a single string.
    # run-with-secrets.ps1 writes diagnostics and the set-secret hint via
    # [Console]::Error, which is a raw console stream that *>&1 does NOT capture;
    # temporarily redirect Console.Error to a StringWriter so hints reach the test.
    $errWriter = New-Object System.IO.StringWriter
    $prevErr = [Console]::Error
    try {
        [Console]::SetError($errWriter)
        $stdout = (& $scriptBlock *>&1 | Out-String)
    } finally {
        [Console]::SetError($prevErr)
    }
    return ($stdout + $errWriter.ToString())
}
function Read-Probe($path) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8) }
    return ''
}

$prevVault = $env:AGENT_HQ_SECRETS
$fp = ''
try {
    # --- setup: temp vault + probe child (no secrets in this file) ---
    New-Item -ItemType Directory -Path $VaultDir -Force | Out-Null

    Add-Type -AssemblyName System.Security
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($TestPlain)
    $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes((Join-Path $VaultDir "secret.$TestName.enc"), $encBytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fp = ([BitConverter]::ToString($sha.ComputeHash($plainBytes)) -replace '-', '').ToLowerInvariant().Substring(0, 12)
    $sha.Dispose()

    $childSrc = @'
param([string]$EnvName,[string]$ProbePath)
$present = -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($EnvName,'Process'))
$cmd = [Environment]::CommandLine
$txt = "present=$present" + "`r`n" + "cmdline=" + $cmd
[System.IO.File]::WriteAllText($ProbePath, $txt, (New-Object System.Text.UTF8Encoding($false)))
if ($present) { Write-Output 'PRESENT' } else { Write-Output 'ABSENT' }
'@
    [System.IO.File]::WriteAllText($Child, $childSrc, (New-Object System.Text.UTF8Encoding($false)))

    $env:AGENT_HQ_SECRETS = $VaultDir

    # --- R1: default mapping, child sees TG_TOKEN, no value in output/probe/cmdline ---
    $probe1 = Join-Path $TempBase 'probe-default.txt'
    $out1 = Invoke-Capture { & $runner -Secret $TestName -Command 'powershell' -Args @('-NoProfile', '-NonInteractive', '-File', $Child, '-EnvName', 'TG_TOKEN', '-ProbePath', $probe1) }
    $code1 = $LASTEXITCODE
    $p1 = Read-Probe $probe1
    $ok1 = ($code1 -eq 0) -and ($p1 -match 'present=True') -and ($out1 -match 'PRESENT') -and
           (-not $out1.Contains($TestPlain)) -and (-not $p1.Contains($TestPlain))
    Add-Result 'R1-default-map+env' $ok1 ("exit=$code1 present=$($p1 -match 'present=True') leak=$($out1.Contains($TestPlain) -or $p1.Contains($TestPlain))")

    # --- R2: -Map override, env restored to empty after the call ---
    $envName = 'AGENT_HQ_RWS_TEST'
    [Environment]::SetEnvironmentVariable($envName, $null, 'Process')
    $probe2 = Join-Path $TempBase 'probe-map.txt'
    $out2 = Invoke-Capture { & $runner -Secret $TestName -Map @{ $TestName = $envName } -Command 'powershell' -Args @('-NoProfile', '-NonInteractive', '-File', $Child, '-EnvName', $envName, '-ProbePath', $probe2) }
    $code2 = $LASTEXITCODE
    $p2 = Read-Probe $probe2
    $after2 = [Environment]::GetEnvironmentVariable($envName, 'Process')
    $ok2 = ($code2 -eq 0) -and ($p2 -match 'present=True') -and ($null -eq $after2)
    Add-Result 'R2-map-override+cleanup' $ok2 ("exit=$code2 present=$($p2 -match 'present=True') restored-null=$($null -eq $after2)")

    # --- R3: a pre-existing env value is restored, not clobbered ---
    [Environment]::SetEnvironmentVariable($envName, 'keep-me', 'Process')
    $probe3 = Join-Path $TempBase 'probe-restore.txt'
    $out3 = Invoke-Capture { & $runner -Secret $TestName -Map @{ $TestName = $envName } -Command 'powershell' -Args @('-NoProfile', '-NonInteractive', '-File', $Child, '-EnvName', $envName, '-ProbePath', $probe3) }
    $code3 = $LASTEXITCODE
    $p3 = Read-Probe $probe3
    $after3 = [Environment]::GetEnvironmentVariable($envName, 'Process')
    $ok3 = ($code3 -eq 0) -and ($p3 -match 'present=True') -and ($after3 -eq 'keep-me')
    [Environment]::SetEnvironmentVariable($envName, $null, 'Process')
    Add-Result 'R3-preexisting-restored' $ok3 ("exit=$code3 present=$($p3 -match 'present=True') after='$after3'")

    # --- R4: missing secret -> exit != 0, child NOT started, hint present ---
    $probe4 = Join-Path $TempBase 'probe-missing.txt'
    if (Test-Path -LiteralPath $probe4) { Remove-Item -LiteralPath $probe4 -Force }
    $out4 = Invoke-Capture { & $runner -Secret $Missing -Command 'powershell' -Args @('-NoProfile', '-NonInteractive', '-File', $Child, '-EnvName', 'TG_TOKEN', '-ProbePath', $probe4) }
    $code4 = $LASTEXITCODE
    $childRan4 = Test-Path -LiteralPath $probe4 -PathType Leaf
    $ok4 = ($code4 -ne 0) -and (-not $childRan4) -and ($out4 -match 'set-secret')
    Add-Result 'R4-missing-norun' $ok4 ("exit=$code4 child-ran=$childRan4 hint=$($out4 -match 'set-secret')")

    # --- R5: -List prints the mapping, no secret value ---
    $out5 = Invoke-Capture { & $runner -List }
    $code5 = $LASTEXITCODE
    $ok5 = ($code5 -eq 0) -and ($out5 -match 'tg-bot-token') -and ($out5 -match 'TG_TOKEN') -and (-not $out5.Contains($TestPlain))
    Add-Result 'R5-list' $ok5 ("exit=$code5 mapping=$($out5 -match 'TG_TOKEN') leak=$($out5.Contains($TestPlain))")

    # --- R6: -VerifyOnly explicit -> fingerprint matches, no value ---
    $out6 = Invoke-Capture { & $runner -VerifyOnly -Secret $TestName }
    $code6 = $LASTEXITCODE
    $ok6 = ($code6 -eq 0) -and ($out6 -match [regex]::Escape($fp)) -and (-not $out6.Contains($TestPlain))
    Add-Result 'R6-verifyonly-explicit' $ok6 ("exit=$code6 fp-match=$($out6 -match [regex]::Escape($fp)) leak=$($out6.Contains($TestPlain))")

    # --- R7: -VerifyOnly (all vault names) -> exit 0, includes temp secret ---
    $out7 = Invoke-Capture { & $runner -VerifyOnly }
    $code7 = $LASTEXITCODE
    $ok7 = ($code7 -eq 0) -and ($out7 -match $TestName) -and (-not $out7.Contains($TestPlain))
    Add-Result 'R7-verifyonly-all' $ok7 ("exit=$code7 named=$($out7 -match $TestName)")

    # --- R8: -VerifyOnly on a missing secret -> exit != 0 ---
    $out8 = Invoke-Capture { & $runner -VerifyOnly -Secret $Missing }
    $code8 = $LASTEXITCODE
    Add-Result 'R8-verifyonly-missing' ($code8 -ne 0) "exit=$code8"

    # --- R9: invalid ENV name from -Map -> usage error, child not started ---
    $probe9 = Join-Path $TempBase 'probe-badname.txt'
    if (Test-Path -LiteralPath $probe9) { Remove-Item -LiteralPath $probe9 -Force }
    $out9 = Invoke-Capture { & $runner -Secret $TestName -Map @{ $TestName = 'BAD-NAME!' } -Command 'powershell' -Args @('-NoProfile', '-NonInteractive', '-File', $Child, '-EnvName', 'TG_TOKEN', '-ProbePath', $probe9) }
    $code9 = $LASTEXITCODE
    $ok9 = ($code9 -eq 2) -and (-not (Test-Path -LiteralPath $probe9 -PathType Leaf))
    Add-Result 'R9-bad-envname' $ok9 ("exit=$code9 child-ran=$(Test-Path -LiteralPath $probe9 -PathType Leaf)")

    # --- R10: usage errors -> exactly one of -Command/-FilePath, and -Secret required ---
    $outA = Invoke-Capture { & $runner -Command 'powershell' -Secret $TestName -FilePath (Join-Path $env:TEMP 'nope.ps1') }
    $codeA = $LASTEXITCODE
    $outB = Invoke-Capture { & $runner -Command 'powershell' }
    $codeB = $LASTEXITCODE
    $ok10 = ($codeA -eq 2) -and ($codeB -eq 2)
    Add-Result 'R10-usage-errors' $ok10 ("both=$codeA nosecret=$codeB")

    # --- R11: no secret value in the child command line (argv) ---
    $cmdline = ''
    if ($p1 -match 'cmdline=(.*)') { $cmdline = $Matches[1] }
    $ok11 = (-not [string]::IsNullOrEmpty($cmdline)) -and (-not $cmdline.Contains($TestPlain))
    Add-Result 'R11-no-argv-leak' $ok11 ("cmdline-captured=$(-not [string]::IsNullOrEmpty($cmdline)) leak=$($cmdline.Contains($TestPlain))")
}
catch {
    Write-Host ('STACK: ' + $_.ScriptStackTrace)
    Add-Result 'R-runtime' $false $_.Exception.Message
}
finally {
    # --- cleanup: drop temp vault/probes/child, restore AGENT_HQ_SECRETS ---
    try {
        if ($null -ne $prevVault) { $env:AGENT_HQ_SECRETS = $prevVault }
        else { Remove-Item -Path 'Env:\AGENT_HQ_SECRETS' -ErrorAction SilentlyContinue }
    } catch { }
    if (Test-Path -LiteralPath $TempBase) {
        Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("ИТОГ: {0}/{1} PASS" -f ($script:Results.Count - $failed.Count), $script:Results.Count)
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
