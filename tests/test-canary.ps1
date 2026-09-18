# test-canary.ps1 - independent tests for .agents\scripts\canary.ps1 (P3).
#
# Pure PowerShell 5.1 (no Pester). Every case runs against an ISOLATED temp root
# exposed through $env:AGENT_HQ_ROOT, so the real repository is never written to.
# The -Run -Execute cases drive canary.ps1 with a generated fake CLI
# (AGENT_HQ_OPENCODE), so the real opencode binary is never executed. The fake
# reads CANARY_FIXTURE=good|bad out of the prompt, so one arm can succeed while
# the other fails - which is exactly what a canary rollout must detect.
#
# Covered:
#   a) syntax + CRLF of canary.ps1
#   b) -Define        - state file, stages, 0 runs, status defined
#   c) -Run (default) - dry-run: plan only, no engine run, no writes
#   d) -Define guards - id / agent / change / value / stages rejected, no mode
#   e) -Run -Execute  - both arms through the engine, metrics captured
#   f) -Status -Json  - ASCII JSON, metrics + promotion verdict
#   g) -Promote       - good canary promotes stage by stage to complete
#   h) bad canary     - stop with a reason, then -Rollback, then locked
#   i) empty root     - missing rollout reports itself, no crash
#   j) broken data    - damaged state file does not crash the tool
#   k) -Stages        - custom stage list is stored and reported
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Canary   = Join-Path $RepoRoot ".agents\scripts\canary.ps1"

