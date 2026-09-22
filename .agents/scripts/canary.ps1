# canary.ps1 - staged canary rollout over the shared inbox engine (P3).
#
#   .\canary.ps1 -Define -Id C1 -Agent dev-1 -Change prompt -Value "new prompt" [-Baseline "old prompt"] [-Stages 1,2,3]
#   .\canary.ps1 -Run -Id C1 [-Execute] [-Samples 10] [-Json]
#   .\canary.ps1 -Status -Id C1 [-Json]
#   .\canary.ps1 -Promote -Id C1 [-Epsilon 0.05] [-Json]
#   .\canary.ps1 -Rollback -Id C1 [-Json]
#
# State: <root>\.memory\canary\<id>.json - definition, history, every run.
# A stage is a traffic share in percent. The current stage is executed through the
# SAME engine the poller/daemon/replay use (inbox-engine.ps1 -> Process-InboxFile),
# once per arm (baseline / canary). Per-arm metrics: success-rate, average
# confidence, average duration, failure-memory hits.
# Promotion rule: canary success-rate >= baseline - Epsilon AND canary average
# confidence >= baseline. A regression stops the rollout (Rollback recommended).
# -Run is DRY-RUN unless -Execute is given. The only writes outside the engine are
# .memory\canary\<id>.json.
# Exit codes: 0 ok, 1 cannot fulfil the request, 2 internal error.
# Pure PowerShell 5.1. CRLF. No secrets are read, printed or written.

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Define,
    [switch]$Run,
    [switch]$Status,
    [switch]$Promote,
    [switch]$Rollback,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Execute,
    [string]$Id = '',
    [string]$Agent = '',
    [string]$Change = '',
    [string]$Value = '',
    [string]$Baseline = '',
    [Alias('Stages')][string]$StageList = '1,2,3',
    [int]$Samples = 10,
    [double]$Epsilon = 0.0,
    [string]$Root = ''
)

$script:CanaryScriptRoot = $PSScriptRoot
$script:CanaryUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CanaryIdGuard = '^[A-Za-z0-9._-]{1,40}$'
$script:CanaryAgentGuard = '^[A-Za-z0-9._-]{1,40}$'
$script:CanaryKinds = @('model', 'prompt', 'config')
$script:CanaryMaxJsonBytes = 8 * 1024 * 1024

function Get-CanaryRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:CanaryScriptRoot)) {
        return (Split-Path (Split-Path $script:CanaryScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-CanaryDir {
    param([string]$RootPath)
    return (Join-Path (Join-Path $RootPath '.memory') 'canary')
}

function Get-CanaryPath {
    param([string]$CanaryDir, [string]$Id)
    return (Join-Path $CanaryDir ($Id + '.json'))
}

function Get-CanaryBufferPath {
    param([string]$RootPath)
    return (Join-Path $RootPath 'CONTEXT-BUFFER.md')
}

function Get-CanaryStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-CanaryInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-CanaryDouble {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

function ConvertTo-CanaryJsonAscii {
    param($InputObject, [int]$Depth = 10)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

function Read-CanaryJson {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt $script:CanaryMaxJsonBytes) { return $null }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-CanaryJsonFile {
    param([string]$Path, $Object)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, $script:CanaryUtf8NoBom)
}

# "1,2,3" | "10 25 100" -> strictly ascending percents in 1..100; problems are collected.
function ConvertTo-CanaryStages {
    param([string]$Spec)
    $out = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Spec)) {
        [void]$errors.Add('stage list is empty')
        return [pscustomobject]@{ stages = @(); errors = @($errors.ToArray()) }
    }
    $previous = 0
    foreach ($part in @([string]$Spec -split '[,\s;]+')) {
        $text = ([string]$part).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $parsed = 0
        if (-not [int]::TryParse($text, [ref]$parsed)) {
            [void]$errors.Add("stage '" + $text + "' is not a whole number")
            continue
        }
        if ($parsed -lt 1 -or $parsed -gt 100) {
            [void]$errors.Add('stage ' + $parsed + ' is outside 1..100')
            continue
        }
        if ($parsed -le $previous) {
            [void]$errors.Add('stage ' + $parsed + ' is not above the previous stage ' + $previous)
            continue
        }
        [void]$out.Add($parsed)
        $previous = $parsed
    }
    if ($out.Count -eq 0) { [void]$errors.Add('no usable stage in the list') }
    return [pscustomobject]@{ stages = @($out.ToArray()); errors = @($errors.ToArray()) }
}

function Get-CanaryStagesFromDocument {
    param($Document)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Document) { return @() }
    $previous = 0
    foreach ($item in @($Document.stages)) {
        $parsed = 0
        if (-not [int]::TryParse([string]$item, [ref]$parsed)) { continue }
        if ($parsed -lt 1 -or $parsed -gt 100) { continue }
        if ($parsed -le $previous) { continue }
        [void]$out.Add($parsed)
        $previous = $parsed
    }
    return @($out.ToArray())
}

function Get-CanaryRunRecords {
    param($Document)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Document) { return @() }
    foreach ($run in @($Document.runs)) {
        if ($null -eq $run) { continue }
        [void]$out.Add([ordered]@{
            run_id             = [string]$run.run_id
            arm                = [string]$run.arm
            stage              = ConvertTo-CanaryInt -Value $run.stage
            seq                = ConvertTo-CanaryInt -Value $run.seq
            started_at         = [string]$run.started_at
            finished_at        = [string]$run.finished_at
            duration_ms        = ConvertTo-CanaryInt -Value $run.duration_ms
            success            = [bool]$run.success
            engine_status      = [string]$run.engine_status
            engine_reason      = [string]$run.engine_reason
            attempts           = ConvertTo-CanaryInt -Value $run.attempts
            failed_attempts    = ConvertTo-CanaryInt -Value $run.failed_attempts
            exit_code          = [string]$run.exit_code
            confidence         = ConvertTo-CanaryDouble -Value $run.confidence
            confidence_level   = [string]$run.confidence_level
            failure_memory_hit = [bool]$run.failure_memory_hit
            error              = [string]$run.error
        })
    }
    return @($out)
}

