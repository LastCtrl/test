# test-ab-experiment.ps1 - independent tests for .agents\scripts\ab-experiment.ps1 (P3).
#
# Pure PowerShell 5.1 (no Pester). Every case runs against an ISOLATED temp root
# exposed through $env:AGENT_HQ_ROOT, so the real repository is never written to.
# The -Run cases drive ab-experiment.ps1 with a generated fake CLI, so the real
# `opencode` binary is never executed. The fake reads its behaviour out of the
# PROMPT argument (AB_FIXTURE_MODE=...), so the same binary succeeds for one
# variant and fails for another - which is what an A/B experiment must detect.
#
# Covered:
#   a) syntax + CRLF of ab-experiment.ps1
#   b) -Define           - experiment file with 2 variants, 0 runs
#   c) -Run -DryRun      - plan only, nothing written, engine not started
#   d) -Define guards    - bad id / no colon / duplicate label rejected
#   e) -Run              - good variant wins, attempts/failure-hit/exit codes recorded
#   f) -Status -Json     - ASCII JSON, metrics + winner
#   g) repeated -Run     - runs accumulate, winner stays stable
#   h) verdicts          - reviewer accept+reject -> disagreement metric captured
#   i) empty root        - -List says so, -List -Json is valid, no mode exits 2
#   j) broken data       - damaged/absent experiment does not crash
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Ab       = Join-Path $RepoRoot ".agents\scripts\ab-experiment.ps1"

