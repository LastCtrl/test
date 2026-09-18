# test-team-optimizer.ps1 - independent tests for the P3 team optimizer.
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT and passed explicitly as -Root, so no
# repository state is read or written and no provider quota is touched. The real
# script is dot-sourced (functions) and also invoked as a CLI (exit codes/output).
#
# Covered:
#   a) risk     - the verifier line-up grows with risk (low < med < high)
#   b) filters  - capability mismatch and cost ceiling reject candidates
#   c) failures - an open failure-memory signature lowers the executor candidate
#   d) json     - the CLI -Json output is valid and read-only
#   e) tolerance- missing/broken passport, empty ratings/failures: no throw
#   f) cli      - -List / text / -Json / unknown argument exit codes
#   g) hygiene  - CRLF, ASCII, no BOM, parse-clean, no temp residue
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Script   = Join-Path $RepoRoot ".agents\scripts\team-optimizer.ps1"

$TempBase   = Join-Path $env:TEMP "agent-hq-team-optimizer-tests"
$Root       = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigDir  = Join-Path $Root ".agents\config"
$MemoryDir  = Join-Path $Root ".memory"
$PassportPath = Join-Path $ConfigDir "capability-passport.json"
$RatingsPath  = Join-Path $MemoryDir "ratings.jsonl"
$FailurePath  = Join-Path $MemoryDir "failure-memory.jsonl"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) { Write-Host ("    ok  : " + $Label) } else { Write-Host ("    FAIL: " + $Label) }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $normalized = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $script:Utf8NoBom)
    return $Path
}

function Write-JsonFile {
    param([string]$Path, $Object)
    return (Write-TextFile -Path $Path -Text ((ConvertTo-Json -InputObject $Object -Depth 10) -replace "`r`n", "`n"))
}

function Get-FileHashHex {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Fixtures -------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) { New-Item -ItemType Directory -Path $TempBase -Force | Out-Null }
foreach ($rel in @(".agents\config", ".memory")) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}

$fixturePassport = [ordered]@{
    version    = 1
    updated_at = "2026-09-01T00:00:00"
    agents     = [ordered]@{
        "dev-alpha"      = [ordered]@{ name = "dev-alpha"; role = "developer"; model = "vendor/model-a"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("code") } }
        "dev-beta"       = [ordered]@{ name = "dev-beta"; role = "developer"; model = "vendor/model-b"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("code") } }
        "dev-gamma"      = [ordered]@{ name = "dev-gamma"; role = "developer"; model = "vendor/model-c"; cost_tier = "paid"; capabilities = [ordered]@{ task_types = @("code") } }
        "data-x"         = [ordered]@{ name = "data-x"; role = "data-engineer"; model = "vendor/model-d"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("data") } }
        "qa-empty"       = [ordered]@{ name = "qa-empty"; role = "qa-engineer"; model = "vendor/model-e"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("test") } }
        "reviewer-x"     = [ordered]@{ name = "reviewer-x"; role = "code-reviewer"; model = "vendor/model-f"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("review") } }
        "sec-x"          = [ordered]@{ name = "sec-x"; role = "security-auditor"; model = "vendor/model-g"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("security") } }
        "sec-y"          = [ordered]@{ name = "sec-y"; role = "security-auditor"; model = "vendor/model-i"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("security") } }
        "orchestrator-x" = [ordered]@{ name = "orchestrator-x"; role = "orchestrator"; model = "vendor/model-h"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("orchestration") } }
    }
    models     = [ordered]@{}
}
[void](Write-JsonFile -Path $PassportPath -Object $fixturePassport)