function Get-CanaryHistoryRecords {
    param($Document)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Document) { return @() }
    foreach ($entry in @($Document.history)) {
        if ($null -eq $entry) { continue }
        [void]$out.Add([ordered]@{
            action  = [string]$entry.action
            at      = [string]$entry.at
            stage   = ConvertTo-CanaryInt -Value $entry.stage
            percent = ConvertTo-CanaryInt -Value $entry.percent
            status  = [string]$entry.status
            reason  = [string]$entry.reason
        })
    }
    return @($out)
}

function Get-CanaryMetrics {
    param($RunRecords, [string]$Arm)
    $mine = @(@($RunRecords) | Where-Object { $null -ne $_ -and [string]$_.arm -eq $Arm })
    $count = $mine.Count
    $successes = 0
    $failureHits = 0
    $confidenceSum = 0.0
    $durationSum = 0.0
    foreach ($record in $mine) {
        if ([bool]$record.success) { $successes++ }
        if ([bool]$record.failure_memory_hit) { $failureHits++ }
        $confidenceSum += [double]$record.confidence
        $durationSum += [double]$record.duration_ms
    }
    $rate = 0.0
    $avgConfidence = 0.0
    $avgDuration = 0
    if ($count -gt 0) {
        $rate = [math]::Round($successes / $count, 2)
        $avgConfidence = [math]::Round($confidenceSum / $count, 2)
        $avgDuration = [int][math]::Round($durationSum / $count)
    }
    return [ordered]@{
        arm             = $Arm
        runs            = $count
        successes       = $successes
        success_rate    = $rate
        avg_confidence  = $avgConfidence
        avg_duration_ms = $avgDuration
        failure_hits    = $failureHits
    }
}

function Get-CanaryStageRunCount {
    param($RunRecords, [string]$Arm, [int]$Percent)
    $count = 0
    foreach ($record in @($RunRecords)) {
        if ($null -eq $record) { continue }
        if ([string]$record.arm -eq $Arm -and (ConvertTo-CanaryInt -Value $record.stage) -eq $Percent) { $count++ }
    }
    return $count
}

# Promotion gate: canary must not be worse than baseline (success-rate with epsilon, confidence)
# and the current stage must have at least one recorded canary run.
function Test-CanaryPromotion {
    param($RunRecords, [double]$Epsilon, [int]$CurrentStage = 0)
    $baselineMetrics = Get-CanaryMetrics -RunRecords $RunRecords -Arm 'baseline'
    $canaryMetrics = Get-CanaryMetrics -RunRecords $RunRecords -Arm 'canary'
    $threshold = [math]::Round([double]$baselineMetrics.success_rate - $Epsilon, 2)
    $result = [ordered]@{
        ok        = $false
        reason    = ''
        action    = 'run'
        epsilon   = [double]$Epsilon
        threshold = $threshold
        baseline  = $baselineMetrics
        canary    = $canaryMetrics
    }
    if ([int]$baselineMetrics.runs -eq 0) {
        $result.reason = 'baseline has no runs yet'
        return $result
    }
    if ([int]$canaryMetrics.runs -eq 0) {
        $result.reason = 'canary has no runs yet'
        return $result
    }
    if ((Get-CanaryStageRunCount -RunRecords $RunRecords -Arm 'canary' -Percent $CurrentStage) -eq 0) {
        $result.reason = 'stage ' + $CurrentStage + ' has no canary runs yet'
        return $result
    }
    if ([double]$canaryMetrics.success_rate -lt $threshold) {
        $result.reason = 'canary success-rate ' + $canaryMetrics.success_rate + ' is below baseline ' + $baselineMetrics.success_rate + ' - epsilon ' + $Epsilon
        $result.action = 'stop'
        return $result
    }
    if ([double]$canaryMetrics.avg_confidence -lt [double]$baselineMetrics.avg_confidence) {
        $result.reason = 'canary average confidence ' + $canaryMetrics.avg_confidence + ' is below baseline ' + $baselineMetrics.avg_confidence
        $result.action = 'stop'
        return $result
    }
    $result.ok = $true
    $result.reason = 'canary success-rate and average confidence are not worse than the baseline'
    return $result
}

