# test-doctor.ps1 - independent tests for .agents\scripts\doctor.ps1 (P3-2).
#
# Pure PowerShell 5.1 (no Pester). Everything runs against an ISOLATED temp root
# exposed through $env:AGENT_HQ_ROOT (and passed explicitly as -Root), so the real
# repository is only READ: the schema, opencode.json and the dot-sourced helper
# scripts are copied into the temp root, never modified in place.
#
# Covered:
#   a) syntax gate   - doctor.ps1 parses with zero PSParser errors
#   b) human report  - `-NoTests` exits 0/1/2, prints all seven section headers and
#                      a DOCTOR: verdict; the CONFIG section is OK for a valid root
#   c) json report   - `-NoTests -Json` emits parseable JSON with root/sections/
#                      summary; summary.exit_code matches the process exit code and
#                      status maps 0->OK, 2->WARN, 1->FAIL
#   d) fast mode     - `-Fast` exits 0/1/2, runs (or skips) the TESTS section
#                      without crashing; the isolated root has no tests directory,
#                      so a WARN is expected, never an exception
#   e) read-only     - doctor does not mutate the root: a tree snapshot
#                      (relative path + size + mtime) is byte-identical before/after
#   f) line endings  - doctor.ps1 uses CRLF only (no bare LF)
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Doctor   = Join-Path $RepoRoot ".agents\scripts\doctor.ps1"

$TempBase = Join-Path $env:TEMP "agent-hq-doctor-tests"
$Root     = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CheckPass = 0
$script:CheckFail = 0
$script:CasePass  = 0
$script:CaseFail  = 0

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

# Relative path + size + mtime of every file/dir under the root. Used to prove
# doctor does not mutate state (tests are NOT run in this snapshot).
function Get-TreeSnapshot {
    param([string]$RootPath)
    $items = @(Get-ChildItem -LiteralPath $RootPath -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    $lines = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        $rel = $item.FullName.Substring($RootPath.Length)
        $len = ''
        if ($null -ne $item.Length) { $len = [string]$item.Length }
        [void]$lines.Add(("{0}|{1}|{2}" -f $rel, $len, $item.LastWriteTimeUtc.Ticks))
    }
    return ($lines -join "`n")
}

function Invoke-Doctor {
    param([string]$RootPath, [string[]]$ExtraArgs = @())
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Doctor, '-Root', $RootPath) + $ExtraArgs
    # stderr is dropped so the JSON stream on stdout stays parseable; the exit code
    # is captured right after the pipeline.
    $text = (& $psExe @arguments 2>$null | Out-String)
    $code = $LASTEXITCODE
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($rel in @(
    ".memory\inbox",
    ".memory\outbox",
    ".memory\dead-letter",
    ".memory\claims",
    ".agents\skills\demo",
    ".agents\scripts",
    ".agents\config",
    ".opencode\agents",
    "schemas"
)) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}

Write-Host "=== agent-hq doctor tests ==="
Write-Host ("Doctor : " + $Doctor)
Write-Host ("Root   : " + $Root)

if (-not (Test-Path -LiteralPath $Doctor -PathType Leaf)) {
    Write-Host ("FATAL: doctor not found: " + $Doctor)
    exit 1
}

# --- a) syntax gate ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: a) doctor.ps1 parses without errors"
$caseOk = $true
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Doctor), [ref]$parseErrors)
$caseOk = (Write-Check "zero PSParser errors" ($parseErrors.Count -eq 0) ("count=" + $parseErrors.Count)) -and $caseOk
Close-Case "a) syntax" $caseOk

# --- fixture: copy read-only sources + minimal runtime data -----------------

Copy-Item -LiteralPath (Join-Path $RepoRoot "opencode.json") -Destination (Join-Path $Root "opencode.json") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "schemas\opencode.config.schema.json") -Destination (Join-Path $Root "schemas\opencode.config.schema.json") -Force
foreach ($helper in @("bash-policy.ps1", "task-state.ps1", "model-router.ps1", "review-disagreement.ps1", "capability-passport.ps1")) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot (".agents\scripts\" + $helper)) -Destination (Join-Path $Root (".agents\scripts\" + $helper)) -Force
}

[System.IO.File]::WriteAllText((Join-Path $Root ".memory\model-health.json"),
    '{"demo/model-a":{"model":"demo/model-a","status":"OK","checked_at":"2026-01-01T00:00:00","fail_count":0,"open_until":""}}',
    $Utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $Root ".agents\skills\demo\SKILL.md"),
    "# demo skill`r`n`r`nIsolated fixture for the doctor test.`r`n",
    $Utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $Root ".opencode\agents\dev-x.json"),
    "{`r`n    `"name`":  `"dev-x`",`r`n    `"description`":  `"fixture`",`r`n    `"model`":  `"demo/model-a`",`r`n    `"mode`":  `"subagent`"`r`n}`r`n",
    $Utf8NoBom)

