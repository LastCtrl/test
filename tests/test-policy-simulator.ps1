# test-policy-simulator.ps1 - independent tests for .agents\scripts\policy-simulator.ps1.
#
# Pure PowerShell 5.1 (no Pester). All simulation runs against an isolated fake
# repo root; the real repository configs are only READ and their hashes are
# checked before/after, so a real config can never be modified by a simulation.
#
# Covered:
#   a) source invariants - syntax, CRLF, no BOM, no forbidden token in both files
#   b) dot-source        - functions load without running the CLI or clobbering vars
#   c) bash regression   - deny -> allow is flagged REGRESSION and unsafe
#   d) bash hardening    - allow -> deny is HARDENED and stays safe
#   e) model route       - the proposed model changes the routed model
#   f) permission map    - deny -> allow regression + fork-bomb risk
#   g) cli json          - `-Inline ... -Simulate -Json` emits valid JSON
#   h) cli diff          - `-Diff` hides unchanged rows, keeps the regression
#   i) list / usage      - `-List` exits 0, no arguments exits 2
#   j) bad input         - broken/empty/missing proposals exit non-zero, no crash
#   k) read-only         - real opencode.json + a real agent file keep their hashes
#   l) cleanup           - the simulator leaves no temp overlay behind
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Sim      = Join-Path $RepoRoot ".agents\scripts\policy-simulator.ps1"
$TestSim  = $PSCommandPath

$TempBase = Join-Path $env:TEMP ("agent-hq-policy-sim-tests-" + [guid]::NewGuid().ToString("N"))
$Root     = Join-Path $TempBase "repo"
$nl       = "`r`n"
$NoBom    = New-Object System.Text.UTF8Encoding($false)

$script:CasePass  = 0
$script:CaseFail  = 0
$script:CheckPass = 0
$script:CheckFail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:CheckPass++
        Write-Host ("    ok  : " + $Label)
    } else {
        $script:CheckFail++
        $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { "" } else { " -- " + $Detail }
        Write-Host ("    FAIL: " + $Label + $suffix)
    }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-SimTestText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Test-FileInvariants {
    param([string]$Label, [string]$Path)
    $ok = $true
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $ok = (Write-Check ($Label + ": no UTF-8 BOM") (-not $hasBom)) -and $ok
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) { $lf++; if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
    }
    $ok = (Write-Check ($Label + ": CRLF only (lone LF = 0)") (($lf - $crlf) -eq 0 -and $crlf -gt 0)) -and $ok
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Path), [ref]$errors)
    $ok = (Write-Check ($Label + ": PSParser 0 errors") ($errors.Count -eq 0)) -and $ok
    $needle = 's' + 'k-'
    $hits = ([regex]::Matches((Read-SimTestText -Path $Path), [regex]::Escape($needle))).Count
    $ok = (Write-Check ($Label + ": forbidden token absent") ($hits -eq 0) ("hits=" + $hits)) -and $ok
    return $ok
}

function ConvertFrom-CliJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $i = $Text.IndexOf('{')
    if ($i -lt 0) { return $null }
    try { return ($Text.Substring($i) | ConvertFrom-Json) } catch { return $null }
}

function Invoke-SimInlineCli {
    param([string]$Json, [string]$CliRoot, [string[]]$Extra = @())
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("& '" + $Sim + "'")
    [void]$parts.Add("-Inline")
    [void]$parts.Add('$env:SIM_TEST_INLINE')
    if (-not [string]::IsNullOrWhiteSpace($CliRoot)) { [void]$parts.Add("-Root '" + $CliRoot + "'") }
    foreach ($item in @($Extra)) { [void]$parts.Add([string]$item) }
    $command = ($parts.ToArray() -join ' ')
    $env:SIM_TEST_INLINE = $Json
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
    $code = $LASTEXITCODE
    Remove-Item Env:\SIM_TEST_INLINE -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Output = (@($out) -join "`n"); Exit = [int]$code }
}

function Invoke-SimRawCli {
    param([string[]]$SimArgs = @())
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sim @SimArgs 2>&1
    return [pscustomobject]@{ Output = (@($out) -join "`n"); Exit = [int]$LASTEXITCODE }
}

if (-not (Test-Path -LiteralPath $Sim -PathType Leaf)) {
    Write-Host ("FATAL: policy-simulator.ps1 missing: " + $Sim)
    exit 1
}