$fixtureRatings = @(
    '{"model":"vendor/model-a","agent":"dev-alpha","task_type":"code","grade":9,"date":"2026-09-01"}',
    '{"model":"vendor/model-a","agent":"dev-alpha","task_type":"code","grade":9,"date":"2026-09-02"}',
    '{"model":"vendor/model-b","agent":"dev-beta","task_type":"code","grade":7,"date":"2026-09-01"}',
    '{"model":"vendor/model-b","agent":"dev-beta","task_type":"code","grade":7,"date":"2026-09-02"}',
    '{"model":"vendor/model-c","agent":"dev-gamma","task_type":"code","grade":6,"date":"2026-09-01"}',
    '{"model":"vendor/model-e","agent":"qa-empty","task_type":"test","grade":8,"date":"2026-09-01"}',
    '{"model":"vendor/model-e","agent":"qa-empty","task_type":"test","grade":8,"date":"2026-09-02"}',
    '{"model":"vendor/model-f","agent":"reviewer-x","task_type":"review","grade":9,"date":"2026-09-01"}',
    '{"model":"vendor/model-g","agent":"sec-x","task_type":"security","grade":8,"date":"2026-09-01"}',
    '{"model":"vendor/model-i","agent":"sec-y","task_type":"security","grade":7,"date":"2026-09-01"}',
    '{"model":"vendor/model-h","agent":"orchestrator-x","task_type":"orchestration","grade":5,"date":"2026-09-01"}'
)
[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))

$fixtureFailures = @(
    '{"signature":"code|kb-critical","task_type":"code","agent":"dev-alpha","model":"vendor/model-a","reason_code":"kb-critical","count":3,"fixed":false}',
    '{"signature":"code|kb-old","task_type":"code","agent":"dev-alpha","model":"vendor/model-a","reason_code":"kb-old","count":5,"fixed":true}',
    '{"signature":"code|noise","task_type":"code","agent":"dev-beta","model":"vendor/model-b","reason_code":"noise","count":0,"fixed":false}',
    '{"signature":"review|reviewer-reject","task_type":"review","agent":"reviewer-x","model":"vendor/model-f","reason_code":"reviewer-reject","count":1,"fixed":false}'
)
[void](Write-TextFile -Path $FailurePath -Text ($fixtureFailures -join "`n"))

$originalRoot = $env:AGENT_HQ_ROOT
$env:AGENT_HQ_ROOT = $Root

Write-Host "=== agent-hq team optimizer tests ==="
Write-Host ("Script: " + $Script)
Write-Host ("Root  : " + $Root)

if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
    Write-Host ("FATAL: script not found: " + $Script)
    if ($null -ne $originalRoot) { $env:AGENT_HQ_ROOT = $originalRoot } else { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
    exit 1
}

. $Script

# --- a) risk profiles --------------------------------------------------------

Write-Host ""
Write-Host "CASE: a) the verifier line-up grows with the risk level"
$caseOk = $true