[System.IO.File]::WriteAllText((Join-Path $Root "CONTEXT-BUFFER.md"),
    "[2026-01-01T00:00:00] dev-x -> team-lead:`r`nTYPE: update | PRIORITY: low`r`nCONTENT: isolated doctor test fixture.`r`nSTATUS: resolved`r`n",
    $Utf8NoBom)

# Fresh passport fixture: 1 agent + 1 model with a current updated_at.
$passportFixture = '{"version":1,"updated_at":"' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') + '","agents":{"dev-x":{}},"models":{"demo/model-a":{}}}'
[System.IO.File]::WriteAllText((Join-Path $Root ".agents\config\capability-passport.json"), $passportFixture, $Utf8NoBom)

$isoAgentsDir = Join-Path $Root ".opencode\agents"
$isoSkillsDir = Join-Path $Root ".agents\skills"

# --- b) human report --------------------------------------------------------

Write-Host ""
Write-Host "CASE: b) -NoTests human report"
$caseOk = $true
$human = Invoke-Doctor -RootPath $Root -ExtraArgs @('-NoTests')
$caseOk = (Write-Check "exit code is 0/1/2" (@(0, 1, 2) -contains $human.code) ("exit=" + $human.code)) -and $caseOk
$caseOk = (Write-Check "prints the doctor header" ($human.text -match '===\s*agent-hq doctor\s*===')) -and $caseOk
foreach ($section in @('ENV', 'CONFIG', 'MODELS', 'PASSPORT', 'QUEUE', 'TESTS', 'EVIDENCE/DISAGREEMENT')) {
    $pattern = '---\s*' + [regex]::Escape($section) + '\s*\['
    $caseOk = (Write-Check ("section header " + $section) ($human.text -match $pattern)) -and $caseOk
}
$caseOk = (Write-Check "prints a DOCTOR: verdict" ($human.text -match 'DOCTOR:\s*(OK|WARN|FAIL)')) -and $caseOk
$caseOk = (Write-Check "CONFIG section is OK on a valid root" ($human.text -match '---\s*CONFIG\s*\[OK\]')) -and $caseOk
$caseOk = (Write-Check "PASSPORT section is OK with a fresh passport" ($human.text -match '---\s*PASSPORT\s*\[OK\]')) -and $caseOk
$caseOk = (Write-Check "PASSPORT reports agent/model counts" ($human.text -match '\[OK\] passport document - 1 agent\(s\), 1 model\(s\)')) -and $caseOk
$caseOk = (Write-Check "-NoTests marks the test run as skipped" ($human.text -match 'skipped \(-NoTests\)')) -and $caseOk

# Missing passport must degrade to WARN without crashing (read-only).
$isoPassport = Join-Path $Root ".agents\config\capability-passport.json"
$isoPassportOff = $isoPassport + ".off"
Rename-Item -LiteralPath $isoPassport -NewName "capability-passport.json.off"
$humanMissing = Invoke-Doctor -RootPath $Root -ExtraArgs @('-NoTests')
Rename-Item -LiteralPath $isoPassportOff -NewName "capability-passport.json"
$caseOk = (Write-Check "missing passport keeps exit 0/1/2" (@(0, 1, 2) -contains $humanMissing.code)) -and $caseOk
$caseOk = (Write-Check "missing passport is section-WARN, not a crash" ($humanMissing.text -match '---\s*PASSPORT\s*\[WARN\]')) -and $caseOk
Close-Case "b) human report" $caseOk

