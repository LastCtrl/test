# test-compliance-gate.ps1 - regression harness for compliance-gate.ps1 (BUG-044).
#
# Covers the per-record parser contract:
#   (a) a valid record -> PASS, exit 0
#   (b) empty SKILLS_LOADED -> FAIL, exit 1
#   (c) a record WITHOUT the SKILLS_LOADED field -> FAIL (never "No records")
#   (d) two adjacent records, one invalid -> neither masks the other
#   (e) a placeholder/non-date stamp -> skip with WARN, counted in the summary
#
# Pure PowerShell 5.1 (no Pester), ASCII-only (AMSI / codepage safety).
# Every fixture is written under %TEMP%; the repository bus is never touched.
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Gate     = Join-Path $RepoRoot ".agents\scripts\compliance-gate.ps1"
$TestBase = Join-Path $env:TEMP "agent-hq-test-compliance-gate"

$script:Pass = 0
$script:Fail = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Add-Check {
    param([string]$Id, [bool]$Ok, [string]$Note)
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $label = if ($Ok) { "PASS" } else { "FAIL" }
    Write-Host ("[{0}] {1} - {2}" -f $label, $Id, $Note)
}

function New-CaseDir {
    $dir = Join-Path $TestBase ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Write-Fixture {
    param([string]$Dir, [string]$Text)
    $path = Join-Path $Dir "CONTEXT-BUFFER.md"
    [System.IO.File]::WriteAllText($path, $Text, $script:Utf8NoBom)
    return $path
}

# In-process gate call; `exit N` inside the child script sets $LASTEXITCODE.
function Invoke-Gate {
    param([string]$Path)
    $out = & $Gate -ReportPath $Path -LookbackHours 24 *>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

function Get-Stamp {
    return (Get-Date).ToString("yyyy-MM-dd HH:mm")
}

function New-Record {
    param(
        [string]$Stamp,
        [string]$Agent,
        [string]$Skills,
        [string]$Mcp,
        [string]$Compliance,
        [switch]$OmitSkills
    )
    $lines = @()
    $lines += "[$Stamp] $Agent -> team-lead:"
    $lines += "TYPE: update | PRIORITY: medium"
    $lines += "Project: fixture"
    $lines += "CONTENT: fixture record for regression"
    if (-not $OmitSkills) { $lines += "SKILLS_LOADED: $Skills" }
    $lines += "MCP_USED: $Mcp"
    $lines += "COMPLIANCE: $Compliance"
    $lines += "STATUS: resolved"
    return ($lines -join "`r`n")
}

function Count-Occurrence {
    param([string]$Text, [string]$Needle)
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

# --- main -------------------------------------------------------------------

Write-Host "=== agent-hq compliance-gate regression tests ==="
Write-Host ("Gate: " + $Gate)

if (-not (Test-Path -LiteralPath $Gate -PathType Leaf)) {
    Write-Host ("FATAL: not found: " + $Gate)
    exit 1
}
New-Item -ItemType Directory -Path $TestBase -Force | Out-Null

$GoodSkills = '["evidence-discipline"]'
$GoodMcp    = '["sequential-thinking"]'

try {

    # --- (a) valid record -> PASS ------------------------------------------
    $dir = New-CaseDir
    $stamp = Get-Stamp
    $path = Write-Fixture -Dir $dir -Text (New-Record -Stamp $stamp -Agent "dev-ok" -Skills $GoodSkills -Mcp $GoodMcp -Compliance "true")
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 0) -and ($r.Out -match '\[PASS\]') -and ($r.Out -match 'Passed: 1') -and ($r.Out -match 'Failed: 0')
    Add-Check 'a-valid-pass' $ok ("exit=$($r.Exit)")

    # --- (b) empty SKILLS_LOADED -> FAIL -----------------------------------
    $dir = New-CaseDir
    $path = Write-Fixture -Dir $dir -Text (New-Record -Stamp (Get-Stamp) -Agent "dev-empty" -Skills "[]" -Mcp $GoodMcp -Compliance "true")
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 1) -and ($r.Out -match '\[FAIL\]') -and ($r.Out -match 'SKILLS_LOADED empty') -and ($r.Out -match 'Failed: 1')
    Add-Check 'b-empty-skills-fail' $ok ("exit=$($r.Exit)")

    # --- (c) missing SKILLS_LOADED field -> FAIL (not "No records") --------
    $dir = New-CaseDir
    $path = Write-Fixture -Dir $dir -Text (New-Record -Stamp (Get-Stamp) -Agent "dev-missing" -Skills $GoodSkills -Mcp $GoodMcp -Compliance "true" -OmitSkills)
    $r = Invoke-Gate -Path $path
    $notNoRecords = -not ($r.Out -match 'No records')
    $ok = ($r.Exit -eq 1) -and ($r.Out -match '\[FAIL\]') -and ($r.Out -match 'SKILLS_LOADED missing') -and $notNoRecords
    Add-Check 'c-missing-skills-fail' $ok ("exit=$($r.Exit) notNoRecords=$notNoRecords")

    # --- (d1) bad then good: neither masks the other -----------------------
    $dir = New-CaseDir
    $bad  = New-Record -Stamp (Get-Stamp) -Agent "dev-bad"  -Skills "[]" -Mcp $GoodMcp -Compliance "true"
    $good = New-Record -Stamp (Get-Stamp) -Agent "dev-good" -Skills $GoodSkills -Mcp $GoodMcp -Compliance "true"
    $path = Write-Fixture -Dir $dir -Text ($bad + "`r`n`r`n" + $good)
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 1) -and ($r.Out -match 'Passed: 1') -and ($r.Out -match 'Failed: 1') -and
          ((Count-Occurrence -Text $r.Out -Needle '[FAIL]') -eq 1) -and ((Count-Occurrence -Text $r.Out -Needle '[PASS]') -eq 1)
    Add-Check 'd1-bad-then-good' $ok ("exit=$($r.Exit)")

    # --- (d2) good then bad: reverse order must behave the same ------------
    $dir = New-CaseDir
    $path = Write-Fixture -Dir $dir -Text ($good + "`r`n`r`n" + $bad)
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 1) -and ($r.Out -match 'Passed: 1') -and ($r.Out -match 'Failed: 1') -and
          ((Count-Occurrence -Text $r.Out -Needle '[FAIL]') -eq 1) -and ((Count-Occurrence -Text $r.Out -Needle '[PASS]') -eq 1)
    Add-Check 'd2-good-then-bad' $ok ("exit=$($r.Exit)")

    # --- (e1) placeholder stamp only -> skip with WARN, exit 0 -------------
    $dir = New-CaseDir
    $ph = New-Record -Stamp "TIME" -Agent "dev-ph" -Skills $GoodSkills -Mcp $GoodMcp -Compliance "true"
    $path = Write-Fixture -Dir $dir -Text $ph
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 0) -and ($r.Out -match '\[WARN\]') -and ($r.Out -match 'Placeholders skipped: 1') -and ($r.Out -match 'No records')
    Add-Check 'e1-placeholder-skip' $ok ("exit=$($r.Exit)")

    # --- (e2) placeholder + valid -> placeholder skipped, valid still PASS --
    $dir = New-CaseDir
    $valid = New-Record -Stamp (Get-Stamp) -Agent "dev-live" -Skills $GoodSkills -Mcp $GoodMcp -Compliance "true"
    $path = Write-Fixture -Dir $dir -Text ($ph + "`r`n`r`n" + $valid)
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 0) -and ($r.Out -match 'Placeholders skipped: 1') -and ($r.Out -match 'Passed: 1') -and ($r.Out -match 'Failed: 0')
    Add-Check 'e2-placeholder-plus-valid' $ok ("exit=$($r.Exit)")

    # --- (f) field-shaped text inside CONTENT must not count as a field ----
    # A record whose CONTENT quotes "COMPLIANCE:false" but whose real field is
    # true must still PASS (guards against matching embedded text).
    $dir = New-CaseDir
    $tricky = @()
    $tricky += "[" + (Get-Stamp) + "] dev-tricky -> team-lead:"
    $tricky += "TYPE: update | PRIORITY: medium"
    $tricky += "Project: fixture"
    $tricky += "CONTENT: example says COMPLIANCE:false inside the text"
    $tricky += "SKILLS_LOADED: $GoodSkills"
    $tricky += "MCP_USED: $GoodMcp"
    $tricky += "COMPLIANCE: true"
    $tricky += "STATUS: resolved"
    $path = Write-Fixture -Dir $dir -Text ($tricky -join "`r`n")
    $r = Invoke-Gate -Path $path
    $ok = ($r.Exit -eq 0) -and ($r.Out -match 'Passed: 1') -and ($r.Out -match 'Failed: 0')
    Add-Check 'f-embedded-field-text-ignored' $ok ("exit=$($r.Exit)")

} catch {
    Add-Check 'harness' $false ("unhandled exception: " + $_.Exception.Message)
} finally {
    if (Test-Path -LiteralPath $TestBase) {
        Remove-Item -LiteralPath $TestBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