try {
    # --- fixture -------------------------------------------------------------

    foreach ($rel in @(".opencode\agents", ".memory", ".agents\config")) {
        New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
    }

    $configJson = '{' + $nl +
        '  "permission": {' + $nl +
        '    "bash": {' + $nl +
        '      "*": "allow",' + $nl +
        '      "git status*": "allow",' + $nl +
        '      "git push*": "ask",' + $nl +
        '      "rm -rf*": "deny",' + $nl +
        '      "Start-Process*": "deny",' + $nl +
        '      "format *": "deny"' + $nl +
        '    }' + $nl +
        '  },' + $nl +
        '  "agent": {' + $nl +
        '    "dev-x": { "model": "zone/alpha", "permission": { "task": { "*": "deny", "qa-x": "allow" } } },' + $nl +
        '    "qa-x": { "model": "zone/beta" }' + $nl +
        '  }' + $nl +
        '}' + $nl
    $cfgPath = Join-Path $Root "opencode.json"
    [System.IO.File]::WriteAllText($cfgPath, $configJson, $NoBom)

    $devAgent = '{' + $nl + '    "name": "dev-x",' + $nl + '    "model": "zone/alpha"' + $nl + '}' + $nl
    $qaAgent  = '{' + $nl + '    "name": "qa-x",' + $nl + '    "model": "zone/beta"' + $nl + '}' + $nl
    [System.IO.File]::WriteAllText((Join-Path $Root ".opencode\agents\dev-x.json"), $devAgent, $NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Root ".opencode\agents\qa-x.json"), $qaAgent, $NoBom)

    # --- a) source invariants ------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE a: source invariants ---"
    $aOk = $true
    $aOk = (Test-FileInvariants -Label "simulator" -Path $Sim) -and $aOk
    $aOk = (Test-FileInvariants -Label "test" -Path $TestSim) -and $aOk
    Close-Case "a) source invariants" $aOk

    # --- b) dot-source safety ------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE b: dot-source safety ---"
    $bOk = $true
    $sentinel = "SENTINEL-KEEP"
    . $Sim
    $bOk = (Write-Check "Invoke-PolicySimulation is defined" ($null -ne (Get-Command Invoke-PolicySimulation -CommandType Function -ErrorAction SilentlyContinue))) -and $bOk
    $bOk = (Write-Check "Invoke-SimBashChange is defined" ($null -ne (Get-Command Invoke-SimBashChange -CommandType Function -ErrorAction SilentlyContinue))) -and $bOk
    $bOk = (Write-Check "dot-sourcing kept the caller variable" ($sentinel -eq "SENTINEL-KEEP")) -and $bOk
    Close-Case "b) dot-source safety" $bOk

    # --- c) bash regression --------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE c: bash regression (deny -> allow) ---"
    $cOk = $true
    $regProposal = '{"kind":"bash","overrides":{"rm -rf*":"allow"}}'
    $regResult = Invoke-PolicySimulation -Inline $regProposal -Root $Root -DefaultAction "ask"
    $cOk = (Write-Check "simulation returns ok" ($regResult.ok -eq $true)) -and $cOk
    $cOk = (Write-Check "kind is bash" ($regResult.kind -eq "bash")) -and $cOk
    $cOk = (Write-Check "proposal is marked unsafe" ($regResult.unsafe -eq $true)) -and $cOk
    $cOk = (Write-Check "at least one regression counted" ([int]$regResult.counts.regression -ge 1)) -and $cOk
    $regRow = @($regResult.diffs | Where-Object { $_.command -eq "rm -rf /" })
    $cOk = (Write-Check "rm -rf / flips deny -> allow" (($regRow.Count -eq 1) -and ($regRow[0].effect -eq "regression") -and ($regRow[0].baseline -eq "deny") -and ($regRow[0].proposed -eq "allow"))) -and $cOk
    $regChanged = @($regResult.rules_changed | Where-Object { $_.pattern -eq "rm -rf*" })
    $cOk = (Write-Check "rules_changed records rm -rf*: deny -> allow" (($regChanged.Count -eq 1) -and ($regChanged[0].to -eq "allow"))) -and $cOk
    $cOk = (Write-Check "warning mentions REGRESSION" (($regResult.warnings -join " ") -match "REGRESSION")) -and $cOk
    $cOk = (Write-Check "counts sum equals the command count" (([int]$regResult.counts.unchanged + [int]$regResult.counts.hardened + [int]$regResult.counts.weakened + [int]$regResult.counts.regression) -eq @($regResult.commands).Count)) -and $cOk
    Close-Case "c) bash regression" $cOk

    # --- d) bash hardening ---------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE d: bash hardening (allow -> deny) ---"
    $dOk = $true
    $hardResult = Invoke-PolicySimulation -Inline '{"kind":"bash","overrides":{"node *":"deny"}}' -Root $Root -DefaultAction "ask"
    $dOk = (Write-Check "hardening proposal stays safe" ($hardResult.unsafe -eq $false)) -and $dOk
    $dOk = (Write-Check "at least one hardened command" ([int]$hardResult.counts.hardened -ge 1)) -and $dOk
    $nodeRow = @($hardResult.diffs | Where-Object { $_.command -eq "node script.js" })
    $dOk = (Write-Check "node * flips allow -> deny" (($nodeRow.Count -eq 1) -and ($nodeRow[0].effect -eq "hardened"))) -and $dOk
    Close-Case "d) bash hardening" $dOk

    # --- e) model route change ----------------------------------------------

    Write-Host ""
    Write-Host "--- CASE e: model route change ---"
    $eOk = $true
    $modelResult = Invoke-PolicySimulation -Inline '{"kind":"model","agent":"dev-x","model":"zone/omega"}' -Root $Root
    $eOk = (Write-Check "model simulation returns ok" ($modelResult.ok -eq $true)) -and $eOk
    $eOk = (Write-Check "baseline route is zone/alpha" ($modelResult.baseline.model -eq "zone/alpha")) -and $eOk
    $eOk = (Write-Check "proposed route is zone/omega" ($modelResult.proposed.model -eq "zone/omega")) -and $eOk
    $eOk = (Write-Check "route_changed is true" ($modelResult.route_changed -eq $true)) -and $eOk
    Close-Case "e) model route" $eOk

    # --- f) permission map ---------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE f: permission map regression + fork-bomb ---"
    $fOk = $true
    $permProposal = '{"kind":"permission","agent":"dev-x","task":{"*":"allow"},"targets":["qa-x","team-lead","dev-x"]}'
    $permResult = Invoke-PolicySimulation -Inline $permProposal -Root $Root
    $fOk = (Write-Check "permission simulation returns ok" ($permResult.ok -eq $true)) -and $fOk
    $fOk = (Write-Check "permission proposal is unsafe" ($permResult.unsafe -eq $true)) -and $fOk
    $fOk = (Write-Check "two deny -> allow regressions" ([int]$permResult.counts.regression -eq 2)) -and $fOk
    $fOk = (Write-Check "fork-bomb risk is reported" (($permResult.warnings -join " ") -match "FORK-BOMB")) -and $fOk
    $fOk = (Write-Check "qa-x stays allow (unchanged)" ((@($permResult.rows | Where-Object { $_.target -eq "qa-x" })[0].effect) -eq "unchanged")) -and $fOk
    Close-Case "f) permission map" $fOk

    # --- g) cli json ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE g: CLI -Json ---"
    $gOk = $true
    $regCli = Invoke-SimInlineCli -Json $regProposal -CliRoot $Root -Extra @("-Simulate", "-Json")
    $gOk = (Write-Check "JSON CLI exits 0" ($regCli.Exit -eq 0) $regCli.Output) -and $gOk
    $parsed = ConvertFrom-CliJson -Text $regCli.Output
    $gOk = (Write-Check "output parses as JSON" ($null -ne $parsed)) -and $gOk
    if ($null -ne $parsed) {
        $gOk = (Write-Check "JSON ok = true" ($parsed.ok -eq $true)) -and $gOk
        $gOk = (Write-Check "JSON kind = bash" ($parsed.kind -eq "bash")) -and $gOk
        $gOk = (Write-Check "JSON regression count >= 1" ([int]$parsed.counts.regression -ge 1)) -and $gOk
        $gOk = (Write-Check "JSON unsafe = true" ($parsed.unsafe -eq $true)) -and $gOk
    }
    Close-Case "g) cli json" $gOk

    # --- h) cli diff ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE h: CLI -Diff hides unchanged rows ---"
    $hOk = $true
    $diffCli = Invoke-SimInlineCli -Json $regProposal -CliRoot $Root -Extra @("-Simulate", "-Diff")
    $hOk = (Write-Check "diff CLI exits 0" ($diffCli.Exit -eq 0) $diffCli.Output) -and $hOk
    $hOk = (Write-Check "diff output shows the regression" (($diffCli.Output -match "regression") -and ($diffCli.Output -match "rm -rf /"))) -and $hOk
    $hOk = (Write-Check "diff output hides unchanged commands" (-not ($diffCli.Output -match "git status"))) -and $hOk
    Close-Case "h) cli diff" $hOk

    # --- i) list / usage -----------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE i: -List and no-argument usage ---"
    $iOk = $true
    $listCli = Invoke-SimRawCli -SimArgs @("-List")
    $iOk = (Write-Check "-List exits 0" ($listCli.Exit -eq 0) $listCli.Output) -and $iOk
    $iOk = (Write-Check "-List mentions bash/model/permission" (($listCli.Output -match "bash") -and ($listCli.Output -match "model") -and ($listCli.Output -match "permission"))) -and $iOk
    $usageCli = Invoke-SimRawCli
    $iOk = (Write-Check "no arguments exits 2" ($usageCli.Exit -eq 2) ("exit=" + $usageCli.Exit)) -and $iOk
    Close-Case "i) list / usage" $iOk

    # --- j) bad input --------------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE j: bad input is rejected without a crash ---"
    $jOk = $true
    $brokenCli = Invoke-SimInlineCli -Json '{"kind":"bash","overrides":{' -CliRoot $Root -Extra @("-Simulate", "-Json")
    $jOk = (Write-Check "broken JSON exits non-zero" ($brokenCli.Exit -ne 0) ("exit=" + $brokenCli.Exit)) -and $jOk
    $brokenParsed = ConvertFrom-CliJson -Text $brokenCli.Output
    $jOk = (Write-Check "broken JSON reports ok=false" (($null -ne $brokenParsed) -and ($brokenParsed.ok -eq $false))) -and $jOk

    $emptyCli = Invoke-SimInlineCli -Json "" -CliRoot $Root -Extra @("-Simulate")
    $jOk = (Write-Check "empty -Inline exits non-zero" ($emptyCli.Exit -ne 0) ("exit=" + $emptyCli.Exit)) -and $jOk

    $missingCli = Invoke-SimRawCli -SimArgs @("-Propose", (Join-Path $TempBase "does-not-exist.json"))
    $jOk = (Write-Check "missing -Propose file exits non-zero" ($missingCli.Exit -ne 0) ("exit=" + $missingCli.Exit)) -and $jOk

    $unknownCli = Invoke-SimInlineCli -Json '{"kind":"nonsense"}' -CliRoot $Root -Extra @("-Simulate")
    $jOk = (Write-Check "unknown kind exits non-zero" ($unknownCli.Exit -ne 0) ("exit=" + $unknownCli.Exit)) -and $jOk
    Close-Case "j) bad input" $jOk

    # --- k) read-only real configs ------------------------------------------

    Write-Host ""
    Write-Host "--- CASE k: real configs are untouched (hashes) ---"
    $kOk = $true
    $realCfg = Join-Path $RepoRoot "opencode.json"
    $realAgent = Join-Path $RepoRoot ".opencode\agents\dev-3.json"
    if (-not (Test-Path -LiteralPath $realAgent -PathType Leaf)) {
        $realAgent = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".opencode\agents") -Filter "*.json" -File)[0].FullName
    }
    $cfgHashBefore = Get-Sha256 $realCfg
    $agentHashBefore = Get-Sha256 $realAgent
    $bakBefore = @(Get-ChildItem -LiteralPath $RepoRoot -Filter "opencode.json.bak.*" -File -ErrorAction SilentlyContinue).Count

    $realRun = Invoke-SimInlineCli -Json $regProposal -CliRoot $RepoRoot -Extra @("-Simulate", "-Json")
    $kOk = (Write-Check "simulation against the real root exits 0" ($realRun.Exit -eq 0) $realRun.Output) -and $kOk
    $kOk = (Write-Check "real opencode.json hash unchanged" ((Get-Sha256 $realCfg) -eq $cfgHashBefore)) -and $kOk
    $kOk = (Write-Check "real agent file hash unchanged" ((Get-Sha256 $realAgent) -eq $agentHashBefore)) -and $kOk
    $bakAfter = @(Get-ChildItem -LiteralPath $RepoRoot -Filter "opencode.json.bak.*" -File -ErrorAction SilentlyContinue).Count
    $kOk = (Write-Check "no backup file was created" ($bakAfter -eq $bakBefore)) -and $kOk
    Close-Case "k) read-only" $kOk

    # --- l) temp cleanup -----------------------------------------------------

    Write-Host ""
    Write-Host "--- CASE l: no temp overlay left behind ---"
    $lOk = $true
    $prefix = "agent-hq-policy-sim-"
    $before = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($prefix + "*") }).Count
    $null = Invoke-PolicySimulation -Inline '{"kind":"model","agent":"dev-x","model":"zone/omega"}' -Root $Root
    $after = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($prefix + "*") }).Count
    $lOk = (Write-Check "model overlay temp dir is removed" ($after -le $before) ("before=" + $before + " after=" + $after)) -and $lOk
    Close-Case "l) temp cleanup" $lOk
}
finally {
    Remove-Item Env:\SIM_TEST_INLINE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: checks PASS=" + $script:CheckPass + " FAIL=" + $script:CheckFail)
Write-Host ("CASES  : PASS=" + $script:CasePass + " FAIL=" + $script:CaseFail)
if ($script:CaseFail -gt 0 -or $script:CheckFail -gt 0) { Write-Host "RESULT : FAIL" } else { Write-Host "RESULT : PASS" }
Write-Host "=================================================="

if ($script:CaseFail -gt 0 -or $script:CheckFail -gt 0) { exit 1 } else { exit 0 }
