# ab-experiment.ps1 - prompt A/B experiments over the shared inbox engine (P3).
#
# Define N prompt variants for one task, run every variant through the SAME
# engine the poller/daemon/replay use (inbox-engine.ps1 -> Process-InboxFile),
# then compare variants and elect a winner.
#
#   .\ab-experiment.ps1 -Define -Id AB1 -Agent dev-1 -Variant "a:prompt A","b:prompt B"
#   .\ab-experiment.ps1 -Run -Id AB1 [-Repeats 3] [-DryRun]
#   .\ab-experiment.ps1 -Status -Id AB1 [-Json]
#   .\ab-experiment.ps1 -List [-Json]
#
# State: <root>\.memory\experiments\<id>.json - definition + EVERY run (appended,
# never rewritten). Per-run metrics: success, attempts, duration, confidence,
# reviewer verdicts / disagreement, failure-memory hit. Winner order:
# success-rate -> average confidence -> average duration.
#
# Safety: the prompt is DATA. The only execution path is inbox-engine.ps1 and the
# engine is not even loaded unless -Run (without -DryRun) is given.
# Root: -Root > $env:AGENT_HQ_ROOT > repo derived from this script > cwd.
#
# Exit codes: 0 ok, 1 cannot fulfil the request, 2 internal error.
# Pure PowerShell 5.1. CRLF. No secrets are read, printed or written.

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Define,
    [switch]$Run,
    [switch]$Status,
    [switch]$List,
    [switch]$Json,
    [switch]$DryRun,
    [string]$Id = '',
    [string]$Agent = '',
    [string[]]$Variant = @(),
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingVariants = @(),
    [int]$Repeats = 1,
    [string]$Root = '',
    [int]$MaxFiles = 500
)

$script:AbScriptRoot = $PSScriptRoot
$script:AbUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:AbIdGuard = '^[A-Za-z0-9._-]{1,40}$'
$script:AbLabelGuard = '^[A-Za-z0-9._-]{1,12}$'
$script:AbAgentGuard = '^[A-Za-z0-9._-]{1,40}$'
$script:AbMaxJsonBytes = 8 * 1024 * 1024

