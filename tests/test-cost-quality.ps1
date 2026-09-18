# test-cost-quality.ps1 - independent tests for the P3 cost/quality frontier.
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT and passed explicitly as -Root, so no
# repository state is read or written. The real script is dot-sourced (functions)
# and also invoked as a CLI (exit codes and output).
#
# Covered:
#   a) bar      - the cheapest candidate above the grade bar is recommended
#   b) frontier - the pareto table is built; low-sample rows are excluded
#   c) evidence - insufficient samples are flagged, never used to fake a pick
#   d) json     - CLI JSON is valid, deterministic and read-only
#   e) tolerance- empty/broken ratings, failures and passport never throw
#   f) cli      - -List / text / -Frontier / bad arguments exit codes
#   g) hygiene  - CRLF, ASCII, no BOM, parse-clean, no temp residue
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Script   = Join-Path $RepoRoot ".agents\scripts\cost-quality.ps1"

$TempBase     = Join-Path $env:TEMP "agent-hq-cost-quality-tests"
$Root         = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigDir    = Join-Path $Root ".agents\config"
$MemoryDir    = Join-Path $Root ".memory"
$PassportPath = Join-Path $ConfigDir "capability-passport.json"
$LimitsPath   = Join-Path $ConfigDir "model-limits.json"
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
        "dev-free-good"      = [ordered]@{ name = "dev-free-good"; role = "developer"; model = "vendor/model-free"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("code") } }
        "dev-free-penalized" = [ordered]@{ name = "dev-free-penalized"; role = "developer"; model = "vendor/model-free-b"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("code") } }
        "dev-paid-high"      = [ordered]@{ name = "dev-paid-high"; role = "developer"; model = "vendor/model-paid"; cost_tier = "paid"; capabilities = [ordered]@{ task_types = @("code") } }
        "dev-free-thin"      = [ordered]@{ name = "dev-free-thin"; role = "developer"; model = "vendor/model-thin"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("code") } }
        "data-free"          = [ordered]@{ name = "data-free"; role = "data-engineer"; model = "vendor/model-data"; cost_tier = "free"; capabilities = [ordered]@{ task_types = @("data") } }
        "ops-unknown"        = [ordered]@{ name = "ops-unknown"; role = "devops"; model = "vendor/model-unknown"; cost_tier = ""; capabilities = [ordered]@{ task_types = @("ops") } }
    }
    models     = [ordered]@{
        "vendor/model-modelonly" = [ordered]@{ cost_tier = ""; capabilities = [ordered]@{ task_types = @("code") } }
    }
}
[void](Write-JsonFile -Path $PassportPath -Object $fixturePassport)

$fixtureLimits = [ordered]@{
    version = 1
    models  = [ordered]@{
        "vendor/model-modelonly" = [ordered]@{ provider = "vendor"; tier = "free" }
        "vendor/model-free-b"    = [ordered]@{ provider = "vendor"; tier = "free" }
    }
}
[void](Write-JsonFile -Path $LimitsPath -Object $fixtureLimits)

$fixtureRatings = @(
    '{"model":"vendor/model-free","agent":"dev-free-good","task_type":"code","grade":9,"date":"2026-09-01"}',
    '{"model":"vendor/model-free","agent":"dev-free-good","task_type":"code","grade":9,"date":"2026-09-02"}',
    '{"model":"vendor/model-free-b","agent":"dev-free-penalized","task_type":"code","grade":10,"date":"2026-09-01"}',
    '{"model":"vendor/model-free-b","agent":"dev-free-penalized","task_type":"code","grade":10,"date":"2026-09-02"}',
    '{"model":"vendor/model-paid","agent":"dev-paid-high","task_type":"code","grade":9,"date":"2026-09-01"}',
    '{"model":"vendor/model-paid","agent":"dev-paid-high","task_type":"code","grade":10,"date":"2026-09-02"}',
    '{"model":"vendor/model-thin","agent":"dev-free-thin","task_type":"code","grade":10,"date":"2026-09-01"}',
    '{"model":"vendor/model-data","agent":"data-free","task_type":"data","grade":8,"date":"2026-09-01"}',
    '{"model":"vendor/model-data","agent":"data-free","task_type":"data","grade":8,"date":"2026-09-02"}',
    '{"model":"vendor/model-modelonly","agent":"","task_type":"code","grade":5,"date":"2026-09-01"}',
    '{"model":"vendor/model-modelonly","agent":"","task_type":"code","grade":5,"date":"2026-09-02"}'
)
[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))