# --- c) json report ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: c) -NoTests -Json report"
$caseOk = $true
$jsonRun = Invoke-Doctor -RootPath $Root -ExtraArgs @('-NoTests', '-Json')
$caseOk = (Write-Check "exit code is 0/1/2" (@(0, 1, 2) -contains $jsonRun.code) ("exit=" + $jsonRun.code)) -and $caseOk
$parsed = $null
try { $parsed = $jsonRun.text | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
$caseOk = (Write-Check "stdout is valid JSON" ($null -ne $parsed)) -and $caseOk
$nonAscii = @([regex]::Matches($jsonRun.text, '[^\x00-\x7F]')).Count
$caseOk = (Write-Check "json stdout is pure ASCII (codepage-independent)" ($nonAscii -eq 0) ("nonAscii=" + $nonAscii)) -and $caseOk

if ($null -ne $parsed) {
    $caseOk = (Write-Check "has root" (-not [string]::IsNullOrWhiteSpace([string]$parsed.root))) -and $caseOk
    $caseOk = (Write-Check "has timestamp" (-not [string]::IsNullOrWhiteSpace([string]$parsed.timestamp))) -and $caseOk
    $caseOk = (Write-Check "has seven sections" (@($parsed.sections).Count -eq 7) ("count=" + @($parsed.sections).Count)) -and $caseOk

    $sectionNames = @($parsed.sections | ForEach-Object { $_.name })
    if ($sectionNames.Count -gt 0) {
        $hasAll = $true
        foreach ($wanted in @('ENV', 'CONFIG', 'MODELS', 'PASSPORT', 'QUEUE', 'TESTS', 'EVIDENCE/DISAGREEMENT')) {
            if ($sectionNames -cnotcontains $wanted) { $hasAll = $false }
        }
        $caseOk = (Write-Check "section names are the documented seven" $hasAll ("names=" + ($sectionNames -join ','))) -and $caseOk
    } else {
        $caseOk = (Write-Check "section names are the documented seven" $false "no sections") -and $caseOk
    }

    $validStatuses = $true
    foreach ($section in @($parsed.sections)) {
        if (@('OK', 'WARN', 'FAIL') -cnotcontains [string]$section.status) { $validStatuses = $false }
        if (@($section.checks).Count -lt 1) { $validStatuses = $false }
        foreach ($check in @($section.checks)) {
            if (@('OK', 'WARN', 'FAIL') -cnotcontains [string]$check.status) { $validStatuses = $false }
        }
    }
    $caseOk = (Write-Check "every section/check has a valid status" $validStatuses) -and $caseOk

    $summary = $parsed.summary
    $caseOk = (Write-Check "summary has ok/warn/fail counts" ($null -ne $summary.ok -and $null -ne $summary.warn -and $null -ne $summary.fail)) -and $caseOk
    $caseOk = (Write-Check "summary.exit_code matches the process exit" ([int]$summary.exit_code -eq $jsonRun.code) ("json=" + $summary.exit_code + " process=" + $jsonRun.code)) -and $caseOk

    $expectedStatus = 'OK'
    if ($jsonRun.code -eq 1) { $expectedStatus = 'FAIL' }
    elseif ($jsonRun.code -eq 2) { $expectedStatus = 'WARN' }
    $caseOk = (Write-Check "summary.status matches the exit code mapping" ([string]$summary.status -eq $expectedStatus) ("status=" + $summary.status + " exit=" + $jsonRun.code)) -and $caseOk

    $jsonConfig = @($parsed.sections | Where-Object { $_.name -eq 'CONFIG' })
    if ($jsonConfig.Count -eq 1) {
        $caseOk = (Write-Check "json CONFIG status is OK on a valid root" ([string]$jsonConfig[0].status -eq 'OK')) -and $caseOk
    }
} else {
    $caseOk = (Write-Check "json structure could not be checked (parse failed)" $false) -and $caseOk
}
Close-Case "c) json report" $caseOk

# --- d) fast mode -----------------------------------------------------------

Write-Host ""
Write-Host "CASE: d) -Fast (no tests directory in the isolated root)"
$caseOk = $true
$fastRun = Invoke-Doctor -RootPath $Root -ExtraArgs @('-Fast')
$caseOk = (Write-Check "-Fast exit code is 0/1/2" (@(0, 1, 2) -contains $fastRun.code) ("exit=" + $fastRun.code)) -and $caseOk
$caseOk = (Write-Check "-Fast still prints the TESTS section" ($fastRun.text -match '---\s*TESTS\s*\[')) -and $caseOk
$caseOk = (Write-Check "-Fast does not crash on a missing tests dir" ($fastRun.text -match 'tests directory missing')) -and $caseOk
$caseOk = (Write-Check "-Fast does not imply -NoTests" (-not ($fastRun.text -match 'skipped \(-NoTests\)'))) -and $caseOk
Close-Case "d) fast mode" $caseOk

# --- e) read-only -----------------------------------------------------------

Write-Host ""
Write-Host "CASE: e) doctor does not mutate the repository state"
$caseOk = $true
$before = Get-TreeSnapshot -RootPath $Root
$null = Invoke-Doctor -RootPath $Root -ExtraArgs @('-NoTests')
$after = Get-TreeSnapshot -RootPath $Root
$caseOk = (Write-Check "tree snapshot is identical before/after -NoTests" ($before -eq $after)) -and $caseOk
if ($before -ne $after) {
    $beforeLines = @($before -split "`n")
    $afterLines = @($after -split "`n")
    $diff = @(Compare-Object -ReferenceObject $beforeLines -DifferenceObject $afterLines)
    foreach ($d in @($diff | Select-Object -First 5)) {
        Write-Host ("        diff: " + $d.SideIndicator + " " + $d.InputObject)
    }
}
Close-Case "e) read-only" $caseOk

# --- f) CRLF ----------------------------------------------------------------

Write-Host ""
Write-Host "CASE: f) doctor.ps1 uses CRLF only"
$caseOk = $true
$doctorRaw = [System.IO.File]::ReadAllText($Doctor, [System.Text.Encoding]::UTF8)
$bareLf = @([regex]::Matches($doctorRaw, "(?<!\r)\n")).Count
$caseOk = (Write-Check "no bare LF line endings" ($bareLf -eq 0) ("bareLF=" + $bareLf)) -and $caseOk
Close-Case "f) CRLF" $caseOk

# --- summary + cleanup ------------------------------------------------------

$totalChecks = $script:CheckPass + $script:CheckFail
$totalCases  = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: cases passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $totalCases)
Write-Host ("         checks passed=" + $script:CheckPass + " failed=" + $script:CheckFail + " total=" + $totalChecks)
Write-Host "=================================================="

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