function Get-CanaryRepeats {
    param([int]$SamplesValue, [int]$Percent)
    $effective = $SamplesValue
    if ($effective -lt 1) { $effective = 1 }
    $raw = [math]::Round(($effective * $Percent) / 100.0, 0, [System.MidpointRounding]::AwayFromZero)
    $count = [int]$raw
    if ($count -lt 1) { $count = 1 }
    return $count
}

function Get-CanaryPayload {
    param([string]$ExperimentId, [string]$Arm, [int]$Percent, [string]$ChangeKind, [string]$ValueText, [string]$BaselineText)
    $text = $ValueText
    if ($Arm -eq 'baseline') { $text = $BaselineText }
    return ('canary ' + $ExperimentId + ' CANARY_ARM=' + $Arm + ' CANARY_CHANGE=' + $ChangeKind +
        ' CANARY_STAGE=' + $Percent + ' ' + $text)
}

function New-CanaryReport {
    param($Document, $RunRecords, [string]$RootPath, [string]$FilePath, [string]$Mode = 'status', [int]$Executed = 0, [int]$Planned = 0, $Notes = @())
    $stages = @(Get-CanaryStagesFromDocument -Document $Document)
    $stageIndex = ConvertTo-CanaryInt -Value $Document.stage_index
    if ($stageIndex -lt 0) { $stageIndex = 0 }
    if ($stages.Count -eq 0) { $stageIndex = 0 }
    elseif ($stageIndex -ge $stages.Count) { $stageIndex = $stages.Count - 1 }
    $stagePercent = 0
    if ($stages.Count -gt 0) { $stagePercent = [int]$stages[$stageIndex] }
    $epsilon = ConvertTo-CanaryDouble -Value $Document.epsilon
    $verdict = Test-CanaryPromotion -RunRecords $RunRecords -Epsilon $epsilon -CurrentStage $stagePercent
    return [ordered]@{
        tool         = 'canary'
        generated_at = Get-CanaryStamp
        ok           = $true
        mode         = $Mode
        executed     = $Executed
        planned      = $Planned
        id           = [string]$Document.id
        agent        = [string]$Document.agent
        change       = [string]$Document.change
        value        = [string]$Document.value
        baseline     = [string]$Document.baseline
        stages       = $stages
        stage_index  = $stageIndex
        stage_percent = $stagePercent
        stages_total = $stages.Count
        samples      = ConvertTo-CanaryInt -Value $Document.samples
        epsilon      = $epsilon
        status       = [string]$Document.status
        created      = [string]$Document.created
        updated      = [string]$Document.updated
        file         = $FilePath
        root         = $RootPath
        runs_total   = @($RunRecords).Count
        metrics      = @($verdict.baseline, $verdict.canary)
        promotion    = $verdict
        history      = @(Get-CanaryHistoryRecords -Document $Document)
        notes        = @($Notes)
        runs         = @($RunRecords)
    }
}

function Get-CanaryNextAction {
    param($Report)
    $status = [string]$Report.status
    if ($status -eq 'rolled-back') { return 'rollout was rolled back' }
    if ($status -eq 'promoted') { return 'rollout is complete (last stage reached)' }
    if ([string]$Report.promotion.action -eq 'stop') { return 'rollback recommended: -Rollback -Id ' + [string]$Report.id }
    if ([string]$Report.promotion.action -eq 'run') { return 'run stage ' + [int]$Report.stage_percent + '%: -Run -Id ' + [string]$Report.id + ' -Execute' }
    if ([int]$Report.stage_index + 1 -ge [int]$Report.stages_total) { return 'promote to finish the rollout: -Promote -Id ' + [string]$Report.id }
    return 'promote to the next stage: -Promote -Id ' + [string]$Report.id
}