$fixtureFailures = @(
    '{"signature":"code|kb-major","task_type":"code","agent":"dev-free-penalized","model":"vendor/model-free-b","reason_code":"kb-major","count":3,"fixed":false}',
    '{"signature":"code|kb-old","task_type":"code","agent":"dev-free-good","model":"vendor/model-free","reason_code":"kb-old","count":5,"fixed":true}',
    '{"signature":"data|kb-minor","task_type":"data","agent":"data-free","model":"vendor/model-data","reason_code":"kb-minor","count":1,"fixed":true}'
)
[void](Write-TextFile -Path $FailurePath -Text ($fixtureFailures -join "`n"))

$originalRoot = $env:AGENT_HQ_ROOT
$env:AGENT_HQ_ROOT = $Root

Write-Host "=== agent-hq cost/quality frontier tests ==="
Write-Host ("Script: " + $Script)
Write-Host ("Root  : " + $Root)

if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
    Write-Host ("FATAL: script not found: " + $Script)
    if ($null -ne $originalRoot) { $env:AGENT_HQ_ROOT = $originalRoot } else { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
    exit 1
}

. $Script

# --- a) bar: cheapest above the grade bar ------------------------------------

Write-Host ""
Write-Host "CASE: a) the cheapest candidate above the grade bar wins"
$caseOk = $true

$rec = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "the recommendation is ok" ($rec.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "the bar is met" ($rec.meets_min_grade -eq $true)) -and $caseOk
$caseOk = (Write-Check "a free agent is selected" (($rec.selected.kind -eq "agent") -and ($rec.selected.name -eq "dev-free-good"))) -and $caseOk
$caseOk = (Write-Check "the selected cost tier is free" ($rec.selected.cost_tier -eq "free")) -and $caseOk
$caseOk = (Write-Check "the selected quality is 9" ([double]$rec.selected.quality -eq 9)) -and $caseOk
$caseOk = (Write-Check "the selected grade is 9 over 2 samples" (([double]$rec.selected.avg_grade -eq 9) -and ($rec.selected.samples -eq 2))) -and $caseOk
$caseOk = (Write-Check "a fixed failure is not penalised" ([double]$rec.selected.failure_penalty -eq 0)) -and $caseOk
$caseOk = (Write-Check "the higher-quality paid candidate is not picked" ($rec.selected.cost_tier -ne "paid")) -and $caseOk
$caseOk = (Write-Check "the recommendation explains itself" ([string]$rec.reason -match "cheapest")) -and $caseOk

$built = Get-CostQualityCandidates -Root $Root -CanonicalType "code"
$penalized = @($built.candidates | Where-Object { $_.name -eq "dev-free-penalized" })[0]
$caseOk = (Write-Check "an open failure pinches the quality" ([double]$penalized.quality -eq 5.5)) -and $caseOk
$caseOk = (Write-Check "the open failure penalty is capped at 4.5" ([double]$penalized.failure_penalty -eq 4.5)) -and $caseOk
$caseOk = (Write-Check "the open failure count is reported" ([int]$penalized.failure_count -eq 3)) -and $caseOk

$modelOnly = @($built.candidates | Where-Object { $_.name -eq "vendor/model-modelonly" })[0]
$caseOk = (Write-Check "a model-only candidate is evaluated" ($null -ne $modelOnly)) -and $caseOk
$caseOk = (Write-Check "the cost tier falls back to model-limits" ($modelOnly.cost_tier -eq "free")) -and $caseOk

$unknown = @($built.candidates | Where-Object { $_.name -eq "ops-unknown" })[0]
$caseOk = (Write-Check "an unknown cost tier is marked, not guessed" ($unknown.cost_tier -eq "unknown")) -and $caseOk