$low = Get-TeamRecommendation -TaskType "code" -Risk "low" -Root $Root
$caseOk = (Write-Check "low recommendation is ok" ($low.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "an executor is recommended" (@($low.executors).Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "the executor is a code-capable agent" ($low.executors[0].name -eq "dev-beta")) -and $caseOk
$lowTypes = @($low.verifiers | ForEach-Object { $_.verifies })
$caseOk = (Write-Check "low risk verifies with qa" ($lowTypes -contains "test")) -and $caseOk
$caseOk = (Write-Check "low risk needs no security reviewer" (-not ($lowTypes -contains "security"))) -and $caseOk

$med = Get-TeamRecommendation -TaskType "code" -Risk "med" -Root $Root
$medTypes = @($med.verifiers | ForEach-Object { $_.verifies })
$caseOk = (Write-Check "med risk adds a code reviewer" ($medTypes -contains "review")) -and $caseOk

$high = Get-TeamRecommendation -TaskType "code" -Risk "high" -Root $Root
$highTypes = @($high.verifiers | ForEach-Object { $_.verifies })
$caseOk = (Write-Check "high risk adds a security reviewer" ($highTypes -contains "security")) -and $caseOk
$caseOk = (Write-Check "high risk verifier count is the largest" (@($high.verifiers).Count -gt @($low.verifiers).Count)) -and $caseOk
$highNames = @($high.verifiers | ForEach-Object { $_.name })
$caseOk = (Write-Check "the qa verifier is the declared qa role" ($highNames -contains "qa-empty")) -and $caseOk
$caseOk = (Write-Check "the review verifier is the declared reviewer role" ($highNames -contains "reviewer-x")) -and $caseOk
$caseOk = (Write-Check "the security verifier is the declared auditor role" ($highNames -contains "sec-x")) -and $caseOk
$caseOk = (Write-Check "the recommendation explains itself" ([string]$high.reason -match "code/high risk")) -and $caseOk

$security = Get-TeamRecommendation -TaskType "security" -Risk "low" -Root $Root
$secTypes = @($security.verifiers | ForEach-Object { $_.verifies })
$caseOk = (Write-Check "a security task always adds a security verifier" ($secTypes -contains "security")) -and $caseOk

Close-Case "a) risk profiles" $caseOk

# --- b) capability and cost filters ------------------------------------------

Write-Host ""
Write-Host "CASE: b) capability mismatch and the cost ceiling reject candidates"
$caseOk = $true

$rec = Get-TeamRecommendation -TaskType "code" -Risk "med" -Root $Root
$dataRejected = @($rec.rejected | Where-Object { $_.name -eq "data-x" })[0]
$caseOk = (Write-Check "a non-matching capability is rejected" ($dataRejected.reason -eq "capability-mismatch")) -and $caseOk
$caseOk = (Write-Check "the mismatch names the declared types" ([string]$dataRejected.detail -match "data")) -and $caseOk
$caseOk = (Write-Check "the executor declares the requested capability" (@($rec.executors[0].declared) -contains "code")) -and $caseOk

$freeRec = Get-TeamRecommendation -TaskType "code" -Risk "med" -MaxCostTier "free" -Root $Root
$gammaRejected = @($freeRec.rejected | Where-Object { $_.name -eq "dev-gamma" })[0]
$caseOk = (Write-Check "a paid candidate is rejected under a free ceiling" ($gammaRejected.reason -eq "cost-tier-above-max")) -and $caseOk

$paidRec = Get-TeamRecommendation -TaskType "code" -Risk "med" -MaxCostTier "paid" -Size 3 -Root $Root
$caseOk = (Write-Check "a paid ceiling keeps paid candidates" (-not (@($paidRec.rejected | Where-Object { $_.name -eq "dev-gamma" -and $_.reason -eq "cost-tier-above-max" }).Count -gt 0))) -and $caseOk
$caseOk = (Write-Check "size selects several executors" (@($paidRec.executors).Count -eq 3)) -and $caseOk

Close-Case "b) filters" $caseOk

# --- c) failure memory lowers a candidate ------------------------------------

Write-Host ""
Write-Host "CASE: c) an open failure signature lowers the affected candidate"
$caseOk = $true

$withFailures = Get-TeamRecommendation -TaskType "code" -Risk "low" -Root $Root
$alphaRejected = @($withFailures.rejected | Where-Object { $_.name -eq "dev-alpha" })[0]
$caseOk = (Write-Check "the penalised candidate loses to the healthy one" ($withFailures.executors[0].name -eq "dev-beta")) -and $caseOk
$caseOk = (Write-Check "the penalised candidate is listed with a reason" ($alphaRejected.reason -eq "lower-ranked")) -and $caseOk
$caseOk = (Write-Check "the failure penalty is reported" ([double]$alphaRejected.failure_penalty -eq 4.5)) -and $caseOk
$caseOk = (Write-Check "fixed failures are not counted" ([int]$alphaRejected.failure_count -eq 3)) -and $caseOk

Rename-Item -LiteralPath $FailurePath -NewName "failure-memory.jsonl.off"
$withoutFailures = Get-TeamRecommendation -TaskType "code" -Risk "low" -Root $Root
Rename-Item -LiteralPath (Join-Path $MemoryDir "failure-memory.jsonl.off") -NewName "failure-memory.jsonl"
$caseOk = (Write-Check "without failure data the stronger candidate wins" ($withoutFailures.executors[0].name -eq "dev-alpha")) -and $caseOk
$caseOk = (Write-Check "the failure penalty disappears" ([double]$withoutFailures.executors[0].failure_penalty -eq 0)) -and $caseOk

Close-Case "c) failure memory" $caseOk

# --- d) json and read-only ---------------------------------------------------

Write-Host ""
Write-Host "CASE: d) the CLI -Json output is valid and nothing is written"
$caseOk = $true

$passportHashBefore = Get-FileHashHex -Path $PassportPath
$ratingsHashBefore = Get-FileHashHex -Path $RatingsPath

$jsonText = (& $Script -TaskType "code" -Risk "high" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Json exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$parsed = $null
$parses = $true
try { $parsed = $jsonText | ConvertFrom-Json } catch { $parses = $false }
$caseOk = (Write-Check "-Json is valid JSON" $parses) -and $caseOk
$caseOk = (Write-Check "-Json carries an executor" (@($parsed.executors).Count -ge 1)) -and $caseOk
$caseOk = (Write-Check "-Json carries the verifiers" (@($parsed.verifiers).Count -ge 1)) -and $caseOk
$jsonVerifies = @($parsed.verifiers | ForEach-Object { $_.verifies })
$caseOk = (Write-Check "-Json verifiers honour the risk" ($jsonVerifies -contains "security")) -and $caseOk
$caseOk = (Write-Check "-Json reports it never changes anything" (($parsed.dry_run -eq $true) -and ($parsed.changed -eq $false))) -and $caseOk
$caseOk = (Write-Check "the passport was not modified" ((Get-FileHashHex -Path $PassportPath) -eq $passportHashBefore)) -and $caseOk
$caseOk = (Write-Check "the ratings were not modified" ((Get-FileHashHex -Path $RatingsPath) -eq $ratingsHashBefore)) -and $caseOk

$firstJson = (& $Script -TaskType "code" -Risk "high" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the recommendation is deterministic" ($firstJson -eq $jsonText)) -and $caseOk

Close-Case "d) json and read-only" $caseOk

# --- e) tolerance ------------------------------------------------------------

Write-Host ""
Write-Host "CASE: e) missing, broken and empty sources never throw"
$caseOk = $true

$passportBackup = [System.IO.File]::ReadAllText($PassportPath, [System.Text.Encoding]::UTF8)

[void](Write-TextFile -Path $PassportPath -Text "{ this is not valid json")
$broken = Get-TeamRecommendation -TaskType "code" -Risk "high" -Root $Root
$caseOk = (Write-Check "a broken passport is reported" ($broken.passport -eq "broken")) -and $caseOk
$caseOk = (Write-Check "a broken passport yields no executor" (@($broken.executors).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "a broken passport does not throw" ($broken.ok -eq $false)) -and $caseOk
$caseOk = (Write-Check "the parse error is surfaced" (@($broken.notes).Count -ge 1)) -and $caseOk

Remove-Item -LiteralPath $PassportPath -Force
$missing = Get-TeamRecommendation -TaskType "code" -Risk "high" -Root $Root
$caseOk = (Write-Check "a missing passport is reported" ($missing.passport -eq "missing")) -and $caseOk
$caseOk = (Write-Check "a missing passport yields no executor" (@($missing.executors).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "the missing-passport reason is stable" ($missing.reason -eq "passport-missing")) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text $passportBackup)
[void](Write-TextFile -Path $RatingsPath -Text "")
[void](Write-TextFile -Path $FailurePath -Text "")

$empty = Get-TeamRecommendation -TaskType "code" -Risk "low" -Root $Root
$caseOk = (Write-Check "empty ratings still produce a recommendation" ($empty.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "an executor is still chosen" (@($empty.executors).Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "empty data falls back to the neutral grade" ($null -eq $empty.executors[0].avg_grade)) -and $caseOk

[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))
[void](Write-TextFile -Path $FailurePath -Text ($fixtureFailures -join "`n"))

Close-Case "e) tolerance" $caseOk

# --- f) command line ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: f) the command line paths"
$caseOk = $true

$listOutput = (& $Script -List -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-List exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-List prints the passport agents" ($listOutput -match "PASSPORT AGENTS")) -and $caseOk
$caseOk = (Write-Check "-List shows an agent row" ($listOutput -match "dev-alpha")) -and $caseOk

$textOutput = (& $Script -TaskType "code" -Risk "high" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "text mode exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "text mode prints the executors" ($textOutput -match "EXECUTORS")) -and $caseOk
$caseOk = (Write-Check "text mode prints the verifiers" ($textOutput -match "VERIFIERS")) -and $caseOk
$caseOk = (Write-Check "text mode prints the rejected list" ($textOutput -match "REJECTED")) -and $caseOk

$dryOutput = (& $Script -TaskType "code" -Risk "low" -DryRun -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-DryRun -Json exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$dryParsed = $null
$dryParses = $true
try { $dryParsed = $dryOutput | ConvertFrom-Json } catch { $dryParses = $false }
$caseOk = (Write-Check "-DryRun output is valid JSON" ($dryParses -and ($dryParsed.dry_run -eq $true))) -and $caseOk

$badArg = (& $Script -NoSuchFlag -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "an unknown argument exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$noTask = (& $Script -Risk "high" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a missing task type exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$zeroSize = (& $Script -TaskType "code" -Risk "low" -Size 0 -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a zero size exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$bigSize = (& $Script -TaskType "code" -Risk "low" -Size 11 -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a size above the range exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk
$caseOk = (Write-Check "a size above the range prints the usage" ($bigSize -match "team-optimizer.ps1 - recommend")) -and $caseOk
$caseOk = (Write-Check "a size above the range has no raw range exception" (-not ($bigSize -match "ValidateRange|ParameterBindingValidationException"))) -and $caseOk

Close-Case "f) command line" $caseOk

# --- g) hygiene --------------------------------------------------------------

Write-Host ""
Write-Host "CASE: g) script hygiene and a clean working tree"
$caseOk = $true

$rawScript = [System.IO.File]::ReadAllText($Script, [System.Text.Encoding]::UTF8)
$caseOk = (Write-Check "the script uses CRLF" ($rawScript.Contains("`r`n"))) -and $caseOk
$caseOk = (Write-Check "the script has no bare LF" (-not ($rawScript.Replace("`r`n", "") -match "`n"))) -and $caseOk
$caseOk = (Write-Check "the script has no BOM" (-not ($rawScript.Length -gt 0 -and [int][char]$rawScript[0] -eq 0xFEFF))) -and $caseOk
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize($rawScript, [ref]$parseErrors)
$caseOk = (Write-Check "the script parses without errors" ($parseErrors.Count -eq 0)) -and $caseOk
$forbiddenToken = ([string][char]0x73) + ([string][char]0x6b) + "-"
$caseOk = (Write-Check "the script avoids the forbidden key-like substring" ((@([regex]::Matches($rawScript, [regex]::Escape($forbiddenToken))).Count) -eq 0)) -and $caseOk

$rawTest = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
$caseOk = (Write-Check "the test file uses CRLF" ($rawTest.Contains("`r`n"))) -and $caseOk
$caseOk = (Write-Check "the test file has no bare LF" (-not ($rawTest.Replace("`r`n", "") -match "`n"))) -and $caseOk

$residue = @(Get-ChildItem -LiteralPath $ConfigDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "no temp residue next to the passport" ($residue.Count -eq 0)) -and $caseOk
$memoryResidue = @(Get-ChildItem -LiteralPath $MemoryDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.off" })
$caseOk = (Write-Check "no temp residue in .memory" ($memoryResidue.Count -eq 0)) -and $caseOk

Close-Case "g) hygiene" $caseOk

# --- summary + cleanup -------------------------------------------------------

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

if ($null -ne $originalRoot) { $env:AGENT_HQ_ROOT = $originalRoot } else { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
if (@(Get-ChildItem -LiteralPath $TempBase -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