function Format-CanaryStatusHuman {
    param($Report)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== agent-hq canary rollout: ' + [string]$Report.id + ' ===')
    [void]$lines.Add('agent    : ' + [string]$Report.agent)
    [void]$lines.Add('change   : ' + [string]$Report.change)
    [void]$lines.Add('value    : ' + [string]$Report.value)
    [void]$lines.Add('baseline : ' + [string]$Report.baseline)
    [void]$lines.Add('file     : ' + [string]$Report.file)
    [void]$lines.Add('status   : ' + [string]$Report.status + '   stage ' + ([int]$Report.stage_index + 1) + '/' + [int]$Report.stages_total +
        ' (' + [int]$Report.stage_percent + '%)   samples ' + [int]$Report.samples)
    [void]$lines.Add('')
    [void]$lines.Add(('  {0,-10} {1,5} {2,8} {3,6} {4,7} {5,9} {6,9}' -f 'arm', 'runs', 'success', 'rate', 'conf', 'avg_ms', 'fail-mem'))
    foreach ($metric in @($Report.metrics)) {
        [void]$lines.Add(('  {0,-10} {1,5} {2,8} {3,6} {4,7} {5,9} {6,9}' -f
            [string]$metric.arm, [int]$metric.runs, [int]$metric.successes, [double]$metric.success_rate,
            [double]$metric.avg_confidence, [int]$metric.avg_duration_ms, [int]$metric.failure_hits))
    }
    [void]$lines.Add('')
    if ([bool]$Report.promotion.ok) {
        [void]$lines.Add('promotion: OK - ' + [string]$Report.promotion.reason)
    } else {
        [void]$lines.Add('promotion: NOT OK - ' + [string]$Report.promotion.reason)
    }
    [void]$lines.Add('next     : ' + (Get-CanaryNextAction -Report $Report))
    return ($lines -join "`r`n")
}

function Write-CanaryOutput {
    param([string]$HumanText, $JsonObject, [bool]$AsJson)
    if ($AsJson) { Write-Output (ConvertTo-CanaryJsonAscii -InputObject $JsonObject -Depth 10) }
    else { Write-Output $HumanText }
}

function Write-CanaryProblem {
    param([string]$Message, [bool]$AsJson, [string]$IdValue = '')
    if ($AsJson) {
        Write-Output (ConvertTo-CanaryJsonAscii -InputObject ([ordered]@{ tool = 'canary'; ok = $false; id = $IdValue; error = $Message }) -Depth 6)
    } else {
        Write-Output ('canary: ' + $Message)
    }
}

function Save-CanaryState {
    param([string]$Path, $Document, $RunRecords, $History, [string]$StatusValue, [int]$StageIndex)
    $state = [ordered]@{
        id          = [string]$Document.id
        agent       = [string]$Document.agent
        change      = [string]$Document.change
        value       = [string]$Document.value
        baseline    = [string]$Document.baseline
        stages      = @(Get-CanaryStagesFromDocument -Document $Document)
        stage_index = $StageIndex
        samples     = ConvertTo-CanaryInt -Value $Document.samples
        epsilon     = ConvertTo-CanaryDouble -Value $Document.epsilon
        status      = $StatusValue
        created     = [string]$Document.created
        updated     = Get-CanaryStamp
        runs        = @($RunRecords)
        history     = @($History)
    }
    Write-CanaryJsonFile -Path $Path -Object $state
    return $state
}