$dataRec = Get-CostQualityRecommendation -TaskType "data" -MinGrade 7 -Root $Root
$caseOk = (Write-Check "a data task picks the data candidate" (($dataRec.ok -eq $true) -and ($dataRec.selected.name -eq "data-free"))) -and $caseOk
$caseOk = (Write-Check "the fixed data failure is ignored" ([double]$dataRec.selected.quality -eq 8)) -and $caseOk

$defaultRec = Get-CostQualityRecommendation -TaskType "code" -Root $Root
$caseOk = (Write-Check "the grade bar defaults when omitted" (([double]$defaultRec.min_grade -eq 6) -and ($defaultRec.min_grade_source -eq "default"))) -and $caseOk

Close-Case "a) bar" $caseOk

# --- b) frontier -------------------------------------------------------------

Write-Host ""
Write-Host "CASE: b) the cost/quality frontier is built"
$caseOk = $true

$matching = Get-CostQualityMatchingCandidates -Candidates $built.candidates -CanonicalType "code"
$frontier = Get-CostQualityFrontier -Candidates $matching
$caseOk = (Write-Check "the frontier has a point per cost tier" (@($frontier.rows).Count -eq 2)) -and $caseOk
$caseOk = (Write-Check "the cheapest point is free" ($frontier.rows[0].cost_tier -eq "free")) -and $caseOk
$caseOk = (Write-Check "the best free point is dev-free-good" ($frontier.rows[0].name -eq "dev-free-good")) -and $caseOk
$caseOk = (Write-Check "the next point is paid" ($frontier.rows[1].cost_tier -eq "paid")) -and $caseOk
$caseOk = (Write-Check "quality rises with cost" ([double]$frontier.rows[1].quality -gt [double]$frontier.rows[0].quality)) -and $caseOk
$caseOk = (Write-Check "the low-sample candidate is not a frontier point" (-not (@($frontier.rows | Where-Object { $_.name -eq "dev-free-thin" }).Count -gt 0))) -and $caseOk
$caseOk = (Write-Check "the excluded insufficient count is reported" ($frontier.excluded_insufficient -ge 1)) -and $caseOk