$TempBase   = Join-Path $env:TEMP ("agent-hq-ab-tests\" + [guid]::NewGuid().ToString('N'))
$MainRoot   = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$EmptyRoot  = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$VerdictRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$BrokenRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$FakeCli    = Join-Path $TempBase "fake-ab-cli.ps1"
$TrackDry   = Join-Path $TempBase "track-dry"
$TrackRun1  = Join-Path $TempBase "track-run1"
$TrackRun2  = Join-Path $TempBase "track-run2"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

$ExperimentId = "ABMAIN"
$AgentName    = "dev-1"
$GoodPrompt   = "ab fixture AB_FIXTURE_MODE=good execute the fixture task"
$BadPrompt    = "ab fixture AB_FIXTURE_MODE=bad execute the fixture task"

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
    } else {
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

function Get-NonAsciiCount {
    param([string]$Text)
    return @([regex]::Matches([string]$Text, '[^\x00-\x7F]')).Count
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-Ab {
    param([string]$RootPath, [string[]]$Arguments = @())
    $env:AGENT_HQ_ROOT = $RootPath
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $full = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Ab) + @($Arguments)
    $text = (& $psExe @full 2>$null | Out-String)
    $code = $LASTEXITCODE
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

function Clear-CaseEnv {
    foreach ($name in @("AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "AGENT_HQ_OPENCODE_PATH",
                        "AGENT_HQ_JOB_TIMEOUT", "AGENT_HQ_NO_VAULT", "FAKE_AB_TRACK_DIR", "FAKE_OPENCODE_MODE")) {
        Remove-Item -Path ("Env:\" + $name) -ErrorAction SilentlyContinue
    }
}

function Get-TrackCount {
    param([string]$Dir, [string]$Mode)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
        if (([System.IO.File]::ReadAllText($file.FullName)).Trim() -eq $Mode) { $count++ }
    }
    return $count
}

function Get-ExperimentDocument {
    param([string]$RootPath, [string]$ExperimentId)
    return (Read-JsonFile -Path (Join-Path $RootPath (".memory\experiments\" + $ExperimentId + ".json")))
}

function Get-RunsByLabel {
    param($Document, [string]$Label)
    return @(@($Document.runs) | Where-Object { $null -ne $_ -and [string]$_.label -eq $Label })
}

function Get-MetricByLabel {
    param($Report, [string]$Label)
    foreach ($metric in @($Report.metrics)) {
        if ([string]$metric.label -eq $Label) { return $metric }
    }
    return $null
}

function New-VerdictBuffer {
    param([string]$RootPath, [string]$TaskKey)
    $separator = '=' * 80
    $lines = @(
        $separator,
        '[2026-09-17 10:00] qa-engineer -> team-lead:',
        'TYPE: update | PRIORITY: medium',
        ('CONTENT: independent review of task_id: ' + $TaskKey),
        'VERDICT: PASS',
        'STATUS: resolved',
        $separator,
        '[2026-09-17 10:05] code-reviewer -> team-lead:',
        'TYPE: update | PRIORITY: high',
        ('CONTENT: independent review of task_id: ' + $TaskKey),
        'VERDICT: REJECT',
        'STATUS: resolved',
        $separator
    )
    Write-TextFile -Path (Join-Path $RootPath 'CONTEXT-BUFFER.md') -Text ($lines -join "`r`n")
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($caseRoot in @($MainRoot, $EmptyRoot, $VerdictRoot, $BrokenRoot)) {
    foreach ($rel in @(".memory\evidence", ".memory\inbox", ".memory\outbox", ".memory\archive",
                       ".memory\dead-letter", ".memory\traces", ".memory\claims", ".agents\tasks")) {
        New-Item -ItemType Directory -Path (Join-Path $caseRoot $rel) -Force | Out-Null
    }
}

$fakeSource = @'
$mode = ''
foreach ($argument in @($args)) {
    if ([string]$argument -match 'AB_FIXTURE_MODE=([a-z]+)') { $mode = $Matches[1] }
}
if ($env:FAKE_AB_TRACK_DIR) {
    try {
        if (-not (Test-Path -LiteralPath $env:FAKE_AB_TRACK_DIR -PathType Container)) {
            New-Item -ItemType Directory -Path $env:FAKE_AB_TRACK_DIR -Force | Out-Null
        }
        $trackFile = Join-Path $env:FAKE_AB_TRACK_DIR ([guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($trackFile, $mode, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
switch ($mode) {
    'good' { Write-Output "TASK done.`nSTATUS: resolved"; exit 0 }
    'bad'  { Write-Output 'boom'; exit 1 }
    default { Write-Output 'fake-ab-cli: AB_FIXTURE_MODE marker missing'; exit 2 }
}
'@
Write-TextFile -Path $FakeCli -Text $fakeSource

Write-Host "=== agent-hq prompt A/B tests ==="
Write-Host ("Script : " + $Ab)
Write-Host ("Root   : " + $MainRoot)

if (-not (Test-Path -LiteralPath $Ab -PathType Leaf)) {
    Write-Host ("FATAL: ab-experiment.ps1 not found: " + $Ab)
    exit 1
}

# --- a) syntax + CRLF ------------------------------------------------------

$caseOk = $true
$syntaxErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Ab), [ref]$syntaxErrors)
$caseOk = (Write-Check "ab-experiment.ps1 parses with zero syntax errors" ($syntaxErrors.Count -eq 0) ("errors=" + $syntaxErrors.Count)) -and $caseOk

$rawScript = [System.IO.File]::ReadAllText($Ab)
$crlfCount = @([regex]::Matches($rawScript, "`r`n")).Count
$bareLfCount = @([regex]::Matches($rawScript, "(?<!`r)`n")).Count
$caseOk = (Write-Check "ab-experiment.ps1 uses CRLF (no bare LF)" (($crlfCount -gt 0) -and ($bareLfCount -eq 0)) ("crlf=" + $crlfCount + " bareLf=" + $bareLfCount)) -and $caseOk
Close-Case "a) syntax + CRLF" $caseOk

# --- b) define -------------------------------------------------------------

$caseOk = $true
$define = Invoke-Ab -RootPath $MainRoot -Arguments @("-Define", "-Id", $ExperimentId, "-Agent", $AgentName,
    "-Variant", ("good:" + $GoodPrompt), ("bad:" + $BadPrompt))
$caseOk = (Write-Check "define exit code is 0" ($define.code -eq 0) ("exit=" + $define.code + " out=" + $define.text)) -and $caseOk
$caseOk = (Write-Check "define announces both labels" (($define.text -match 'good') -and ($define.text -match 'bad'))) -and $caseOk
$caseOk = (Write-Check "define says it defined 2 variants" ($define.text -match 'defined: 2 variant')) -and $caseOk

$defineDoc = Get-ExperimentDocument -RootPath $MainRoot -ExperimentId $ExperimentId
$caseOk = (Write-Check "experiment file was written" ($null -ne $defineDoc)) -and $caseOk
if ($null -ne $defineDoc) {
    $caseOk = (Write-Check "stored id matches" ([string]$defineDoc.id -eq $ExperimentId)) -and $caseOk
    $caseOk = (Write-Check "stored agent matches" ([string]$defineDoc.agent -eq $AgentName)) -and $caseOk
    $caseOk = (Write-Check "stored 2 variants" (@($defineDoc.variants).Count -eq 2) ("count=" + @($defineDoc.variants).Count)) -and $caseOk
    $caseOk = (Write-Check "stored 0 runs" (@($defineDoc.runs).Count -eq 0) ("count=" + @($defineDoc.runs).Count)) -and $caseOk
    $caseOk = (Write-Check "variant prompts survive verbatim" (@(@($defineDoc.variants) | Where-Object { [string]$_.prompt -eq $GoodPrompt }).Count -eq 1)) -and $caseOk
}
Close-Case "b) define" $caseOk

# --- c) dry-run ------------------------------------------------------------

$caseOk = $true
$env:FAKE_AB_TRACK_DIR = $TrackDry
$dry = Invoke-Ab -RootPath $MainRoot -Arguments @("-Run", "-Id", $ExperimentId, "-Repeats", "2", "-DryRun")
$caseOk = (Write-Check "dry-run exit code is 0" ($dry.code -eq 0) ("exit=" + $dry.code + " out=" + $dry.text)) -and $caseOk
$caseOk = (Write-Check "dry-run says dry-run" ($dry.text -match 'dry-run')) -and $caseOk
$caseOk = (Write-Check "dry-run plans 4 runs for 2 repeats" ($dry.text -match 'planned runs: 4') ("out=" + $dry.text)) -and $caseOk
$caseOk = (Write-Check "dry-run names both labels" (($dry.text -match 'good') -and ($dry.text -match 'bad'))) -and $caseOk

$afterDry = Get-ExperimentDocument -RootPath $MainRoot -ExperimentId $ExperimentId
$caseOk = (Write-Check "dry-run added no runs" (@($afterDry.runs).Count -eq 0) ("count=" + @($afterDry.runs).Count)) -and $caseOk
$caseOk = (Write-Check "dry-run wrote no evidence" (@(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\evidence") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "dry-run wrote no inbox message" (@(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\inbox") -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "dry-run never started the CLI" (((Get-TrackCount -Dir $TrackDry -Mode "good") -eq 0) -and ((Get-TrackCount -Dir $TrackDry -Mode "bad") -eq 0))) -and $caseOk

$dryJson = Invoke-Ab -RootPath $MainRoot -Arguments @("-Run", "-Id", $ExperimentId, "-DryRun", "-Json")
$dryDoc = $null
try { $dryDoc = $dryJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $dryDoc = $null }
$caseOk = (Write-Check "dry-run json is valid" ($null -ne $dryDoc)) -and $caseOk
if ($null -ne $dryDoc) {
    $caseOk = (Write-Check "dry-run json mode is dry-run" ([string]$dryDoc.mode -eq "dry-run")) -and $caseOk
    $caseOk = (Write-Check "dry-run json is ASCII-only" ((Get-NonAsciiCount $dryJson.text) -eq 0)) -and $caseOk
}
Close-Case "c) dry-run" $caseOk

# --- d) define guards ------------------------------------------------------

$caseOk = $true
$badId = Invoke-Ab -RootPath $MainRoot -Arguments @("-Define", "-Id", "bad id", "-Agent", $AgentName, "-Variant", "a:prompt one")
$caseOk = (Write-Check "bad experiment id is rejected" ($badId.code -ne 0) ("exit=" + $badId.code)) -and $caseOk
$caseOk = (Write-Check "bad experiment id explains itself" ($badId.text -match 'rejected')) -and $caseOk

$noColon = Invoke-Ab -RootPath $MainRoot -Arguments @("-Define", "-Id", "ABNOCOLON", "-Agent", $AgentName, "-Variant", "prompt-without-label")
$caseOk = (Write-Check "variant without a colon is rejected" ($noColon.code -ne 0) ("exit=" + $noColon.code)) -and $caseOk
$caseOk = (Write-Check "rejected variant writes no file" (-not (Test-Path -LiteralPath (Join-Path $MainRoot ".memory\experiments\ABNOCOLON.json") -PathType Leaf))) -and $caseOk

$duplicate = Invoke-Ab -RootPath $MainRoot -Arguments @("-Define", "-Id", "ABDUP", "-Agent", $AgentName, "-Variant", "a:first", "a:second")
$caseOk = (Write-Check "duplicate label is rejected" ($duplicate.code -ne 0) ("exit=" + $duplicate.code)) -and $caseOk
$caseOk = (Write-Check "rejected duplicate writes no file" (-not (Test-Path -LiteralPath (Join-Path $MainRoot ".memory\experiments\ABDUP.json") -PathType Leaf))) -and $caseOk

$noVariant = Invoke-Ab -RootPath $MainRoot -Arguments @("-Define", "-Id", "ABNOVAR", "-Agent", $AgentName)
$caseOk = (Write-Check "define without variants is rejected" ($noVariant.code -ne 0) ("exit=" + $noVariant.code)) -and $caseOk
Close-Case "d) define guards" $caseOk

# --- e) real run with the fake CLI ----------------------------------------

$caseOk = $true
$env:AGENT_HQ_OPENCODE = $FakeCli
$env:AGENT_HQ_JOB_TIMEOUT = "90"
$env:FAKE_AB_TRACK_DIR = $TrackRun1
$run1 = Invoke-Ab -RootPath $MainRoot -Arguments @("-Run", "-Id", $ExperimentId, "-Repeats", "1", "-Json")
$caseOk = (Write-Check "run exit code is 0" ($run1.code -eq 0) ("exit=" + $run1.code + " out=" + $run1.text)) -and $caseOk

$runDoc1 = $null
try { $runDoc1 = $run1.text | ConvertFrom-Json -ErrorAction Stop } catch { $runDoc1 = $null }
$caseOk = (Write-Check "run json is valid" ($null -ne $runDoc1)) -and $caseOk
if ($null -ne $runDoc1) {
    $caseOk = (Write-Check "run json is ASCII-only" ((Get-NonAsciiCount $run1.text) -eq 0)) -and $caseOk
    $caseOk = (Write-Check "run json ok flag" ([bool]$runDoc1.ok -eq $true)) -and $caseOk
    $caseOk = (Write-Check "run json mode is run" ([string]$runDoc1.mode -eq "run")) -and $caseOk
    $caseOk = (Write-Check "run json executed 2 runs" ([int]$runDoc1.executed -eq 2) ("executed=" + [int]$runDoc1.executed)) -and $caseOk
    $caseOk = (Write-Check "run json runs_total is 2" ([int]$runDoc1.runs_total -eq 2) ("total=" + [int]$runDoc1.runs_total)) -and $caseOk

    $goodMetric = Get-MetricByLabel -Report $runDoc1 -Label "good"
    $badMetric = Get-MetricByLabel -Report $runDoc1 -Label "bad"
    $caseOk = (Write-Check "both variants have metrics" (($null -ne $goodMetric) -and ($null -ne $badMetric))) -and $caseOk
    if (($null -ne $goodMetric) -and ($null -ne $badMetric)) {
        $caseOk = (Write-Check "good variant success-rate is 1" ([double]$goodMetric.success_rate -eq 1) ("rate=" + [double]$goodMetric.success_rate)) -and $caseOk
        $caseOk = (Write-Check "bad variant success-rate is 0" ([double]$badMetric.success_rate -eq 0) ("rate=" + [double]$badMetric.success_rate)) -and $caseOk
    }

    $caseOk = (Write-Check "winner is the good variant" ([string]$runDoc1.winner.label -eq "good") ("winner=" + [string]$runDoc1.winner.label)) -and $caseOk
    $caseOk = (Write-Check "winner reason mentions the ordering" ([string]$runDoc1.winner.reason -match 'success-rate')) -and $caseOk

    $goodRuns = @(Get-RunsByLabel -Document $runDoc1 -Label "good")
    $badRuns = @(Get-RunsByLabel -Document $runDoc1 -Label "bad")
    $caseOk = (Write-Check "one stored run per variant" (($goodRuns.Count -eq 1) -and ($badRuns.Count -eq 1))) -and $caseOk
    if (($goodRuns.Count -eq 1) -and ($badRuns.Count -eq 1)) {
        $caseOk = (Write-Check "good run succeeded" ([bool]$goodRuns[0].success -eq $true)) -and $caseOk
        $caseOk = (Write-Check "good run engine status is done" ([string]$goodRuns[0].engine_status -eq "done") ("status=" + [string]$goodRuns[0].engine_status)) -and $caseOk
        $caseOk = (Write-Check "good run exit code is 0" ([string]$goodRuns[0].exit_code -eq "0") ("exit=" + [string]$goodRuns[0].exit_code)) -and $caseOk
        $caseOk = (Write-Check "good run made exactly 1 attempt" ([int]$goodRuns[0].attempts -eq 1) ("attempts=" + [int]$goodRuns[0].attempts)) -and $caseOk

        $caseOk = (Write-Check "bad run failed" ([bool]$badRuns[0].success -eq $false)) -and $caseOk
        $caseOk = (Write-Check "bad run was dead-lettered" ([string]$badRuns[0].engine_status -eq "dead-letter") ("status=" + [string]$badRuns[0].engine_status)) -and $caseOk
        $caseOk = (Write-Check "bad run made 2 attempts" ([int]$badRuns[0].attempts -eq 2) ("attempts=" + [int]$badRuns[0].attempts)) -and $caseOk
        $caseOk = (Write-Check "bad run exit code is 1" ([string]$badRuns[0].exit_code -eq "1") ("exit=" + [string]$badRuns[0].exit_code)) -and $caseOk
        $caseOk = (Write-Check "bad run confidence is below the good one" ([double]$badRuns[0].confidence -lt [double]$goodRuns[0].confidence) ("good=" + [double]$goodRuns[0].confidence + " bad=" + [double]$badRuns[0].confidence)) -and $caseOk
        $caseOk = (Write-Check "bad run hit failure memory" ([bool]$badRuns[0].failure_memory_hit -eq $true)) -and $caseOk
        $caseOk = (Write-Check "good run has no failure-memory hit" ([bool]$goodRuns[0].failure_memory_hit -eq $false)) -and $caseOk
        $caseOk = (Write-Check "runs carry a positive duration" ((([int]$goodRuns[0].duration_ms) -ge 0) -and (([int]$badRuns[0].duration_ms) -ge 0))) -and $caseOk
    }

    $caseOk = (Write-Check "deterministic run ids" ((@(@($runDoc1.runs) | Where-Object { [string]$_.run_id -eq "ABMAIN-good-n1" }).Count -eq 1) -and (@(@($runDoc1.runs) | Where-Object { [string]$_.run_id -eq "ABMAIN-bad-n1" }).Count -eq 1))) -and $caseOk
}
$caseOk = (Write-Check "CLI was called once for good" ((Get-TrackCount -Dir $TrackRun1 -Mode "good") -eq 1) ("count=" + (Get-TrackCount -Dir $TrackRun1 -Mode "good"))) -and $caseOk
$caseOk = (Write-Check "CLI was called twice for bad" ((Get-TrackCount -Dir $TrackRun1 -Mode "bad") -eq 2) ("count=" + (Get-TrackCount -Dir $TrackRun1 -Mode "bad"))) -and $caseOk
Close-Case "e) run" $caseOk

# --- f) status json --------------------------------------------------------

$caseOk = $true
$status = Invoke-Ab -RootPath $MainRoot -Arguments @("-Status", "-Id", $ExperimentId, "-Json")
$caseOk = (Write-Check "status exit code is 0" ($status.code -eq 0) ("exit=" + $status.code + " out=" + $status.text)) -and $caseOk
$caseOk = (Write-Check "status json is ASCII-only" ((Get-NonAsciiCount $status.text) -eq 0)) -and $caseOk
$statusDoc = $null
try { $statusDoc = $status.text | ConvertFrom-Json -ErrorAction Stop } catch { $statusDoc = $null }
$caseOk = (Write-Check "status json is valid" ($null -ne $statusDoc)) -and $caseOk
if ($null -ne $statusDoc) {
    $caseOk = (Write-Check "status json ok flag" ([bool]$statusDoc.ok -eq $true)) -and $caseOk
    $caseOk = (Write-Check "status json mode is status" ([string]$statusDoc.mode -eq "status") ("mode=" + [string]$statusDoc.mode)) -and $caseOk
    $caseOk = (Write-Check "status json keeps both variants" (@($statusDoc.variants).Count -eq 2)) -and $caseOk
    $caseOk = (Write-Check "status json keeps 2 runs" (@($statusDoc.runs).Count -eq 2)) -and $caseOk
    $caseOk = (Write-Check "status json winner is good" ([string]$statusDoc.winner.label -eq "good")) -and $caseOk
}

$statusHuman = Invoke-Ab -RootPath $MainRoot -Arguments @("-Status", "-Id", $ExperimentId)
$caseOk = (Write-Check "status human exit code is 0" ($statusHuman.code -eq 0)) -and $caseOk
$caseOk = (Write-Check "status human shows the winner" ($statusHuman.text -match 'winner') -and ($statusHuman.text -match 'good')) -and $caseOk
Close-Case "f) status" $caseOk

# --- g) repeated run accumulates ------------------------------------------

$caseOk = $true
$env:FAKE_AB_TRACK_DIR = $TrackRun2
$run2 = Invoke-Ab -RootPath $MainRoot -Arguments @("-Run", "-Id", $ExperimentId, "-Repeats", "1", "-Json")
$caseOk = (Write-Check "second run exit code is 0" ($run2.code -eq 0) ("exit=" + $run2.code + " out=" + $run2.text)) -and $caseOk
$runDoc2 = $null
try { $runDoc2 = $run2.text | ConvertFrom-Json -ErrorAction Stop } catch { $runDoc2 = $null }
$caseOk = (Write-Check "second run json is valid" ($null -ne $runDoc2)) -and $caseOk
if ($null -ne $runDoc2) {
    $caseOk = (Write-Check "runs accumulated to 4" ([int]$runDoc2.runs_total -eq 4) ("total=" + [int]$runDoc2.runs_total)) -and $caseOk
    $caseOk = (Write-Check "second run executed only 2 new runs" ([int]$runDoc2.executed -eq 2) ("executed=" + [int]$runDoc2.executed)) -and $caseOk
    $caseOk = (Write-Check "first results are still present" ((@(@($runDoc2.runs) | Where-Object { [string]$_.run_id -eq "ABMAIN-good-n1" }).Count -eq 1))) -and $caseOk
    $caseOk = (Write-Check "second sequence was used" ((@(@($runDoc2.runs) | Where-Object { [string]$_.run_id -eq "ABMAIN-good-n2" }).Count -eq 1))) -and $caseOk
    $caseOk = (Write-Check "winner is still the good variant" ([string]$runDoc2.winner.label -eq "good")) -and $caseOk

    $goodMetric2 = Get-MetricByLabel -Report $runDoc2 -Label "good"
    $badMetric2 = Get-MetricByLabel -Report $runDoc2 -Label "bad"
    if (($null -ne $goodMetric2) -and ($null -ne $badMetric2)) {
        $caseOk = (Write-Check "good success-rate stayed at 1" ([double]$goodMetric2.success_rate -eq 1)) -and $caseOk
        $caseOk = (Write-Check "bad success-rate stayed at 0" ([double]$badMetric2.success_rate -eq 0)) -and $caseOk
        $caseOk = (Write-Check "good metric counts 2 runs" ([int]$goodMetric2.runs -eq 2)) -and $caseOk
    }
}

$storedDoc = Get-ExperimentDocument -RootPath $MainRoot -ExperimentId $ExperimentId
$caseOk = (Write-Check "on-disk file also holds 4 runs" (@($storedDoc.runs).Count -eq 4) ("count=" + @($storedDoc.runs).Count)) -and $caseOk
Close-Case "g) accumulate" $caseOk

# --- h) reviewer verdicts / disagreement ----------------------------------

$caseOk = $true
$defineVerdict = Invoke-Ab -RootPath $VerdictRoot -Arguments @("-Define", "-Id", "ABVERDICT", "-Agent", $AgentName, "-Variant", ("v1:" + $GoodPrompt))
$caseOk = (Write-Check "verdict experiment defined" ($defineVerdict.code -eq 0) ("exit=" + $defineVerdict.code)) -and $caseOk
New-VerdictBuffer -RootPath $VerdictRoot -TaskKey "ABVERDICT-v1-n1"

$env:FAKE_AB_TRACK_DIR = (Join-Path $TempBase "track-verdict")
$verdictRun = Invoke-Ab -RootPath $VerdictRoot -Arguments @("-Run", "-Id", "ABVERDICT", "-Repeats", "1", "-Json")
$caseOk = (Write-Check "verdict run exit code is 0" ($verdictRun.code -eq 0) ("exit=" + $verdictRun.code + " out=" + $verdictRun.text)) -and $caseOk
$verdictDoc = $null
try { $verdictDoc = $verdictRun.text | ConvertFrom-Json -ErrorAction Stop } catch { $verdictDoc = $null }
$caseOk = (Write-Check "verdict run json is valid" ($null -ne $verdictDoc)) -and $caseOk
if ($null -ne $verdictDoc) {
    $verdictRuns = @(Get-RunsByLabel -Document $verdictDoc -Label "v1")
    $caseOk = (Write-Check "verdict experiment stored one run" ($verdictRuns.Count -eq 1) ("count=" + $verdictRuns.Count)) -and $caseOk
    if ($verdictRuns.Count -eq 1) {
        $stored = $verdictRuns[0]
        $caseOk = (Write-Check "run used the deterministic id" ([string]$stored.run_id -eq "ABVERDICT-v1-n1") ("id=" + [string]$stored.run_id)) -and $caseOk
        $caseOk = (Write-Check "accept verdict was captured" ([int]$stored.verdicts_accept -ge 1) ("accept=" + [int]$stored.verdicts_accept)) -and $caseOk
        $caseOk = (Write-Check "reject verdict was captured" ([int]$stored.verdicts_reject -ge 1) ("reject=" + [int]$stored.verdicts_reject)) -and $caseOk
        $caseOk = (Write-Check "reviewer disagreement is flagged" ([bool]$stored.reviewer_disagreement -eq $true)) -and $caseOk
        $caseOk = (Write-Check "mixed verdicts lowered confidence" ([double]$stored.confidence -lt 1) ("conf=" + [double]$stored.confidence)) -and $caseOk
        $caseOk = (Write-Check "confidence level is reported" (-not [string]::IsNullOrWhiteSpace([string]$stored.confidence_level)) ("level=" + [string]$stored.confidence_level)) -and $caseOk
        $caseOk = (Write-Check "verdict run still succeeded" ([bool]$stored.success -eq $true)) -and $caseOk
    }
}
Close-Case "h) verdicts" $caseOk

# --- i) empty root ---------------------------------------------------------

$caseOk = $true
$emptyList = Invoke-Ab -RootPath $EmptyRoot -Arguments @("-List")
$caseOk = (Write-Check "empty list exit code is 0" ($emptyList.code -eq 0) ("exit=" + $emptyList.code + " out=" + $emptyList.text)) -and $caseOk
$caseOk = (Write-Check "empty list says there are no experiments" ($emptyList.text -match 'no experiments')) -and $caseOk

$emptyJson = Invoke-Ab -RootPath $EmptyRoot -Arguments @("-List", "-Json")
$emptyDoc = $null
try { $emptyDoc = $emptyJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $emptyDoc = $null }
$caseOk = (Write-Check "empty list json is valid" ($null -ne $emptyDoc)) -and $caseOk
if ($null -ne $emptyDoc) {
    $caseOk = (Write-Check "empty list json holds no experiments" (@($emptyDoc.experiments).Count -eq 0) ("count=" + @($emptyDoc.experiments).Count)) -and $caseOk
}

$noMode = Invoke-Ab -RootPath $EmptyRoot -Arguments @("-Id", $ExperimentId)
$caseOk = (Write-Check "no mode exits 2" ($noMode.code -eq 2) ("exit=" + $noMode.code)) -and $caseOk
$caseOk = (Write-Check "no mode explains itself" ($noMode.text -match 'nothing to do')) -and $caseOk
Close-Case "i) empty root" $caseOk

# --- j) broken data --------------------------------------------------------

$caseOk = $true
$brokenPath = Join-Path $BrokenRoot ".memory\experiments\BROKEN.json"
Write-TextFile -Path $brokenPath -Text "{ this is not json at all"

$brokenStatus = Invoke-Ab -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "BROKEN")
$caseOk = (Write-Check "broken experiment exits non-zero" ($brokenStatus.code -ne 0) ("exit=" + $brokenStatus.code)) -and $caseOk
$caseOk = (Write-Check "broken experiment does not crash" (($brokenStatus.text -notmatch 'Exception') -and ($brokenStatus.text -notmatch 'internal error'))) -and $caseOk
$caseOk = (Write-Check "broken experiment explains itself" ($brokenStatus.text -match 'unreadable')) -and $caseOk

$brokenJson = Invoke-Ab -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "BROKEN", "-Json")
$brokenDoc = $null
try { $brokenDoc = $brokenJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $brokenDoc = $null }
$caseOk = (Write-Check "broken json output is still parseable" ($null -ne $brokenDoc)) -and $caseOk
if ($null -ne $brokenDoc) {
    $caseOk = (Write-Check "broken json output reports ok=false" ([bool]$brokenDoc.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "broken json output carries an error" (-not [string]::IsNullOrWhiteSpace([string]$brokenDoc.error))) -and $caseOk
}

$missingStatus = Invoke-Ab -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "MISSING")
$caseOk = (Write-Check "missing experiment exits non-zero" ($missingStatus.code -ne 0) ("exit=" + $missingStatus.code)) -and $caseOk
$caseOk = (Write-Check "missing experiment says not found" ($missingStatus.text -match 'not found')) -and $caseOk

$brokenList = Invoke-Ab -RootPath $BrokenRoot -Arguments @("-List")
$caseOk = (Write-Check "list survives a broken file" ($brokenList.code -eq 0) ("exit=" + $brokenList.code + " out=" + $brokenList.text)) -and $caseOk
$caseOk = (Write-Check "list marks the broken file" ($brokenList.text -match 'broken json')) -and $caseOk
Close-Case "j) broken data" $caseOk

# --- cleanup ---------------------------------------------------------------

Clear-CaseEnv
try {
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Host ""
Write-Host ("=== cases: " + $script:CasePass + " passed, " + $script:CaseFail + " failed ===")
if ($script:CaseFail -gt 0) { exit 1 }
exit 0