# One canary run: enqueue a message and process it with the shared engine, then snapshot metrics.
function Invoke-CanaryOneRun {
    param(
        [string]$RootPath,
        [string]$ExperimentId,
        [string]$AgentName,
        [string]$Arm,
        [int]$Percent,
        [int]$Seq,
        [string]$RunId,
        [string]$Payload
    )

    $inboxDir = Join-Path (Join-Path (Join-Path $RootPath '.memory') 'inbox') $AgentName
    if (-not (Test-Path -LiteralPath $inboxDir -PathType Container)) {
        New-Item -ItemType Directory -Path $inboxDir -Force | Out-Null
    }
    $inboxFile = Join-Path $inboxDir ($RunId + '.json')
    $message = [ordered]@{
        id           = $RunId
        from         = 'canary'
        to           = $AgentName
        type         = 'task'
        priority     = 'normal'
        payload      = $Payload
        created      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        canary_id    = $ExperimentId
        canary_arm   = $Arm
        canary_stage = $Percent
    }
    [System.IO.File]::WriteAllText($inboxFile, ($message | ConvertTo-Json -Depth 6), $script:CanaryUtf8NoBom)

    $startedAt = Get-Date
    $engineStatus = 'unknown'
    $engineReason = ''
    $runError = ''
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $engineResult = & { Process-InboxFile -filePath $inboxFile -agentName $AgentName } 6>$null
        if ($null -ne $engineResult) {
            $engineStatus = [string]$engineResult.Status
            $engineReason = [string]$engineResult.Reason
        }
    } catch {
        $engineStatus = 'error'
        $runError = $_.Exception.Message
    }
    $watch.Stop()
    $finishedAt = Get-Date

    $evidenceFile = Join-Path (Join-Path (Join-Path $RootPath '.memory') 'evidence') ($RunId + '.json')
    $attempts = @()
    $evidenceDoc = Read-CanaryJson -Path $evidenceFile
    if ($null -ne $evidenceDoc) { $attempts = @($evidenceDoc.attempts | Where-Object { $null -ne $_ }) }

    $failedAttempts = 0
    $lastExit = ''
    foreach ($attempt in $attempts) {
        $exit = 0
        if ($null -ne $attempt.exit_code -and -not [string]::IsNullOrWhiteSpace([string]$attempt.exit_code)) {
            if ([int]::TryParse([string]$attempt.exit_code, [ref]$exit)) {
                $lastExit = [string]$exit
                if ($exit -ne 0) { $failedAttempts++ }
            }
        }
    }

    $success = ($engineStatus -eq 'done')
    $confidence = 0.0
    $confidenceLevel = ''
    $failureHit = $false
    try {
        $verdict = Get-TaskConfidence -TaskId $RunId -Root $RootPath -BufferPath (Get-CanaryBufferPath -RootPath $RootPath)
        if ($null -ne $verdict) {
            $confidence = [double]$verdict.confidence
            $confidenceLevel = [string]$verdict.level
            $failureHit = [bool]$verdict.failure_memory_hit
        }
    } catch {
        if ([string]::IsNullOrWhiteSpace($runError)) { $runError = 'confidence: ' + $_.Exception.Message }
    }

    return [ordered]@{
        run_id             = $RunId
        arm                = $Arm
        stage              = $Percent
        seq                = $Seq
        started_at         = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        finished_at        = $finishedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        duration_ms        = [int]$watch.ElapsedMilliseconds
        success            = [bool]$success
        engine_status      = $engineStatus
        engine_reason      = $engineReason
        attempts           = $attempts.Count
        failed_attempts    = $failedAttempts
        exit_code          = $lastExit
        confidence         = [double]$confidence
        confidence_level   = $confidenceLevel
        failure_memory_hit = $failureHit
        error              = $runError
    }
}

# ===========================================================================
# Main
# ===========================================================================