$frontierJson = (& $Script -Frontier -TaskType "code" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the frontier CLI exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$frontierParsed = $null
$frontierParses = $true
try { $frontierParsed = $frontierJson | ConvertFrom-Json } catch { $frontierParses = $false }
$caseOk = (Write-Check "the frontier JSON is valid" $frontierParses) -and $caseOk
$caseOk = (Write-Check "the frontier JSON is labelled" ($frontierParsed.mode -eq "frontier")) -and $caseOk
$caseOk = (Write-Check "the frontier JSON carries the rows" (@($frontierParsed.rows).Count -eq 2)) -and $caseOk

Close-Case "b) frontier" $caseOk

# --- c) insufficient evidence is marked, never faked -------------------------

Write-Host ""
Write-Host "CASE: c) insufficient evidence is flagged, not invented"
$caseOk = $true

$thin = @((Get-CostQualityCandidates -Root $Root -CanonicalType "code").candidates | Where-Object { $_.name -eq "dev-free-thin" })[0]
$caseOk = (Write-Check "a single-sample candidate is flagged low-sample" ($thin.data_state -eq "low-sample")) -and $caseOk
$caseOk = (Write-Check "its grade is still reported" ($null -ne $thin.avg_grade)) -and $caseOk

$near = Get-CostQualityRecommendation -TaskType "code" -MinGrade 9.8 -Root $Root
$caseOk = (Write-Check "no candidate meets the 9.8 bar" ($near.meets_min_grade -eq $false)) -and $caseOk
$caseOk = (Write-Check "the nearest evidence-backed candidate is returned" ($near.selected.name -eq "dev-paid-high")) -and $caseOk
$caseOk = (Write-Check "the nearest candidate has sufficient evidence" ($near.selected.data_state -eq "ok")) -and $caseOk
$caseOk = (Write-Check "the deficit is reported" ([double]$near.deficit -eq 0.3)) -and $caseOk
$warningText = (@($near.warnings) -join " | ")
$caseOk = (Write-Check "a warning names the missing bar" ($warningText -match "min_grade")) -and $caseOk
$caseOk = (Write-Check "a warning marks the skipped low-sample candidate" ($warningText -match "insufficient samples")) -and $caseOk
$caseOk = (Write-Check "the quality-10 low-sample candidate is not recommended" ($near.selected.name -ne "dev-free-thin")) -and $caseOk

Close-Case "c) evidence" $caseOk

# --- d) json, determinism and read-only --------------------------------------

Write-Host ""
Write-Host "CASE: d) the CLI JSON is valid, deterministic and read-only"
$caseOk = $true

$passportHashBefore = Get-FileHashHex -Path $PassportPath
$limitsHashBefore   = Get-FileHashHex -Path $LimitsPath
$ratingsHashBefore  = Get-FileHashHex -Path $RatingsPath
$failureHashBefore  = Get-FileHashHex -Path $FailurePath

$jsonText = (& $Script -TaskType "code" -MinGrade 8 -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the recommend CLI exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$parsed = $null
$parses = $true
try { $parsed = $jsonText | ConvertFrom-Json } catch { $parses = $false }
$caseOk = (Write-Check "the recommend JSON is valid" $parses) -and $caseOk
$caseOk = (Write-Check "the recommend JSON carries the pick" ($parsed.selected.name -eq "dev-free-good")) -and $caseOk
$caseOk = (Write-Check "the JSON declares read-only output" (($parsed.dry_run -eq $true) -and ($parsed.changed -eq $false))) -and $caseOk

$jsonText2 = (& $Script -TaskType "code" -MinGrade 8 -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the recommendation is deterministic" ($jsonText -eq $jsonText2)) -and $caseOk

$listJson = (& $Script -List -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the list CLI exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$listParsed = $null
$listParses = $true
try { $listParsed = $listJson | ConvertFrom-Json } catch { $listParses = $false }
$caseOk = (Write-Check "the list JSON is valid" $listParses) -and $caseOk
$caseOk = (Write-Check "the list JSON is labelled" ($listParsed.mode -eq "list")) -and $caseOk
$caseOk = (Write-Check "the list JSON carries candidates" (@($listParsed.candidates).Count -ge 5)) -and $caseOk

$caseOk = (Write-Check "the passport was not modified" ((Get-FileHashHex -Path $PassportPath) -eq $passportHashBefore)) -and $caseOk
$caseOk = (Write-Check "the limits were not modified" ((Get-FileHashHex -Path $LimitsPath) -eq $limitsHashBefore)) -and $caseOk
$caseOk = (Write-Check "the ratings were not modified" ((Get-FileHashHex -Path $RatingsPath) -eq $ratingsHashBefore)) -and $caseOk
$caseOk = (Write-Check "the failure memory was not modified" ((Get-FileHashHex -Path $FailurePath) -eq $failureHashBefore)) -and $caseOk

Close-Case "d) json and read-only" $caseOk

# --- e) tolerance ------------------------------------------------------------

Write-Host ""
Write-Host "CASE: e) empty, broken and missing sources never throw"
$caseOk = $true

[void](Write-TextFile -Path $RatingsPath -Text "")
$noGrades = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "no grades yields no selection" ($noGrades.ok -eq $false)) -and $caseOk
$caseOk = (Write-Check "no grades is reported explicitly" ($noGrades.reason -eq "no-quality-data")) -and $caseOk
$caseOk = (Write-Check "no grade data means no selected object" ($null -eq $noGrades.selected)) -and $caseOk
$caseOk = (Write-Check "the empty case explains itself" ((@($noGrades.notes) -join " | ") -match "no grade")) -and $caseOk

$noGradesCli = (& $Script -TaskType "code" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the empty case exits 1, not 2" ($LASTEXITCODE -eq 1)) -and $caseOk
$emptyParsed = $null
$emptyParses = $true
try { $emptyParsed = $noGradesCli | ConvertFrom-Json } catch { $emptyParses = $false }
$caseOk = (Write-Check "the empty case still emits valid JSON" ($emptyParses -and ($emptyParsed.ok -eq $false))) -and $caseOk

$brokenRatings = @($fixtureRatings) + @('this is not json', '{"grade":"nope"}')
[void](Write-TextFile -Path $RatingsPath -Text ($brokenRatings -join "`n"))
$tolerant = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "broken rating lines are skipped, the rest survives" ($tolerant.ok -eq $true)) -and $caseOk

$brokenFailures = @($fixtureFailures) + @('{ not json')
[void](Write-TextFile -Path $FailurePath -Text ($brokenFailures -join "`n"))
$tolerant2 = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "a broken failure line never throws" ($tolerant2.ok -eq $true)) -and $caseOk

$passportBackup = [System.IO.File]::ReadAllText($PassportPath, [System.Text.Encoding]::UTF8)
[void](Write-TextFile -Path $PassportPath -Text "{ this is not valid json")
$brokenRec = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "a broken passport is reported" ($brokenRec.passport -eq "broken")) -and $caseOk
$brokenCli = (& $Script -TaskType "code" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a broken passport exits 2" ($LASTEXITCODE -eq 2)) -and $caseOk
$brokenJsonParsed = $null
$brokenJsonParses = $true
try { $brokenJsonParsed = $brokenCli | ConvertFrom-Json } catch { $brokenJsonParses = $false }
$caseOk = (Write-Check "a broken passport still emits valid JSON" ($brokenJsonParses -and ($brokenJsonParsed.ok -eq $false))) -and $caseOk

Remove-Item -LiteralPath $PassportPath -Force
$missingRec = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "a missing passport is reported" ($missingRec.passport -eq "missing")) -and $caseOk
$missingCli = (& $Script -List -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a missing passport exits 2" ($LASTEXITCODE -eq 2)) -and $caseOk
$missingFrontier = (& $Script -Frontier -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "the frontier mode also exits 2" ($LASTEXITCODE -eq 2)) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text "{}")
$emptyPassport = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "an empty passport never throws" ($emptyPassport.ok -eq $false)) -and $caseOk
$caseOk = (Write-Check "an empty passport reports no candidates" ($emptyPassport.reason -eq "no-matching-candidates")) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text $passportBackup)
[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))
[void](Write-TextFile -Path $FailurePath -Text ($fixtureFailures -join "`n"))
$restored = Get-CostQualityRecommendation -TaskType "code" -MinGrade 8 -Root $Root
$caseOk = (Write-Check "the fixtures are restored cleanly" ($restored.selected.name -eq "dev-free-good")) -and $caseOk