function Get-AbRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:AbScriptRoot)) {
        return (Split-Path (Split-Path $script:AbScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-AbExperimentsDir {
    param([string]$RootPath)
    return (Join-Path (Join-Path $RootPath '.memory') 'experiments')
}

function Get-AbExperimentPath {
    param([string]$ExperimentsDir, [string]$Id)
    return (Join-Path $ExperimentsDir ($Id + '.json'))
}

function Get-AbBufferPath {
    param([string]$RootPath)
    return (Join-Path $RootPath 'CONTEXT-BUFFER.md')
}

function Get-AbStamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-AbInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function ConvertTo-AbDouble {
    param($Value, [double]$Default = 0.0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Default
}

# ASCII-only JSON: captured text is code-page dependent, escaping keeps it stable.
function ConvertTo-AbJsonAscii {
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

function Read-AbJson {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt $script:AbMaxJsonBytes) { return $null }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-AbJsonFile {
    param([string]$Path, $Object)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Object -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, $script:AbUtf8NoBom)
}

# "label:prompt" -> ordered list; every problem is collected, never thrown.
function ConvertTo-AbVariantList {
    param([string[]]$Definitions)
    $parsed = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($definition in @($Definitions)) {
        $text = [string]$definition
        $index = $text.IndexOf(':')
        if ($index -lt 1) {
            [void]$errors.Add("variant '$text' is not in the 'label:prompt' shape")
            continue
        }
        $label = $text.Substring(0, $index).Trim()
        $prompt = $text.Substring($index + 1)
        if ($label -notmatch $script:AbLabelGuard) {
            [void]$errors.Add("variant label '$label' rejected: letters, digits, dot, underscore or hyphen, max 12")
            continue
        }
        if ([string]::IsNullOrWhiteSpace($prompt)) {
            [void]$errors.Add("variant '$label' has an empty prompt")
            continue
        }
        if (-not $seen.Add($label)) {
            [void]$errors.Add("variant '$label' is declared twice")
            continue
        }
        [void]$parsed.Add([ordered]@{ label = $label; prompt = $prompt })
    }
    return [pscustomobject]@{ variants = @($parsed); errors = @($errors) }
}

# Normalise the runs array of a stored document (tolerates broken/partial records).
function Get-AbRunRecords {
    param($Document)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Document) { return @() }
    foreach ($run in @($Document.runs)) {
        if ($null -eq $run) { continue }
        [void]$out.Add([ordered]@{
            run_id                = [string]$run.run_id
            label                 = [string]$run.label
            seq                   = ConvertTo-AbInt -Value $run.seq
            repeat                = ConvertTo-AbInt -Value $run.repeat
            started_at            = [string]$run.started_at
            finished_at           = [string]$run.finished_at
            duration_ms           = ConvertTo-AbInt -Value $run.duration_ms
            attempt_ms            = ConvertTo-AbInt -Value $run.attempt_ms
            success               = [bool]$run.success
            engine_status         = [string]$run.engine_status
            engine_reason         = [string]$run.engine_reason
            attempts              = ConvertTo-AbInt -Value $run.attempts
            failed_attempts       = ConvertTo-AbInt -Value $run.failed_attempts
            exit_code             = [string]$run.exit_code
            confidence            = ConvertTo-AbDouble -Value $run.confidence
            confidence_level      = [string]$run.confidence_level
            verdicts_accept       = ConvertTo-AbInt -Value $run.verdicts_accept
            verdicts_reject       = ConvertTo-AbInt -Value $run.verdicts_reject
            verdicts_partial      = ConvertTo-AbInt -Value $run.verdicts_partial
            reviewer_disagreement = [bool]$run.reviewer_disagreement
            failure_memory_hit    = [bool]$run.failure_memory_hit
            error                 = [string]$run.error
        })
    }
    return @($out)
}

function Get-AbVariantMetrics {
    param($VariantList, $RunRecords)
    $out = New-Object System.Collections.ArrayList
    foreach ($variant in @($VariantList)) {
        if ($null -eq $variant) { continue }
        $label = [string]$variant.label
        $mine = @(@($RunRecords) | Where-Object { $null -ne $_ -and [string]$_.label -eq $label })
        $count = $mine.Count
        $successes = @($mine | Where-Object { [bool]$_.success }).Count
        $failHits = @($mine | Where-Object { [bool]$_.failure_memory_hit }).Count
        $disagreements = @($mine | Where-Object { [bool]$_.reviewer_disagreement }).Count
        $confSum = 0.0
        $durSum = 0.0
        $attemptSum = 0.0
        foreach ($run in $mine) {
            $confSum += [double]$run.confidence
            $durSum += [double]$run.duration_ms
            $attemptSum += [double]$run.attempts
        }
        $rate = 0.0
        $avgConf = 0.0
        $avgDur = 0
        $avgAttempts = 0.0
        if ($count -gt 0) {
            $rate = [math]::Round($successes / $count, 2)
            $avgConf = [math]::Round($confSum / $count, 2)
            $avgDur = [int][math]::Round($durSum / $count)
            $avgAttempts = [math]::Round($attemptSum / $count, 2)
        }
        [void]$out.Add([ordered]@{
            label           = $label
            prompt_chars    = ([string]$variant.prompt).Length
            runs            = $count
            successes       = $successes
            success_rate    = $rate
            avg_confidence  = $avgConf
            avg_duration_ms = $avgDur
            avg_attempts    = $avgAttempts
            failure_hits    = $failHits
            disagreements   = $disagreements
        })
    }
    return @($out)
}

# Winner: success-rate desc -> average confidence desc -> average duration asc.
function Select-AbWinner {
    param($Metrics)
    $pool = @(@($Metrics) | Where-Object { $null -ne $_ -and (ConvertTo-AbInt -Value $_.runs) -gt 0 })
    if ($pool.Count -eq 0) { return $null }
    $sortKeys = @(
        @{ Expression = { [double]$_.success_rate }; Descending = $true },
        @{ Expression = { [double]$_.avg_confidence }; Descending = $true },
        @{ Expression = { [int]$_.avg_duration_ms }; Descending = $false }
    )
    $ordered = @($pool | Sort-Object -Property $sortKeys)
    $best = $ordered[0]
    return [ordered]@{
        label           = [string]$best.label
        runs            = [int]$best.runs
        success_rate    = [double]$best.success_rate
        avg_confidence  = [double]$best.avg_confidence
        avg_duration_ms = [int]$best.avg_duration_ms
        reason          = ('success-rate ' + [string]$best.success_rate + ' -> confidence ' + [string]$best.avg_confidence + ' -> duration ' + [string]$best.avg_duration_ms + ' ms')
    }
}

function New-AbReport {
    param($Document, $RunRecords, [string]$RootPath, [string]$FilePath, [string]$Mode = 'status', [int]$Executed = 0, $Notes = @())
    $variants = @($Document.variants)
    $metrics = @(Get-AbVariantMetrics -VariantList $variants -RunRecords $RunRecords)
    return [ordered]@{
        tool         = 'ab-experiment'
        generated_at = Get-AbStamp
        ok           = $true
        mode         = $Mode
        executed     = $Executed
        id           = [string]$Document.id
        agent        = [string]$Document.agent
        created      = [string]$Document.created
        updated      = [string]$Document.updated
        file         = $FilePath
        root         = $RootPath
        runs_total   = @($RunRecords).Count
        variants     = $variants
        metrics      = $metrics
        winner       = (Select-AbWinner -Metrics $metrics)
        notes        = @($Notes)
        runs         = @($RunRecords)
    }
}

function Format-AbStatusHuman {
    param($Report)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== agent-hq prompt A/B: ' + [string]$Report.id + ' ===')
    [void]$lines.Add('agent    : ' + [string]$Report.agent)
    [void]$lines.Add('file     : ' + [string]$Report.file)
    [void]$lines.Add('variants : ' + @($Report.variants).Count + '   runs: ' + [int]$Report.runs_total)
    [void]$lines.Add('')
    [void]$lines.Add(('  {0,-14} {1,5} {2,8} {3,6} {4,7} {5,10} {6,9} {7,9}' -f 'label', 'runs', 'success', 'rate', 'conf', 'avg_ms', 'fail-mem', 'disagree'))
    foreach ($metric in @($Report.metrics)) {
        [void]$lines.Add(('  {0,-14} {1,5} {2,8} {3,6} {4,7} {5,10} {6,9} {7,9}' -f
            [string]$metric.label, [int]$metric.runs, [int]$metric.successes, [double]$metric.success_rate,
            [double]$metric.avg_confidence, [int]$metric.avg_duration_ms, [int]$metric.failure_hits, [int]$metric.disagreements))
    }
    [void]$lines.Add('')
    if ($null -eq $Report.winner) {
        [void]$lines.Add('winner   : (no runs yet - pass -Run)')
    } else {
        [void]$lines.Add('winner   : ' + [string]$Report.winner.label + '  (' + [string]$Report.winner.reason + ')')
    }
    return ($lines -join "`r`n")
}

function Get-AbExperimentSummaries {
    param([string]$ExperimentsDir, [string]$RootPath)
    $summaries = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ExperimentsDir -PathType Container)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $ExperimentsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $shortId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $doc = Read-AbJson -Path $file.FullName
        if ($null -eq $doc) {
            [void]$summaries.Add([ordered]@{
                id = $shortId; ok = $false; agent = ''; variants = 0; runs = 0; winner = ''; file = $file.FullName
            })
            continue
        }
        $variants = @($doc.variants)
        $runs = @(Get-AbRunRecords -Document $doc)
        $metrics = @(Get-AbVariantMetrics -VariantList $variants -RunRecords $runs)
        $winner = Select-AbWinner -Metrics $metrics
        $winnerLabel = ''
        if ($null -ne $winner) { $winnerLabel = [string]$winner.label }
        [void]$summaries.Add([ordered]@{
            id = [string]$doc.id
            ok = $true
            agent = [string]$doc.agent
            variants = $variants.Count
            runs = $runs.Count
            winner = $winnerLabel
            file = $file.FullName
        })
    }
    return @($summaries)
}

function Format-AbListHuman {
    param($Summaries, [string]$ExperimentsDir)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== agent-hq prompt A/B experiments ===')
    [void]$lines.Add('dir      : ' + $ExperimentsDir)
    $items = @($Summaries)
    if ($items.Count -eq 0) {
        [void]$lines.Add('  no experiments defined')
        return ($lines -join "`r`n")
    }
    [void]$lines.Add(('  {0,-20} {1,8} {2,5} {3,-14}' -f 'id', 'variants', 'runs', 'winner'))
    foreach ($item in $items) {
        $state = ''
        if (-not [bool]$item.ok) { $state = ' (broken json)' }
        [void]$lines.Add(('  {0,-20} {1,8} {2,5} {3,-14}{4}' -f [string]$item.id, [int]$item.variants, [int]$item.runs, [string]$item.winner, $state))
    }
    return ($lines -join "`r`n")
}

function Write-AbOutput {
    param([string]$HumanText, $JsonObject, [bool]$AsJson)
    if ($AsJson) { Write-Output (ConvertTo-AbJsonAscii -InputObject $JsonObject -Depth 10) }
    else { Write-Output $HumanText }
}

# Enqueue one run and process it with the shared engine, then snapshot the metrics.
function Invoke-AbOneRun {
    param(
        [string]$RootPath,
        [string]$ExperimentId,
        [string]$AgentName,
        [string]$Label,
        [string]$Prompt,
        [string]$RunId,
        [int]$Seq,
        [int]$Repeat
    )

    $inboxDir = Join-Path (Join-Path (Join-Path $RootPath '.memory') 'inbox') $AgentName
    if (-not (Test-Path -LiteralPath $inboxDir -PathType Container)) {
        New-Item -ItemType Directory -Path $inboxDir -Force | Out-Null
    }
    $inboxFile = Join-Path $inboxDir ($RunId + '.json')
    $message = [ordered]@{
        id             = $RunId
        from           = 'ab-experiment'
        to             = $AgentName
        type           = 'task'
        priority       = 'normal'
        payload        = $Prompt
        created        = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        experiment_id  = $ExperimentId
        variant_label  = $Label
        variant_repeat = $Repeat
    }
    [System.IO.File]::WriteAllText($inboxFile, ($message | ConvertTo-Json -Depth 6), $script:AbUtf8NoBom)

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
    $evidenceDoc = Read-AbJson -Path $evidenceFile
    if ($null -ne $evidenceDoc) { $attempts = @($evidenceDoc.attempts | Where-Object { $null -ne $_ }) }

    $failedAttempts = 0
    $attemptMs = 0
    $lastExit = ''
    foreach ($attempt in $attempts) {
        $exit = 0
        $hasExit = $false
        if ($null -ne $attempt.exit_code -and -not [string]::IsNullOrWhiteSpace([string]$attempt.exit_code)) {
            $hasExit = [int]::TryParse([string]$attempt.exit_code, [ref]$exit)
        }
        if ($hasExit) {
            $lastExit = [string]$exit
            if ($exit -ne 0) { $failedAttempts++ }
        }
        $duration = 0
        if ($null -ne $attempt.duration_ms -and [int]::TryParse([string]$attempt.duration_ms, [ref]$duration)) {
            $attemptMs += $duration
        }
    }

    $success = ($engineStatus -eq 'done')
    $confidence = 0.0
    $confidenceLevel = ''
    $accept = 0
    $reject = 0
    $partial = 0
    $disagreement = $false
    $failureHit = $false
    try {
        $verdict = Get-TaskConfidence -TaskId $RunId -Root $RootPath -BufferPath (Get-AbBufferPath -RootPath $RootPath)
        if ($null -ne $verdict) {
            $confidence = [double]$verdict.confidence
            $confidenceLevel = [string]$verdict.level
            $accept = [int]$verdict.verdicts_accept
            $reject = [int]$verdict.verdicts_reject
            $partial = [int]$verdict.verdicts_partial
            $disagreement = [bool]$verdict.disagreement
            $failureHit = [bool]$verdict.failure_memory_hit
        }
    } catch {
        if ([string]::IsNullOrWhiteSpace($runError)) { $runError = 'confidence: ' + $_.Exception.Message }
    }

    return [ordered]@{
        run_id                = $RunId
        label                 = $Label
        seq                   = $Seq
        repeat                = $Repeat
        started_at            = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        finished_at           = $finishedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        duration_ms           = [int]$watch.ElapsedMilliseconds
        attempt_ms            = [int]$attemptMs
        success               = [bool]$success
        engine_status         = $engineStatus
        engine_reason         = $engineReason
        attempts              = $attempts.Count
        failed_attempts       = $failedAttempts
        exit_code             = $lastExit
        confidence            = [double]$confidence
        confidence_level      = $confidenceLevel
        verdicts_accept       = $accept
        verdicts_reject       = $reject
        verdicts_partial      = $partial
        reviewer_disagreement = $disagreement
        failure_memory_hit    = $failureHit
        error                 = $runError
    }
}

function Save-AbExperiment {
    param([string]$Path, $Document, $RunRecords)
    $document = [ordered]@{
        id       = [string]$Document.id
        agent    = [string]$Document.agent
        created  = [string]$Document.created
        updated  = Get-AbStamp
        variants = @($Document.variants)
        runs     = @($RunRecords)
    }
    Write-AbJsonFile -Path $Path -Object $document
    return $document
}

# ===========================================================================
# Main
# ===========================================================================

$exitCode = 0
try {
    $rootPath = Get-AbRoot -RootValue $Root
    $experimentsDir = Get-AbExperimentsDir -RootPath $rootPath
    $repeats = $Repeats
    $notes = New-Object System.Collections.ArrayList

    if ($repeats -lt 1) {
        [void]$notes.Add('Repeats < 1 was clamped to 1')
        $repeats = 1
    }

    # ---- list --------------------------------------------------------------
    if ($List -and -not $Define) {
        $summaries = @(Get-AbExperimentSummaries -ExperimentsDir $experimentsDir -RootPath $rootPath)
        $report = [ordered]@{
            tool         = 'ab-experiment'
            generated_at = Get-AbStamp
            ok           = $true
            dir          = $experimentsDir
            experiments  = $summaries
        }
        Write-AbOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-AbListHuman -Summaries $summaries -ExperimentsDir $experimentsDir)
        exit 0
    }

    $experimentId = $Id.Trim()

    if ($Define) {
        $problems = New-Object System.Collections.ArrayList
        # A second and later label:prompt arrives as a bare positional token (ValueFromRemainingArguments),
        # so the full definition list is the named values followed by the remaining ones.
        $variantDefinitions = @(@($Variant) + @($RemainingVariants))
        if ([string]::IsNullOrWhiteSpace($experimentId)) { [void]$problems.Add('-Id is required') }
        elseif ($experimentId -notmatch $script:AbIdGuard) { [void]$problems.Add("experiment id '$experimentId' rejected: letters, digits, dot, underscore or hyphen, max 40") }
        if ([string]::IsNullOrWhiteSpace($Agent)) { [void]$problems.Add('-Agent is required') }
        elseif ($Agent -notmatch $script:AbAgentGuard) { [void]$problems.Add("agent '$Agent' rejected by the file-name guard") }
        if (@($variantDefinitions).Count -eq 0) { [void]$problems.Add('at least one -Variant label:prompt is required') }
        foreach ($problemText in @($problems)) { [void]$notes.Add('define: ' + $problemText) }

        $parsed = ConvertTo-AbVariantList -Definitions $variantDefinitions
        foreach ($problemText in @($parsed.errors)) { [void]$notes.Add('define: ' + $problemText) }
        if (@($parsed.variants).Count -eq 0) { [void]$notes.Add('define: no usable variant definition') }

        if ($problems.Count -gt 0 -or $parsed.errors.Count -gt 0 -or @($parsed.variants).Count -eq 0) {
            $message = 'cannot define experiment: ' + (@($notes) -join '; ')
            if ($Json) {
                Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = $message; notes = @($notes) }) -Depth 6)
            } else {
                Write-Output ('ab-experiment: ' + $message)
            }
            exit 1
        }

        $experimentsDirCreated = -not (Test-Path -LiteralPath $experimentsDir -PathType Container)
        if ($experimentsDirCreated) { New-Item -ItemType Directory -Path $experimentsDir -Force | Out-Null }
        $experimentPath = Get-AbExperimentPath -ExperimentsDir $experimentsDir -Id $experimentId

        $existing = Read-AbJson -Path $experimentPath
        $keptRuns = @()
        $created = Get-AbStamp
        if ($null -ne $existing) {
            $keptRuns = @(Get-AbRunRecords -Document $existing)
            if (-not [string]::IsNullOrWhiteSpace([string]$existing.created)) { $created = [string]$existing.created }
            if ($keptRuns.Count -gt 0) { [void]$notes.Add('kept ' + $keptRuns.Count + ' existing run(s)') }
        } elseif (Test-Path -LiteralPath $experimentPath -PathType Leaf) {
            [void]$notes.Add('existing file was unreadable and got replaced')
        }

        $document = Save-AbExperiment -Path $experimentPath -Document ([ordered]@{
            id = $experimentId; agent = $Agent; created = $created; variants = @($parsed.variants)
        }) -RunRecords $keptRuns

        $report = New-AbReport -Document $document -RunRecords $keptRuns -RootPath $rootPath -FilePath $experimentPath -Mode 'define' -Notes $notes
        Write-AbOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText ((Format-AbStatusHuman -Report $report) + "`r`n" + 'defined: ' + @($parsed.variants).Count + ' variant(s); pass -Run to execute')
        exit 0
    }

    if (-not ($Run -or $Status)) {
        Write-Output 'ab-experiment: nothing to do - pass -Define, -Run, -Status or -List'
        exit 2
    }

    if ([string]::IsNullOrWhiteSpace($experimentId)) {
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; error = '-Id is required' }) -Depth 4) }
        else { Write-Output 'ab-experiment: -Id is required' }
        exit 1
    }
    if ($experimentId -notmatch $script:AbIdGuard) {
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = 'experiment id rejected by the file-name guard' }) -Depth 4) }
        else { Write-Output ('ab-experiment: experiment id rejected by the file-name guard: ' + $experimentId) }
        exit 1
    }

    $experimentPath = Get-AbExperimentPath -ExperimentsDir $experimentsDir -Id $experimentId
    $document = Read-AbJson -Path $experimentPath
    if ($null -eq $document) {
        $reason = if (Test-Path -LiteralPath $experimentPath -PathType Leaf) { 'experiment file is unreadable or not valid JSON' } else { 'experiment not found' }
        $message = $reason + ': ' + $experimentPath
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = $message }) -Depth 4) }
        else { Write-Output ('ab-experiment: ' + $message) }
        exit 1
    }

    $variants = @($document.variants)
    $knownRuns = @(Get-AbRunRecords -Document $document)
    $agentName = [string]$document.agent
    if ([string]::IsNullOrWhiteSpace($agentName) -or $agentName -notmatch $script:AbAgentGuard) {
        $message = 'definition has no usable agent name'
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = $message }) -Depth 4) }
        else { Write-Output ('ab-experiment: ' + $message) }
        exit 1
    }
    if ($variants.Count -eq 0) {
        $message = 'definition holds no variants'
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = $message }) -Depth 4) }
        else { Write-Output ('ab-experiment: ' + $message) }
        exit 1
    }

    $execute = ([bool]$Run -and -not [bool]$DryRun)

    if ($Status -and -not $execute) {
        # read-only status: metrics + winner, nothing is written
        $report = New-AbReport -Document $document -RunRecords $knownRuns -RootPath $rootPath -FilePath $experimentPath -Mode 'status' -Notes $notes
        Write-AbOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-AbStatusHuman -Report $report)
        exit 0
    }

    if (-not $execute) {
        # plan only: nothing is loaded, nothing is written
        $planned = New-Object System.Collections.ArrayList
        foreach ($variantItem in $variants) {
            $label = [string]$variantItem.label
            $nextSeq = 1
            foreach ($runItem in $knownRuns) {
                if ([string]$runItem.label -eq $label -and (ConvertTo-AbInt -Value $runItem.seq) -ge $nextSeq) {
                    $nextSeq = (ConvertTo-AbInt -Value $runItem.seq) + 1
                }
            }
            for ($index = 0; $index -lt $repeats; $index++) {
                [void]$planned.Add([ordered]@{
                    label  = $label
                    repeat = ($index + 1)
                    run_id = ($experimentId + '-' + $label + '-n' + ($nextSeq + $index))
                })
            }
        }
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('=== agent-hq prompt A/B run plan: ' + $experimentId + ' ===')
        [void]$lines.Add('agent    : ' + $agentName)
        [void]$lines.Add('root     : ' + $rootPath)
        [void]$lines.Add('file     : ' + $experimentPath)
        [void]$lines.Add('variants : ' + $variants.Count + '   repeats: ' + $repeats + '   planned runs: ' + $planned.Count)
        foreach ($plan in $planned) {
            [void]$lines.Add(('  {0,-14} repeat {1,-3} id={2}' -f [string]$plan.label, [int]$plan.repeat, [string]$plan.run_id))
        }
        if ($Run -and $DryRun) { [void]$lines.Add('') ; [void]$lines.Add('dry-run: -Run and -DryRun together - the engine is NOT started') }
        [void]$lines.Add('')
        [void]$lines.Add('dry-run: nothing was written and no engine run was started (pass -Run to execute)')
        $report = [ordered]@{
            tool        = 'ab-experiment'
            generated_at = Get-AbStamp
            ok          = $true
            mode        = 'dry-run'
            id          = $experimentId
            agent       = $agentName
            root        = $rootPath
            file        = $experimentPath
            repeats     = $repeats
            planned     = $planned
            runs_total  = $knownRuns.Count
        }
        Write-AbOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText ($lines -join "`r`n")
        exit 0
    }

    # ---- real run ----------------------------------------------------------
    $enginePath = Join-Path $script:AbScriptRoot 'inbox-engine.ps1'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        $message = 'inbox-engine.ps1 missing - cannot run: ' + $enginePath
        if ($Json) { Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; id = $experimentId; error = $message }) -Depth 4) }
        else { Write-Output ('ab-experiment: ' + $message) }
        exit 1
    }

    $previousRoot = $env:AGENT_HQ_ROOT
    $env:AGENT_HQ_ROOT = $rootPath
    try {
        . $enginePath
        . (Join-Path $script:AbScriptRoot 'confidence.ps1')

        $allRuns = @($knownRuns)
        $evidenceDir = Join-Path (Join-Path $rootPath '.memory') 'evidence'
        $variantInboxDir = Join-Path (Join-Path (Join-Path $rootPath '.memory') 'inbox') $agentName
        for ($repeatIndex = 1; $repeatIndex -le $repeats; $repeatIndex++) {
            foreach ($variantItem in $variants) {
                $label = [string]$variantItem.label
                $prompt = [string]$variantItem.prompt
                $nextSeq = 1
                foreach ($runItem in $allRuns) {
                    if ([string]$runItem.label -eq $label -and (ConvertTo-AbInt -Value $runItem.seq) -ge $nextSeq) {
                        $nextSeq = (ConvertTo-AbInt -Value $runItem.seq) + 1
                    }
                }
                $runId = $experimentId + '-' + $label + '-n' + $nextSeq
                $guard = 0
                while ($guard -lt 1000) {
                    $taken = (Test-Path -LiteralPath (Join-Path $evidenceDir ($runId + '.json')) -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $variantInboxDir ($runId + '.json')) -PathType Leaf)
                    if (-not $taken) { break }
                    $nextSeq++
                    $runId = $experimentId + '-' + $label + '-n' + $nextSeq
                    $guard++
                }

                $record = Invoke-AbOneRun -RootPath $rootPath -ExperimentId $experimentId -AgentName $agentName `
                    -Label $label -Prompt $prompt -RunId $runId -Seq $nextSeq -Repeat $repeatIndex
                $allRuns = @($allRuns) + @($record)
                $document = Save-AbExperiment -Path $experimentPath -Document $document -RunRecords $allRuns
            }
        }
    } finally {
        if ($null -eq $previousRoot) {
            Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
        } else {
            $env:AGENT_HQ_ROOT = $previousRoot
        }
    }

    $report = New-AbReport -Document $document -RunRecords $allRuns -RootPath $rootPath -FilePath $experimentPath -Mode 'run' -Executed ($allRuns.Count - $knownRuns.Count) -Notes $notes
    Write-AbOutput -AsJson ([bool]$Json) -JsonObject $report -HumanText (Format-AbStatusHuman -Report $report)
    exit 0
} catch {
    $exitCode = 2
    if ($Json) {
        Write-Output (ConvertTo-AbJsonAscii -InputObject ([ordered]@{ tool = 'ab-experiment'; ok = $false; error = ('internal error: ' + $_.Exception.Message) }) -Depth 6)
    } else {
        Write-Output ('ab-experiment: internal error: ' + $_.Exception.Message)
    }
}

exit $exitCode