$TempBase   = Join-Path $env:TEMP ("agent-hq-canary-tests\" + [guid]::NewGuid().ToString('N'))
$MainRoot   = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$BadRoot    = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$EmptyRoot  = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$BrokenRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$StageRoot  = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$FakeCli    = Join-Path $TempBase "fake-canary-cli.ps1"
$TrackDry   = Join-Path $TempBase "track-dry"
$TrackRun   = Join-Path $TempBase "track-run"
$TrackBad   = Join-Path $TempBase "track-bad"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

$AgentName = "dev-1"
$BaselineGood = "canary fixture CANARY_FIXTURE=good baseline arm"
$CanaryGood   = "canary fixture CANARY_FIXTURE=good canary arm"
$CanaryBad    = "canary fixture CANARY_FIXTURE=bad canary arm"

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

function ConvertTo-JsonSafe {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-Canary {
    param([string]$RootPath, [string[]]$Arguments = @())
    $env:AGENT_HQ_ROOT = $RootPath
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $full = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Canary) + @($Arguments)
    $text = (& $psExe @full 2>$null | Out-String)
    $code = $LASTEXITCODE
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

function Clear-CaseEnv {
    foreach ($name in @("AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "AGENT_HQ_OPENCODE_PATH",
                        "AGENT_HQ_JOB_TIMEOUT", "AGENT_HQ_NO_VAULT", "FAKE_CANARY_TRACK_DIR")) {
        Remove-Item -Path ("Env:\" + $name) -ErrorAction SilentlyContinue
    }
}

function Get-TrackCount {
    param([string]$Dir, [string]$Key, [string]$Mode)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
        $content = ([System.IO.File]::ReadAllText($file.FullName)).Trim()
        $expected = if ([string]::IsNullOrWhiteSpace($Mode)) { $Key } else { $Key + ":" + $Mode }
        if ($content -eq $expected) { $count++ }
    }
    return $count
}

function Get-CanaryDocument {
    param([string]$RootPath, [string]$Id)
    return (Read-JsonFile -Path (Join-Path $RootPath (".memory\canary\" + $Id + ".json")))
}

function Get-MetricByArm {
    param($Report, [string]$Arm)
    foreach ($metric in @($Report.metrics)) {
        if ([string]$metric.arm -eq $Arm) { return $metric }
    }
    return $null
}

function Get-RunsByArm {
    param($Document, [string]$Arm)
    return @(@($Document.runs) | Where-Object { $null -ne $_ -and [string]$_.arm -eq $Arm })
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($caseRoot in @($MainRoot, $BadRoot, $EmptyRoot, $BrokenRoot, $StageRoot)) {
    foreach ($rel in @(".memory\evidence", ".memory\inbox", ".memory\outbox", ".memory\archive",
                       ".memory\dead-letter", ".memory\traces", ".memory\claims", ".agents\tasks")) {
        New-Item -ItemType Directory -Path (Join-Path $caseRoot $rel) -Force | Out-Null
    }
}

$fakeSource = @'
$mode = ''
$arm = ''
foreach ($argument in @($args)) {
    if ([string]$argument -match 'CANARY_FIXTURE=([a-z]+)') { $mode = $Matches[1] }
    if ([string]$argument -match 'CANARY_ARM=([a-z]+)') { $arm = $Matches[1] }
}
if ($env:FAKE_CANARY_TRACK_DIR) {
    try {
        if (-not (Test-Path -LiteralPath $env:FAKE_CANARY_TRACK_DIR -PathType Container)) {
            New-Item -ItemType Directory -Path $env:FAKE_CANARY_TRACK_DIR -Force | Out-Null
        }
        $trackFile = Join-Path $env:FAKE_CANARY_TRACK_DIR ([guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($trackFile, ($arm + ':' + $mode), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
switch ($mode) {
    'good' { Write-Output "TASK done.`nSTATUS: resolved"; exit 0 }
    'bad'  { Write-Output 'boom'; exit 1 }
    default { Write-Output 'fake-canary-cli: CANARY_FIXTURE marker missing'; exit 2 }
}
'@
Write-TextFile -Path $FakeCli -Text $fakeSource

Write-Host "=== agent-hq canary rollout tests ==="
Write-Host ("Script : " + $Canary)
Write-Host ("Root   : " + $MainRoot)

if (-not (Test-Path -LiteralPath $Canary -PathType Leaf)) {
    Write-Host ("FATAL: canary.ps1 not found: " + $Canary)
    exit 1
}

# --- a) syntax + CRLF ------------------------------------------------------

$caseOk = $true
$syntaxErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Canary), [ref]$syntaxErrors)
$caseOk = (Write-Check "canary.ps1 parses with zero syntax errors" ($syntaxErrors.Count -eq 0) ("errors=" + $syntaxErrors.Count)) -and $caseOk

$rawScript = [System.IO.File]::ReadAllText($Canary)
$crlfCount = @([regex]::Matches($rawScript, "`r`n")).Count
$bareLfCount = @([regex]::Matches($rawScript, "(?<!`r)`n")).Count
$caseOk = (Write-Check "canary.ps1 uses CRLF (no bare LF)" (($crlfCount -gt 0) -and ($bareLfCount -eq 0)) ("crlf=" + $crlfCount + " bareLf=" + $bareLfCount)) -and $caseOk
Close-Case "a) syntax + CRLF" $caseOk

# --- b) define -------------------------------------------------------------

$caseOk = $true
$define = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CG", "-Agent", $AgentName,
    "-Change", "prompt", "-Value", $CanaryGood, "-Baseline", $BaselineGood)
$caseOk = (Write-Check "define exit code is 0" ($define.code -eq 0) ("exit=" + $define.code + " out=" + $define.text)) -and $caseOk
$caseOk = (Write-Check "define says it defined the rollout" ($define.text -match 'defined:')) -and $caseOk

$defineDoc = Get-CanaryDocument -RootPath $MainRoot -Id "CG"
$caseOk = (Write-Check "state file was written" ($null -ne $defineDoc)) -and $caseOk
if ($null -ne $defineDoc) {
    $caseOk = (Write-Check "stored id matches" ([string]$defineDoc.id -eq "CG")) -and $caseOk
    $caseOk = (Write-Check "stored agent matches" ([string]$defineDoc.agent -eq $AgentName)) -and $caseOk
    $caseOk = (Write-Check "stored change kind matches" ([string]$defineDoc.change -eq "prompt")) -and $caseOk
    $caseOk = (Write-Check "canary value survives verbatim" ([string]$defineDoc.value -eq $CanaryGood)) -and $caseOk
    $caseOk = (Write-Check "baseline survives verbatim" ([string]$defineDoc.baseline -eq $BaselineGood)) -and $caseOk
    $caseOk = (Write-Check "default stages are 1,2,3" ((@($defineDoc.stages).Count -eq 3) -and ([int]@($defineDoc.stages)[0] -eq 1) -and ([int]@($defineDoc.stages)[2] -eq 3)) ("stages=" + (@($defineDoc.stages) -join ","))) -and $caseOk
    $caseOk = (Write-Check "status starts as defined" ([string]$defineDoc.status -eq "defined")) -and $caseOk
    $caseOk = (Write-Check "no runs yet" (@($defineDoc.runs).Count -eq 0) ("count=" + @($defineDoc.runs).Count)) -and $caseOk
}

$defineJson = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CG", "-Agent", $AgentName,
    "-Change", "prompt", "-Value", $CanaryGood, "-Baseline", $BaselineGood, "-Json")
$defineJsonDoc = ConvertTo-JsonSafe $defineJson.text
$caseOk = (Write-Check "define -Json is parseable" ($null -ne $defineJsonDoc) ("exit=" + $defineJson.code + " out=" + $defineJson.text)) -and $caseOk
$caseOk = (Write-Check "define -Json is ASCII-only" ((Get-NonAsciiCount $defineJson.text) -eq 0) ("nonascii=" + (Get-NonAsciiCount $defineJson.text))) -and $caseOk
Close-Case "b) define" $caseOk

# --- c) dry-run ------------------------------------------------------------

$caseOk = $true
$env:AGENT_HQ_OPENCODE = $FakeCli
$env:AGENT_HQ_JOB_TIMEOUT = "90"
$env:FAKE_CANARY_TRACK_DIR = $TrackDry
$dry = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG")
$caseOk = (Write-Check "dry-run exit code is 0" ($dry.code -eq 0) ("exit=" + $dry.code + " out=" + $dry.text)) -and $caseOk
$caseOk = (Write-Check "dry-run says dry-run" ($dry.text -match 'dry-run')) -and $caseOk
$caseOk = (Write-Check "dry-run plans 2 runs (one per arm)" ($dry.text -match 'planned runs 2') ("out=" + $dry.text)) -and $caseOk
$caseOk = (Write-Check "dry-run names both arms" (($dry.text -match 'baseline') -and ($dry.text -match 'canary'))) -and $caseOk

$dryJson = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG", "-Json")
$dryDoc = ConvertTo-JsonSafe $dryJson.text
$caseOk = (Write-Check "dry-run json is valid" ($null -ne $dryDoc)) -and $caseOk
if ($null -ne $dryDoc) {
    $caseOk = (Write-Check "dry-run json mode is dry-run" ([string]$dryDoc.mode -eq "dry-run")) -and $caseOk
    $caseOk = (Write-Check "dry-run json is ASCII-only" ((Get-NonAsciiCount $dryJson.text) -eq 0)) -and $caseOk
    $caseOk = (Write-Check "dry-run json planned 2" (@($dryDoc.planned).Count -eq 2) ("planned=" + @($dryDoc.planned).Count)) -and $caseOk
}

$afterDry = Get-CanaryDocument -RootPath $MainRoot -Id "CG"
$caseOk = (Write-Check "dry-run added no runs" (@($afterDry.runs).Count -eq 0) ("count=" + @($afterDry.runs).Count)) -and $caseOk
$caseOk = (Write-Check "dry-run wrote no evidence" (@(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\evidence") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "dry-run wrote no inbox message" (@(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\inbox") -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "dry-run never started the CLI" ((Get-TrackCount -Dir $TrackDry -Key "baseline" -Mode "good") -eq 0)) -and $caseOk
Close-Case "c) dry-run" $caseOk

# --- d) define guards ------------------------------------------------------

$caseOk = $true
$canaryDirCount = @(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\canary") -Filter '*.json' -File -ErrorAction SilentlyContinue).Count

$badId = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "bad id", "-Agent", $AgentName, "-Change", "prompt", "-Value", "x")
$caseOk = (Write-Check "bad id is rejected" ($badId.code -ne 0) ("exit=" + $badId.code)) -and $caseOk
$caseOk = (Write-Check "bad id explains itself" ($badId.text -match 'rejected')) -and $caseOk

$badAgent = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CGA", "-Agent", "", "-Change", "prompt", "-Value", "x")
$caseOk = (Write-Check "empty agent is rejected" ($badAgent.code -ne 0) ("exit=" + $badAgent.code)) -and $caseOk

$badChange = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CGC", "-Agent", $AgentName, "-Change", "banana", "-Value", "x")
$caseOk = (Write-Check "unknown change kind is rejected" ($badChange.code -ne 0) ("exit=" + $badChange.code)) -and $caseOk
$caseOk = (Write-Check "unknown change kind names the vocabulary" ($badChange.text -match 'model')) -and $caseOk

$noValue = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CGV", "-Agent", $AgentName, "-Change", "prompt", "-Value", "")
$caseOk = (Write-Check "empty value is rejected" ($noValue.code -ne 0) ("exit=" + $noValue.code)) -and $caseOk

$badStages = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CGS", "-Agent", $AgentName, "-Change", "prompt", "-Value", "x", "-Stages", "3,1")
$caseOk = (Write-Check "non-ascending stages are rejected" ($badStages.code -ne 0) ("exit=" + $badStages.code)) -and $caseOk

$badRange = Invoke-Canary -RootPath $MainRoot -Arguments @("-Define", "-Id", "CGR", "-Agent", $AgentName, "-Change", "prompt", "-Value", "x", "-Stages", "0,150")
$caseOk = (Write-Check "out-of-range stages are rejected" ($badRange.code -ne 0) ("exit=" + $badRange.code)) -and $caseOk

$afterGuards = @(Get-ChildItem -LiteralPath (Join-Path $MainRoot ".memory\canary") -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
$caseOk = (Write-Check "rejected defines wrote no new file" ($afterGuards -eq $canaryDirCount) ("before=" + $canaryDirCount + " after=" + $afterGuards)) -and $caseOk

$noMode = Invoke-Canary -RootPath $MainRoot -Arguments @("-Id", "CG")
$caseOk = (Write-Check "no mode exits 2" ($noMode.code -eq 2) ("exit=" + $noMode.code)) -and $caseOk
$caseOk = (Write-Check "no mode explains itself" ($noMode.text -match 'nothing to do')) -and $caseOk
Close-Case "d) define guards" $caseOk

# --- e) execute the good canary -------------------------------------------

$caseOk = $true
$env:FAKE_CANARY_TRACK_DIR = $TrackRun
$run1 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG", "-Execute", "-Json")
$caseOk = (Write-Check "execute exit code is 0" ($run1.code -eq 0) ("exit=" + $run1.code + " out=" + $run1.text)) -and $caseOk
$runDoc1 = ConvertTo-JsonSafe $run1.text
$caseOk = (Write-Check "execute json is valid" ($null -ne $runDoc1)) -and $caseOk
if ($null -ne $runDoc1) {
    $caseOk = (Write-Check "execute json is ASCII-only" ((Get-NonAsciiCount $run1.text) -eq 0)) -and $caseOk
    $caseOk = (Write-Check "execute json mode is run" ([string]$runDoc1.mode -eq "run")) -and $caseOk
    $caseOk = (Write-Check "execute json executed 2 runs" ([int]$runDoc1.executed -eq 2) ("executed=" + [int]$runDoc1.executed)) -and $caseOk
    $caseOk = (Write-Check "execute json runs_total is 2" ([int]$runDoc1.runs_total -eq 2) ("total=" + [int]$runDoc1.runs_total)) -and $caseOk

    $baseMetric = Get-MetricByArm -Report $runDoc1 -Arm "baseline"
    $canaMetric = Get-MetricByArm -Report $runDoc1 -Arm "canary"
    $caseOk = (Write-Check "both arms have metrics" (($null -ne $baseMetric) -and ($null -ne $canaMetric))) -and $caseOk
    if (($null -ne $baseMetric) -and ($null -ne $canaMetric)) {
        $caseOk = (Write-Check "baseline success-rate is 1" ([double]$baseMetric.success_rate -eq 1) ("rate=" + [double]$baseMetric.success_rate)) -and $caseOk
        $caseOk = (Write-Check "canary success-rate is 1" ([double]$canaMetric.success_rate -eq 1) ("rate=" + [double]$canaMetric.success_rate)) -and $caseOk
        $caseOk = (Write-Check "canary confidence is recorded" ([double]$canaMetric.avg_confidence -gt 0) ("conf=" + [double]$canaMetric.avg_confidence)) -and $caseOk
    }
    $caseOk = (Write-Check "promotion verdict is ok" ([bool]$runDoc1.promotion.ok -eq $true) ("reason=" + [string]$runDoc1.promotion.reason)) -and $caseOk

    $baseRuns = @(Get-RunsByArm -Document $runDoc1 -Arm "baseline")
    $canaRuns = @(Get-RunsByArm -Document $runDoc1 -Arm "canary")
    $caseOk = (Write-Check "one stored run per arm" (($baseRuns.Count -eq 1) -and ($canaRuns.Count -eq 1))) -and $caseOk
    if (($baseRuns.Count -eq 1) -and ($canaRuns.Count -eq 1)) {
        $caseOk = (Write-Check "baseline run succeeded" ([bool]$baseRuns[0].success -eq $true)) -and $caseOk
        $caseOk = (Write-Check "baseline run engine status is done" ([string]$baseRuns[0].engine_status -eq "done") ("status=" + [string]$baseRuns[0].engine_status)) -and $caseOk
        $caseOk = (Write-Check "baseline run exit code is 0" ([string]$baseRuns[0].exit_code -eq "0") ("exit=" + [string]$baseRuns[0].exit_code)) -and $caseOk
        $caseOk = (Write-Check "canary run succeeded" ([bool]$canaRuns[0].success -eq $true)) -and $caseOk
        $caseOk = (Write-Check "runs carry the current stage" ((([int]$baseRuns[0].stage) -eq 1) -and (([int]$canaRuns[0].stage) -eq 1))) -and $caseOk
        $caseOk = (Write-Check "runs carry a duration" ((([int]$baseRuns[0].duration_ms) -ge 0) -and (([int]$canaRuns[0].duration_ms) -ge 0))) -and $caseOk
        $caseOk = (Write-Check "failure memory is recorded per run" (($null -ne $baseRuns[0].failure_memory_hit) -and ($null -ne $canaRuns[0].failure_memory_hit))) -and $caseOk
    }
    $caseOk = (Write-Check "deterministic run ids" ((@(@($runDoc1.runs) | Where-Object { [string]$_.run_id -eq "CG-baseline-s1-n1" }).Count -eq 1) -and (@(@($runDoc1.runs) | Where-Object { [string]$_.run_id -eq "CG-canary-s1-n1" }).Count -eq 1))) -and $caseOk
}
$caseOk = (Write-Check "CLI was called once for the baseline arm" ((Get-TrackCount -Dir $TrackRun -Key "baseline" -Mode "good") -eq 1) ("count=" + (Get-TrackCount -Dir $TrackRun -Key "baseline" -Mode "good"))) -and $caseOk
$caseOk = (Write-Check "CLI was called once for the canary arm" ((Get-TrackCount -Dir $TrackRun -Key "canary" -Mode "good") -eq 1) ("count=" + (Get-TrackCount -Dir $TrackRun -Key "canary" -Mode "good"))) -and $caseOk
Close-Case "e) execute" $caseOk

# --- f) status json --------------------------------------------------------

$caseOk = $true
$status = Invoke-Canary -RootPath $MainRoot -Arguments @("-Status", "-Id", "CG", "-Json")
$caseOk = (Write-Check "status exit code is 0" ($status.code -eq 0) ("exit=" + $status.code + " out=" + $status.text)) -and $caseOk
$caseOk = (Write-Check "status json is ASCII-only" ((Get-NonAsciiCount $status.text) -eq 0)) -and $caseOk
$statusDoc = ConvertTo-JsonSafe $status.text
$caseOk = (Write-Check "status json is valid" ($null -ne $statusDoc)) -and $caseOk
if ($null -ne $statusDoc) {
    $caseOk = (Write-Check "status json ok flag" ([bool]$statusDoc.ok -eq $true)) -and $caseOk
    $caseOk = (Write-Check "status json mode is status" ([string]$statusDoc.mode -eq "status")) -and $caseOk
    $caseOk = (Write-Check "status json keeps 2 runs" (@($statusDoc.runs).Count -eq 2) ("runs=" + @($statusDoc.runs).Count)) -and $caseOk
    $caseOk = (Write-Check "status json has 2 arm metrics" (@($statusDoc.metrics).Count -eq 2)) -and $caseOk
    $caseOk = (Write-Check "status json promotion is ok" ([bool]$statusDoc.promotion.ok -eq $true)) -and $caseOk
    $caseOk = (Write-Check "status json stage is the first one" ([int]$statusDoc.stage_index -eq 0)) -and $caseOk
}

$statusHuman = Invoke-Canary -RootPath $MainRoot -Arguments @("-Status", "-Id", "CG")
$caseOk = (Write-Check "status human exit code is 0" ($statusHuman.code -eq 0)) -and $caseOk
$caseOk = (Write-Check "status human shows the promotion verdict" ($statusHuman.text -match 'promotion: OK')) -and $caseOk
Close-Case "f) status" $caseOk

# --- g) promote through every stage ---------------------------------------

$caseOk = $true
$promote1 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Promote", "-Id", "CG", "-Json")
$caseOk = (Write-Check "promote exit code is 0" ($promote1.code -eq 0) ("exit=" + $promote1.code + " out=" + $promote1.text)) -and $caseOk
$promote1Doc = ConvertTo-JsonSafe $promote1.text
if ($null -ne $promote1Doc) {
    $caseOk = (Write-Check "promote json mode is promote" ([string]$promote1Doc.mode -eq "promote")) -and $caseOk
    $caseOk = (Write-Check "promote advanced to stage index 1" ([int]$promote1Doc.stage_index -eq 1) ("index=" + [int]$promote1Doc.stage_index)) -and $caseOk
    $caseOk = (Write-Check "promote set status running" ([string]$promote1Doc.status -eq "running") ("status=" + [string]$promote1Doc.status)) -and $caseOk
    $caseOk = (Write-Check "history recorded the promotion" (@(@($promote1Doc.history) | Where-Object { [string]$_.action -eq "promote" }).Count -ge 1)) -and $caseOk
}

$stage2 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG", "-Execute", "-Json")
$stage2Doc = ConvertTo-JsonSafe $stage2.text
$caseOk = (Write-Check "stage 2 run exit code is 0" ($stage2.code -eq 0) ("exit=" + $stage2.code)) -and $caseOk
if ($null -ne $stage2Doc) {
    $caseOk = (Write-Check "stage 2 uses one repeat per arm" ([int]$stage2Doc.repeats -eq 1) ("repeats=" + [int]$stage2Doc.repeats)) -and $caseOk
    $caseOk = (Write-Check "stage 2 accumulated 4 runs" ([int]$stage2Doc.runs_total -eq 4) ("total=" + [int]$stage2Doc.runs_total)) -and $caseOk
}

$promote2 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Promote", "-Id", "CG", "-Json")
$promote2Doc = ConvertTo-JsonSafe $promote2.text
$caseOk = (Write-Check "second promote exit code is 0" ($promote2.code -eq 0) ("exit=" + $promote2.code)) -and $caseOk
if ($null -ne $promote2Doc) {
    $caseOk = (Write-Check "second promote advanced to stage index 2" ([int]$promote2Doc.stage_index -eq 2) ("index=" + [int]$promote2Doc.stage_index)) -and $caseOk
}

$stage3 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG", "-Execute", "-Json")
$stage3Doc = ConvertTo-JsonSafe $stage3.text
$caseOk = (Write-Check "stage 3 run exit code is 0" ($stage3.code -eq 0) ("exit=" + $stage3.code)) -and $caseOk
if ($null -ne $stage3Doc) {
    $caseOk = (Write-Check "stage 3 accumulated 6 runs" ([int]$stage3Doc.runs_total -eq 6) ("total=" + [int]$stage3Doc.runs_total)) -and $caseOk
}

$promote3 = Invoke-Canary -RootPath $MainRoot -Arguments @("-Promote", "-Id", "CG", "-Json")
$promote3Doc = ConvertTo-JsonSafe $promote3.text
$caseOk = (Write-Check "final promote exit code is 0" ($promote3.code -eq 0) ("exit=" + $promote3.code + " out=" + $promote3.text)) -and $caseOk
if ($null -ne $promote3Doc) {
    $caseOk = (Write-Check "rollout is complete" ([string]$promote3Doc.status -eq "promoted") ("status=" + [string]$promote3Doc.status)) -and $caseOk
}

$runAfterComplete = Invoke-Canary -RootPath $MainRoot -Arguments @("-Run", "-Id", "CG", "-Execute")
$caseOk = (Write-Check "run after completion exits non-zero" ($runAfterComplete.code -ne 0) ("exit=" + $runAfterComplete.code)) -and $caseOk
$caseOk = (Write-Check "run after completion says complete" ($runAfterComplete.text -match 'complete')) -and $caseOk

$storedMain = Get-CanaryDocument -RootPath $MainRoot -Id "CG"
$caseOk = (Write-Check "state file keeps all 6 runs" (@($storedMain.runs).Count -eq 6) ("count=" + @($storedMain.runs).Count)) -and $caseOk
$caseOk = (Write-Check "stage 3 run was used" ((@(@($storedMain.runs) | Where-Object { [string]$_.run_id -eq "CG-canary-s3-n1" }).Count -eq 1))) -and $caseOk
Close-Case "g) promote" $caseOk

# --- h) bad canary: stop and rollback --------------------------------------

$caseOk = $true
$env:FAKE_CANARY_TRACK_DIR = $TrackBad
$badDefine = Invoke-Canary -RootPath $BadRoot -Arguments @("-Define", "-Id", "CB", "-Agent", $AgentName,
    "-Change", "prompt", "-Value", $CanaryBad, "-Baseline", $BaselineGood)
$caseOk = (Write-Check "bad-canary define exit code is 0" ($badDefine.code -eq 0) ("exit=" + $badDefine.code)) -and $caseOk

$earlyPromote = Invoke-Canary -RootPath $BadRoot -Arguments @("-Promote", "-Id", "CB")
$caseOk = (Write-Check "promote without runs exits non-zero" ($earlyPromote.code -ne 0) ("exit=" + $earlyPromote.code)) -and $caseOk
$caseOk = (Write-Check "promote without runs says so" ($earlyPromote.text -match 'no runs yet')) -and $caseOk
$stillDefined = Get-CanaryDocument -RootPath $BadRoot -Id "CB"
$caseOk = (Write-Check "failed promote left the status alone" ([string]$stillDefined.status -eq "defined") ("status=" + [string]$stillDefined.status)) -and $caseOk

$badRun = Invoke-Canary -RootPath $BadRoot -Arguments @("-Run", "-Id", "CB", "-Execute", "-Json")
$badRunDoc = ConvertTo-JsonSafe $badRun.text
$caseOk = (Write-Check "bad-canary run exit code is 0" ($badRun.code -eq 0) ("exit=" + $badRun.code)) -and $caseOk
if ($null -ne $badRunDoc) {
    $badMetric = Get-MetricByArm -Report $badRunDoc -Arm "canary"
    $baseMetric2 = Get-MetricByArm -Report $badRunDoc -Arm "baseline"
    if (($null -ne $badMetric) -and ($null -ne $baseMetric2)) {
        $caseOk = (Write-Check "canary success-rate is 0" ([double]$badMetric.success_rate -eq 0) ("rate=" + [double]$badMetric.success_rate)) -and $caseOk
        $caseOk = (Write-Check "baseline success-rate stays 1" ([double]$baseMetric2.success_rate -eq 1)) -and $caseOk
        $caseOk = (Write-Check "canary failure memory was hit" ([int]$badMetric.failure_hits -ge 1) ("hits=" + [int]$badMetric.failure_hits)) -and $caseOk
    }
    $caseOk = (Write-Check "promotion verdict is not ok" ([bool]$badRunDoc.promotion.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "promotion verdict blames the success-rate" ([string]$badRunDoc.promotion.reason -match 'success-rate')) -and $caseOk
}

$badPromote = Invoke-Canary -RootPath $BadRoot -Arguments @("-Promote", "-Id", "CB")
$caseOk = (Write-Check "worse canary stops the promote" ($badPromote.code -ne 0) ("exit=" + $badPromote.code)) -and $caseOk
$caseOk = (Write-Check "stopped promote reports the reason" ($badPromote.text -match 'success-rate')) -and $caseOk
$stoppedDoc = Get-CanaryDocument -RootPath $BadRoot -Id "CB"
$caseOk = (Write-Check "rollout status is stopped" ([string]$stoppedDoc.status -eq "stopped") ("status=" + [string]$stoppedDoc.status)) -and $caseOk

$badPromoteJson = Invoke-Canary -RootPath $BadRoot -Arguments @("-Promote", "-Id", "CB", "-Json")
$badPromoteDoc = ConvertTo-JsonSafe $badPromoteJson.text
$caseOk = (Write-Check "stopped promote json is parseable" ($null -ne $badPromoteDoc)) -and $caseOk
if ($null -ne $badPromoteDoc) {
    $caseOk = (Write-Check "stopped promote json reports ok=false" ([bool]$badPromoteDoc.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "stopped promote json is ASCII-only" ((Get-NonAsciiCount $badPromoteJson.text) -eq 0)) -and $caseOk
}

$rollback = Invoke-Canary -RootPath $BadRoot -Arguments @("-Rollback", "-Id", "CB", "-Json")
$caseOk = (Write-Check "rollback exit code is 0" ($rollback.code -eq 0) ("exit=" + $rollback.code)) -and $caseOk
$rollbackDoc = ConvertTo-JsonSafe $rollback.text
if ($null -ne $rollbackDoc) {
    $caseOk = (Write-Check "rollback status is rolled-back" ([string]$rollbackDoc.status -eq "rolled-back") ("status=" + [string]$rollbackDoc.status)) -and $caseOk
    $caseOk = (Write-Check "rollback json is ASCII-only" ((Get-NonAsciiCount $rollback.text) -eq 0)) -and $caseOk
}

$promoteAfterRollback = Invoke-Canary -RootPath $BadRoot -Arguments @("-Promote", "-Id", "CB")
$caseOk = (Write-Check "promote after rollback exits non-zero" ($promoteAfterRollback.code -ne 0) ("exit=" + $promoteAfterRollback.code)) -and $caseOk
$runAfterRollback = Invoke-Canary -RootPath $BadRoot -Arguments @("-Run", "-Id", "CB", "-Execute")
$caseOk = (Write-Check "run after rollback exits non-zero" ($runAfterRollback.code -ne 0) ("exit=" + $runAfterRollback.code)) -and $caseOk
Close-Case "h) stop + rollback" $caseOk

# --- i) empty root ---------------------------------------------------------

$caseOk = $true
$missingStatus = Invoke-Canary -RootPath $EmptyRoot -Arguments @("-Status", "-Id", "NOPE")
$caseOk = (Write-Check "missing rollout exits non-zero" ($missingStatus.code -ne 0) ("exit=" + $missingStatus.code)) -and $caseOk
$caseOk = (Write-Check "missing rollout says not found" ($missingStatus.text -match 'not found')) -and $caseOk

$missingJson = Invoke-Canary -RootPath $EmptyRoot -Arguments @("-Status", "-Id", "NOPE", "-Json")
$missingDoc = ConvertTo-JsonSafe $missingJson.text
$caseOk = (Write-Check "missing rollout json is parseable" ($null -ne $missingDoc)) -and $caseOk
if ($null -ne $missingDoc) {
    $caseOk = (Write-Check "missing rollout json reports ok=false" ([bool]$missingDoc.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "missing rollout json carries an error" (-not [string]::IsNullOrWhiteSpace([string]$missingDoc.error))) -and $caseOk
}

$missingRun = Invoke-Canary -RootPath $EmptyRoot -Arguments @("-Run", "-Id", "NOPE", "-Execute")
$caseOk = (Write-Check "run on a missing rollout exits non-zero" ($missingRun.code -ne 0) ("exit=" + $missingRun.code)) -and $caseOk

$missingId = Invoke-Canary -RootPath $EmptyRoot -Arguments @("-Status")
$caseOk = (Write-Check "missing -Id exits non-zero" ($missingId.code -ne 0) ("exit=" + $missingId.code)) -and $caseOk

$noMode2 = Invoke-Canary -RootPath $EmptyRoot -Arguments @("-Id", "NOPE")
$caseOk = (Write-Check "no mode exits 2" ($noMode2.code -eq 2) ("exit=" + $noMode2.code)) -and $caseOk
Close-Case "i) empty root" $caseOk

# --- j) broken data --------------------------------------------------------

$caseOk = $true
$brokenPath = Join-Path $BrokenRoot ".memory\canary\BROKEN.json"
Write-TextFile -Path $brokenPath -Text "{ this is not json at all"

$brokenStatus = Invoke-Canary -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "BROKEN")
$caseOk = (Write-Check "broken rollout exits non-zero" ($brokenStatus.code -ne 0) ("exit=" + $brokenStatus.code)) -and $caseOk
$caseOk = (Write-Check "broken rollout does not crash" (($brokenStatus.text -notmatch 'Exception') -and ($brokenStatus.text -notmatch 'internal error'))) -and $caseOk
$caseOk = (Write-Check "broken rollout explains itself" ($brokenStatus.text -match 'unreadable')) -and $caseOk

$brokenJson = Invoke-Canary -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "BROKEN", "-Json")
$brokenDoc = ConvertTo-JsonSafe $brokenJson.text
$caseOk = (Write-Check "broken json output is parseable" ($null -ne $brokenDoc)) -and $caseOk
if ($null -ne $brokenDoc) {
    $caseOk = (Write-Check "broken json output reports ok=false" ([bool]$brokenDoc.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "broken json output carries an error" (-not [string]::IsNullOrWhiteSpace([string]$brokenDoc.error))) -and $caseOk
}

$brokenPromote = Invoke-Canary -RootPath $BrokenRoot -Arguments @("-Promote", "-Id", "BROKEN")
$caseOk = (Write-Check "promote on broken data exits non-zero" ($brokenPromote.code -ne 0) ("exit=" + $brokenPromote.code)) -and $caseOk
$brokenRollback = Invoke-Canary -RootPath $BrokenRoot -Arguments @("-Rollback", "-Id", "BROKEN")
$caseOk = (Write-Check "rollback on broken data exits non-zero" ($brokenRollback.code -ne 0) ("exit=" + $brokenRollback.code)) -and $caseOk

$emptyFile = Join-Path $BrokenRoot ".memory\canary\EMPTYFILE.json"
Write-TextFile -Path $emptyFile -Text "   "
$emptyStatus = Invoke-Canary -RootPath $BrokenRoot -Arguments @("-Status", "-Id", "EMPTYFILE")
$caseOk = (Write-Check "empty state file exits non-zero" ($emptyStatus.code -ne 0) ("exit=" + $emptyStatus.code)) -and $caseOk
$caseOk = (Write-Check "empty state file does not crash" ($emptyStatus.text -notmatch 'internal error')) -and $caseOk
Close-Case "j) broken data" $caseOk

# --- k) custom stages ------------------------------------------------------

$caseOk = $true
$stagesDefine = Invoke-Canary -RootPath $StageRoot -Arguments @("-Define", "-Id", "CST", "-Agent", $AgentName,
    "-Change", "model", "-Value", "some-model-id", "-Baseline", "current-model-id", "-Stages", "10,25,100")
$caseOk = (Write-Check "custom stages define exit code is 0" ($stagesDefine.code -eq 0) ("exit=" + $stagesDefine.code)) -and $caseOk
$stagesDoc = Get-CanaryDocument -RootPath $StageRoot -Id "CST"
if ($null -ne $stagesDoc) {
    $stagesList = @($stagesDoc.stages)
    $caseOk = (Write-Check "custom stages are stored in order" (($stagesList.Count -eq 3) -and ([int]$stagesList[0] -eq 10) -and ([int]$stagesList[1] -eq 25) -and ([int]$stagesList[2] -eq 100)) ("stages=" + ($stagesList -join ","))) -and $caseOk
    $caseOk = (Write-Check "model change kind is accepted" ([string]$stagesDoc.change -eq "model")) -and $caseOk
}
$stagesStatus = Invoke-Canary -RootPath $StageRoot -Arguments @("-Status", "-Id", "CST", "-Json")
$stagesStatusDoc = ConvertTo-JsonSafe $stagesStatus.text
if ($null -ne $stagesStatusDoc) {
    $caseOk = (Write-Check "status reports the first custom stage" ([int]$stagesStatusDoc.stage_percent -eq 10) ("percent=" + [int]$stagesStatusDoc.stage_percent)) -and $caseOk
    $caseOk = (Write-Check "status reports 3 stages" ([int]$stagesStatusDoc.stages_total -eq 3)) -and $caseOk
}
$stagesDry = Invoke-Canary -RootPath $StageRoot -Arguments @("-Run", "-Id", "CST")
$caseOk = (Write-Check "custom stage dry-run uses 1 repeat per arm" ($stagesDry.text -match 'repeats/arm 1') ("out=" + $stagesDry.text)) -and $caseOk
Close-Case "k) custom stages" $caseOk

# --- cleanup ---------------------------------------------------------------

Clear-CaseEnv
try { [System.IO.Directory]::Delete($TempBase, $true) } catch { }

Write-Host ""
Write-Host ("=== cases: " + $script:CasePass + " passed, " + $script:CaseFail + " failed ===")
if ($script:CaseFail -gt 0) { exit 1 }
exit 0