Close-Case "e) tolerance" $caseOk

# --- f) command line ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: f) the command line paths"
$caseOk = $true

$listOutput = (& $Script -List -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-List exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-List prints the header" ($listOutput -match "COST/QUALITY CANDIDATES")) -and $caseOk
$caseOk = (Write-Check "-List shows a candidate row" ($listOutput -match "dev-free-good")) -and $caseOk

$textOutput = (& $Script -TaskType "code" -MinGrade 8 -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "text mode exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "text mode prints the recommendation" ($textOutput -match "COST/QUALITY RECOMMENDATION")) -and $caseOk
$caseOk = (Write-Check "text mode prints the pick" ($textOutput -match "dev-free-good")) -and $caseOk

$frontierText = (& $Script -Frontier -TaskType "code" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "frontier text exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "frontier text prints the table" ($frontierText -match "COST -> QUALITY FRONTIER")) -and $caseOk

$helpOutput = (& $Script -Help -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Help exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-Help prints usage" ($helpOutput -match "cost-quality.ps1")) -and $caseOk

$badArg = (& $Script -NoSuchFlag -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "an unknown argument exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$noTask = (& $Script -MinGrade 8 -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a missing task type exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$badGrade = (& $Script -TaskType "code" -MinGrade "abc" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a non-numeric grade exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

$badSamples = (& $Script -TaskType "code" -MinSamples 0 -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "a zero sample floor exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

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
$caseOk = (Write-Check "the test file avoids the forbidden substring" ((@([regex]::Matches($rawTest, [regex]::Escape($forbiddenToken))).Count) -eq 0)) -and $caseOk

$residue = @(Get-ChildItem -LiteralPath $ConfigDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "no temp residue next to the config" ($residue.Count -eq 0)) -and $caseOk
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