$exitCode = 0
try {
    $rootPath = Get-CanaryRoot -RootValue $Root
    $canaryDir = Get-CanaryDir -RootPath $rootPath
    $notes = New-Object System.Collections.ArrayList

    $samplesValue = $Samples
    if ($samplesValue -lt 1) {
        [void]$notes.Add('Samples < 1 was clamped to 1')
        $samplesValue = 1
    }
    $epsilonValue = $Epsilon
    if ($epsilonValue -lt 0) {
        [void]$notes.Add('Epsilon < 0 was clamped to 0')
        $epsilonValue = 0
    }
    if ($epsilonValue -gt 1) {
        [void]$notes.Add('Epsilon > 1 was clamped to 1')
        $epsilonValue = 1
    }

    $experimentId = ([string]$Id).Trim()

    if ($Define) {
        $problems = New-Object System.Collections.ArrayList
        if ([string]::IsNullOrWhiteSpace($experimentId)) {
            [void]$problems.Add('-Id is required')
        } elseif ($experimentId -notmatch $script:CanaryIdGuard) {
            [void]$problems.Add("experiment id '" + $experimentId + "' rejected: letters, digits, dot, underscore or hyphen, max 40")
        }
        $agentName = ([string]$Agent).Trim()
        if ([string]::IsNullOrWhiteSpace($agentName)) {
            [void]$problems.Add('-Agent is required')
        } elseif ($agentName -notmatch $script:CanaryAgentGuard) {
            [void]$problems.Add("agent '" + $agentName + "' rejected by the file-name guard")
        }
        $changeKind = ([string]$Change).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($changeKind)) {
            [void]$problems.Add('-Change is required')
        } elseif ($script:CanaryKinds -notcontains $changeKind) {
            [void]$problems.Add("change kind '" + $changeKind + "' rejected: model, prompt or config")
        }
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            [void]$problems.Add('-Value is required')
        }
        $stageParse = ConvertTo-CanaryStages -Spec $StageList
        foreach ($stageError in @($stageParse.errors)) { [void]$problems.Add('stages: ' + $stageError) }
        if ($Epsilon -lt 0 -or $Epsilon -gt 1) {
            [void]$problems.Add('Epsilon must be between 0 and 1')
        }

        if ($problems.Count -gt 0) {
            $message = 'cannot define rollout: ' + (@($problems) -join '; ')
            Write-CanaryProblem -Message $message -AsJson ([bool]$Json) -IdValue $experimentId
            exit 1
        }

        if (-not (Test-Path -LiteralPath $canaryDir -PathType Container)) {
            New-Item -ItemType Directory -Path $canaryDir -Force | Out-Null
        }
        $canaryPath = Get-CanaryPath -CanaryDir $canaryDir -Id $experimentId
        $existing = Read-CanaryJson -Path $canaryPath
        $keptRuns = @()
        $history = New-Object System.Collections.ArrayList
        $stageIndex = 0
        $created = Get-CanaryStamp
        if ($null -ne $existing) {
            $keptRuns = @(Get-CanaryRunRecords -Document $existing)
            foreach ($historyEntry in @(Get-CanaryHistoryRecords -Document $existing)) { [void]$history.Add($historyEntry) }
            $stageIndex = ConvertTo-CanaryInt -Value $existing.stage_index
            if ($stageIndex -lt 0) { $stageIndex = 0 }
            if ($stageIndex -ge $stageParse.stages.Count) { $stageIndex = 0 }
            if (-not [string]::IsNullOrWhiteSpace([string]$existing.created)) { $created = [string]$existing.created }
            if ($keptRuns.Count -gt 0) { [void]$notes.Add('kept ' + $keptRuns.Count + ' existing run(s)') }
        } elseif (Test-Path -LiteralPath $canaryPath -PathType Leaf) {
            [void]$notes.Add('existing file was unreadable and got replaced')
        }

        $baselineText = [string]$Baseline
        if ([string]::IsNullOrWhiteSpace($baselineText)) { $baselineText = 'baseline ' + $changeKind + ' state' }

        [void]$history.Add([ordered]@{
            action  = 'define'
            at      = Get-CanaryStamp
            stage   = $stageIndex
            percent = [int]$stageParse.stages[$stageIndex]
            status  = 'defined'
            reason  = 'change ' + $changeKind + ' defined over ' + $stageParse.stages.Count + ' stage(s)'
        })

        $document = [ordered]@{
            id          = $experimentId
            agent       = $agentName
            change      = $changeKind
            value       = [string]$Value
            baseline    = $baselineText
            stages      = @($stageParse.stages)
            stage_index = $stageIndex
            samples     = $samplesValue
            epsilon     = $epsilonValue
            status      = 'defined'
            created     = $created
            updated     = Get-CanaryStamp
            runs        = @($keptRuns)
            history     = @($history)
        }
        Write-CanaryJsonFile -Path $canaryPath -Object $document

        $report = New-CanaryReport -Document $document -RunRecords $keptRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'define' -Notes $notes
        $human = (Format-CanaryStatusHuman -Report $report) + "`r`n" + 'defined: change ' + $changeKind + ' over ' + $stageParse.stages.Count + ' stage(s); pass -Run -Execute to start'
        Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText $human
        exit 0
    }

    if (-not ($Run -or $Status -or $Promote -or $Rollback)) {
        Write-Output 'canary: nothing to do - pass -Define, -Run, -Status, -Promote or -Rollback'
        exit 2
    }

    if ([string]::IsNullOrWhiteSpace($experimentId)) {
        Write-CanaryProblem -Message '-Id is required' -AsJson ([bool]$Json)
        exit 1
    }
    if ($experimentId -notmatch $script:CanaryIdGuard) {
        Write-CanaryProblem -Message ('experiment id rejected by the file-name guard: ' + $experimentId) -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }

    $canaryPath = Get-CanaryPath -CanaryDir $canaryDir -Id $experimentId
    $document = Read-CanaryJson -Path $canaryPath
    if ($null -eq $document) {
        $reason = if (Test-Path -LiteralPath $canaryPath -PathType Leaf) { 'experiment file is unreadable or not valid JSON' } else { 'experiment not found' }
        Write-CanaryProblem -Message ($reason + ': ' + $canaryPath) -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }

    $stages = @(Get-CanaryStagesFromDocument -Document $document)
    if ($stages.Count -eq 0) {
        Write-CanaryProblem -Message ('definition holds no usable stages') -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }
    $agentName = [string]$document.agent
    if ([string]::IsNullOrWhiteSpace($agentName) -or $agentName -notmatch $script:CanaryAgentGuard) {
        Write-CanaryProblem -Message 'definition has no usable agent name' -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }
    $changeKind = [string]$document.change
    if ($script:CanaryKinds -notcontains $changeKind) {
        Write-CanaryProblem -Message 'definition has no usable change kind' -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }

    $knownRuns = @(Get-CanaryRunRecords -Document $document)
    $history = @(Get-CanaryHistoryRecords -Document $document)
    $stageIndex = ConvertTo-CanaryInt -Value $document.stage_index
    if ($stageIndex -lt 0) { $stageIndex = 0 }
    if ($stageIndex -ge $stages.Count) { $stageIndex = $stages.Count - 1 }
    $stagePercent = [int]$stages[$stageIndex]
    $epsilonValue = ConvertTo-CanaryDouble -Value $document.epsilon
    $samplesValue = ConvertTo-CanaryInt -Value $document.samples
    $statusValue = [string]$document.status

    # ---- rollback ----------------------------------------------------------
    if ($Rollback) {
        if ($statusValue -eq 'rolled-back') {
            [void]$notes.Add('rollout was already rolled back')
        } else {
            $history = @($history) + @([ordered]@{
                action  = 'rollback'
                at      = Get-CanaryStamp
                stage   = $stageIndex
                percent = $stagePercent
                status  = 'rolled-back'
                reason  = 'operator rolled the canary change back'
            })
            $statusValue = 'rolled-back'
            $state = Save-CanaryState -Path $canaryPath -Document $document -RunRecords $knownRuns -History $history -StatusValue $statusValue -StageIndex $stageIndex
            $document = $state
        }
        $report = New-CanaryReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'rollback' -Notes $notes
        Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
        exit 0
    }

    # ---- promote -----------------------------------------------------------
    if ($Promote) {
        if ($statusValue -eq 'rolled-back') {
            Write-CanaryProblem -Message 'rollout was rolled back and cannot be promoted' -AsJson ([bool]$Json) -IdValue $experimentId
            exit 1
        }
        if ($statusValue -eq 'promoted') {
            [void]$notes.Add('rollout already reached the last stage')
            $report = New-CanaryReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'promote' -Notes $notes
            Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
            exit 0
        }
        $verdict = Test-CanaryPromotion -RunRecords $knownRuns -Epsilon $epsilonValue -CurrentStage $stagePercent
        if (-not $verdict.ok) {
            if ([string]$verdict.action -eq 'stop') {
                $history = @($history) + @([ordered]@{
                    action  = 'stop'
                    at      = Get-CanaryStamp
                    stage   = $stageIndex
                    percent = $stagePercent
                    status  = 'stopped'
                    reason  = [string]$verdict.reason
                })
                $statusValue = 'stopped'
                $document = Save-CanaryState -Path $canaryPath -Document $document -RunRecords $knownRuns -History $history -StatusValue $statusValue -StageIndex $stageIndex
            }
            $report = New-CanaryReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'promote' -Notes $notes
            $report.ok = $false
            $report.error = [string]$verdict.reason
            Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
            exit 1
        }
        if ($stageIndex + 1 -ge $stages.Count) {
            $history = @($history) + @([ordered]@{
                action  = 'complete'
                at      = Get-CanaryStamp
                stage   = $stageIndex
                percent = $stagePercent
                status  = 'promoted'
                reason  = 'last stage passed: rollout complete'
            })
            $statusValue = 'promoted'
        } else {
            $nextIndex = $stageIndex + 1
            $history = @($history) + @([ordered]@{
                action  = 'promote'
                at      = Get-CanaryStamp
                stage   = $nextIndex
                percent = [int]$stages[$nextIndex]
                status  = 'running'
                reason  = 'stage ' + $stagePercent + '% passed: promoted to ' + [int]$stages[$nextIndex] + '%'
            })
            $stageIndex = $nextIndex
            $stagePercent = [int]$stages[$stageIndex]
            $statusValue = 'running'
        }
        $document = Save-CanaryState -Path $canaryPath -Document $document -RunRecords $knownRuns -History $history -StatusValue $statusValue -StageIndex $stageIndex
        $report = New-CanaryReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'promote' -Notes $notes
        Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
        exit 0
    }

    # ---- status ------------------------------------------------------------
    if ($Status -and -not $Run) {
        $report = New-CanaryReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'status' -Notes $notes
        Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
        exit 0
    }

    # ---- run ---------------------------------------------------------------
    if ($statusValue -eq 'rolled-back') {
        Write-CanaryProblem -Message 'rollout was rolled back and cannot be run' -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }
    if ($statusValue -eq 'promoted') {
        Write-CanaryProblem -Message 'rollout is complete and cannot be run' -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }
    if ($samplesValue -lt 1) { $samplesValue = 1 }
    $repeats = Get-CanaryRepeats -SamplesValue $samplesValue -Percent $stagePercent
    $execute = ([bool]$Execute -and -not [bool]$DryRun)
    $baselineText = [string]$document.baseline
    $valueText = [string]$document.value

    $planned = New-Object System.Collections.ArrayList
    foreach ($arm in @('baseline', 'canary')) {
        $taken = Get-CanaryStageRunCount -RunRecords $knownRuns -Arm $arm -Percent $stagePercent
        for ($index = 1; $index -le $repeats; $index++) {
            $seq = $taken + $index
            $runId = $experimentId + '-' + $arm + '-s' + $stagePercent + '-n' + $seq
            [void]$planned.Add([ordered]@{
                arm     = $arm
                stage   = $stagePercent
                seq     = $seq
                run_id  = $runId
                payload = (Get-CanaryPayload -ExperimentId $experimentId -Arm $arm -Percent $stagePercent -ChangeKind $changeKind -ValueText $valueText -BaselineText $baselineText)
            })
        }
    }

    if (-not $execute) {
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('=== agent-hq canary run plan: ' + $experimentId + ' ===')
        [void]$lines.Add('agent    : ' + $agentName)
        [void]$lines.Add('change   : ' + $changeKind)
        [void]$lines.Add('root     : ' + $rootPath)
        [void]$lines.Add('file     : ' + $canaryPath)
        [void]$lines.Add('stage    : ' + ([int]$stageIndex + 1) + '/' + $stages.Count + ' (' + $stagePercent + '%)   samples ' + $samplesValue + '   repeats/arm ' + $repeats + '   planned runs ' + $planned.Count)
        foreach ($plan in $planned) {
            [void]$lines.Add(('  {0,-10} stage {1,3}% seq {2,-3} id={3}' -f [string]$plan.arm, [int]$plan.stage, [int]$plan.seq, [string]$plan.run_id))
        }
        [void]$lines.Add('')
        [void]$lines.Add('dry-run: nothing was written and no engine run was started (pass -Execute to run)')
        $report = [ordered]@{
            tool         = 'canary'
            generated_at = Get-CanaryStamp
            ok           = $true
            mode         = 'dry-run'
            id           = $experimentId
            agent        = $agentName
            change       = $changeKind
            root         = $rootPath
            file         = $canaryPath
            stage_index  = $stageIndex
            stage_percent = $stagePercent
            stages_total = $stages.Count
            samples      = $samplesValue
            repeats      = $repeats
            planned      = $planned
            runs_total   = $knownRuns.Count
            notes        = @($notes)
        }
        Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText ($lines -join "`r`n")
        exit 0
    }

    $enginePath = Join-Path $script:CanaryScriptRoot 'inbox-engine.ps1'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        Write-CanaryProblem -Message ('inbox-engine.ps1 missing - cannot run: ' + $enginePath) -AsJson ([bool]$Json) -IdValue $experimentId
        exit 1
    }

    $previousRoot = $env:AGENT_HQ_ROOT
    $env:AGENT_HQ_ROOT = $rootPath
    $allRuns = @($knownRuns)
    $executed = 0
    try {
        . $enginePath
        . (Join-Path $script:CanaryScriptRoot 'confidence.ps1')
        $evidenceDir = Join-Path (Join-Path $rootPath '.memory') 'evidence'
        $canaryInboxDir = Join-Path (Join-Path (Join-Path $rootPath '.memory') 'inbox') $agentName
        foreach ($plan in $planned) {
            $arm = [string]$plan.arm
            $seq = [int]$plan.seq
            $runId = [string]$plan.run_id
            $guard = 0
            while ($guard -lt 1000) {
                $taken = (Test-Path -LiteralPath (Join-Path $evidenceDir ($runId + '.json')) -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $canaryInboxDir ($runId + '.json')) -PathType Leaf)
                if (-not $taken) { break }
                $seq++
                $runId = $experimentId + '-' + $arm + '-s' + $stagePercent + '-n' + $seq
                $guard++
            }
            $record = Invoke-CanaryOneRun -RootPath $rootPath -ExperimentId $experimentId -AgentName $agentName `
                -Arm $arm -Percent $stagePercent -Seq $seq -RunId $runId -Payload ([string]$plan.payload)
            $allRuns = @($allRuns) + @($record)
            $executed++
            $document = Save-CanaryState -Path $canaryPath -Document $document -RunRecords $allRuns -History $history -StatusValue $statusValue -StageIndex $stageIndex
        }
    } finally {
        if ($null -eq $previousRoot) {
            Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
        } else {
            $env:AGENT_HQ_ROOT = $previousRoot
        }
    }

    $report = New-CanaryReport -Document $document -RunRecords $allRuns -RootPath $rootPath -FilePath $canaryPath -Mode 'run' -Executed $executed -Notes $notes
    $report.repeats = $repeats
    Write-CanaryOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-CanaryStatusHuman -Report $report)
    exit 0
} catch {
    $exitCode = 2
    if ($Json) {
        Write-Output (ConvertTo-CanaryJsonAscii -InputObject ([ordered]@{ tool = 'canary'; ok = $false; error = ('internal error: ' + $_.Exception.Message) }) -Depth 6)
    } else {
        Write-Output ('canary: internal error: ' + $_.Exception.Message)
    }
}

exit $exitCode
