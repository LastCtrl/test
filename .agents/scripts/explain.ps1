# explain.ps1 - "what happened to this task / agent" (P3-3).
#
# Read-only aggregator over the artifacts the fleet already produces. It writes
# nothing, never throws on missing or broken data and prints a short human
# chronology plus a "what went wrong" section:
#
#   * CONTEXT-BUFFER.md  - agent self-reports (one header block per message)
#   * .memory\evidence\  - machine attempt records (exit_code / reason / timings)
#   * traces.jsonl       - opencode spans written by .opencode\plugins\tracer.js
#   * reviewer verdicts  - parsed by review-disagreement.ps1 (dot-sourced here)
#
# Usage:
#   .\explain.ps1 -TaskId P3-2
#   .\explain.ps1 -Agent qa-engineer
#   .\explain.ps1 -TaskId P3-2 -Json
#   .\explain.ps1                 # no selector -> latest task found in the buffer
#
# Root / traces resolution (same precedence as the other fleet scripts):
#   root   : -Root > $env:AGENT_HQ_ROOT > <repo derived from this script> > cwd
#   traces : -TracesDir > $env:AGENT_HQ_TRACES_DIR > %LOCALAPPDATA%\opencode\agent-hq-traces
#
# The JSON stream is ASCII-only (non-ASCII is \uXXXX-escaped) so it stays
# parseable regardless of the console codepage when stdout is captured.
#
# Exit code: 0 for any completed read (even with zero data), 1 only when the
# aggregation itself failed unexpectedly.
#
# Pure PowerShell 5.1. CRLF. No secrets are read, printed or written.

[CmdletBinding()]
param(
    [string]$TaskId = '',
    [string]$Agent = '',
    [switch]$Json,
    [string]$Root = '',
    [string]$TracesDir = '',
    [string]$BufferPath = '',
    [int]$MaxTraceBytes = 524288,
    [int]$MaxTimeline = 200,
    [int]$MaxSpans = 2000,
    [int]$MaxEvidenceFiles = 500
)

$script:ExplainScriptRoot = $PSScriptRoot
$script:ExplainMaxFileBytes = 8 * 1024 * 1024
$script:ExplainTaskIdLabel = '(?i)\btask_id\s*[:=]\s*["'']?([A-Za-z0-9._-]{1,64})'
$script:ExplainEvidenceMention = '(?i)\.memory[\\/]evidence[\\/]([A-Za-z0-9._-]+)\.json'
$script:ExplainTaskTag = '(?<![A-Za-z0-9_-])(?:[A-Z]{1,3}\d*-\d+(?:-\d+)?|[A-Z]{1,3}\d+-[A-Z][A-Z0-9]*)(?![A-Za-z0-9_-])'
$script:ExplainNonTaskTag = '^UTF-\d+$'
$script:ExplainHeaderPattern = '^\s*\[(?<stamp>[^\]]+)\]\s+(?<agent>[\w.\-]+)\s*(?:->|\u2192|-->|>>)\s*(?<to>[\w.\-]+)\s*:\s*(?<rest>.*)$'
$script:ExplainStatusPattern = '(?im)^\s*STATUS\s*:\s*(?<tok>[A-Za-z_\-]+)'
$script:ExplainTypePattern = '(?im)^\s*TYPE\s*:\s*(?<tok>[A-Za-z_\-]+)'
$script:ExplainFailedStatuses = @('error', 'failed', 'failure', 'timeout', 'blocked', 'dead')

# review-disagreement.ps1 owns the reviewer-verdict heuristics (buffer parsing,
# verdict normalisation, disagreement detection). Dot-sourcing only loads its
# functions: that file runs its CLI solely on a direct invocation.
$script:ExplainVerdictsAvailable = $false
$verdictScript = Join-Path $script:ExplainScriptRoot 'review-disagreement.ps1'
if (Test-Path -LiteralPath $verdictScript -PathType Leaf) {
    try {
        . $verdictScript
        $script:ExplainVerdictsAvailable = $true
    } catch {
        $script:ExplainVerdictsAvailable = $false
    }
}

# ===========================================================================
# Path / value helpers
# ===========================================================================

function Get-ExplainRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:ExplainScriptRoot)) {
        return (Split-Path (Split-Path $script:ExplainScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-ExplainTracesDir {
    param([string]$TracesDirValue)
    if (-not [string]::IsNullOrWhiteSpace($TracesDirValue)) { return $TracesDirValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_TRACES_DIR)) { return $env:AGENT_HQ_TRACES_DIR }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'opencode') 'agent-hq-traces')
}

function Get-ExplainBufferPath {
    param([string]$BufferPathValue, [string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($BufferPathValue)) { return $BufferPathValue }
    if ($script:ExplainVerdictsAvailable) {
        try { return (Get-ReviewBufferPath -Root $RootValue -BufferPath '') } catch { }
    }
    return (Join-Path $RootValue 'CONTEXT-BUFFER.md')
}

function Get-ExplainEvidenceDir {
    param([string]$RootValue)
    return (Join-Path (Join-Path $RootValue '.memory') 'evidence')
}

function ConvertTo-ExplainInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

# UTC instant for sorting. Handles ISO with offset ("...Z"), naive ISO and
# "yyyy-MM-dd HH:mm" style stamps (treated as local time). $null when unparsable.
function ConvertTo-ExplainUtc {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    $dto = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $dto.UtcDateTime
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        return $dt.ToUniversalTime()
    }
    return $null
}

# review-disagreement.ps1 returns naive local DateTimes (Kind=Unspecified) while
# traces/evidence yield Kind=Utc instants. Sort-Object compares raw ticks and
# ignores Kind, so mixing them silently mis-orders the timeline; everything is
# normalised to Kind=Utc before it is stored or compared.
function ConvertTo-ExplainUtcKind {
    param($Value)
    if ($null -eq $Value) { return $null }
    $dt = [datetime]$Value
    if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
        return [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local).ToUniversalTime()
    }
    return $dt.ToUniversalTime()
}

function Format-ExplainTime {
    param($Value, [string]$Fallback = '')
    if ($null -ne $Value) {
        return ([datetime]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    # "[TIME]" and similar placeholders are not timestamps: only a fallback that
    # actually contains a digit is worth showing.
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        $trimmed = $Fallback.Trim()
        if ($trimmed -match '\d') { return $trimmed }
    }
    return '(no time)'
}

function Format-ExplainDuration {
    param([int]$Ms)
    if ($Ms -le 0) { return '0 ms' }
    if ($Ms -lt 1000) { return ($Ms.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' ms') }
    if ($Ms -lt 60000) {
        $seconds = [math]::Round($Ms / 1000.0, 1)
        return ($seconds.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' s')
    }
    $minutes = [math]::Round($Ms / 60000.0, 1)
    return ($minutes.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' min')
}

# ASCII-only JSON: ConvertTo-Json may pass non-ASCII through, and the captured
# stdout of a child PowerShell is codepage-dependent. Escaping makes it stable.
function ConvertTo-ExplainJson {
    param($InputObject, [int]$Depth = 8)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) {
            [void]$builder.Append($ch)
        } else {
            [void]$builder.AppendFormat('\u{0:x4}', $code)
        }
    }
    return $builder.ToString()
}

# ===========================================================================
# Reading (bounded, never throws)
# ===========================================================================

function Read-ExplainTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt $script:ExplainMaxFileBytes) { return '' }
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        return ''
    }
}

# Tail of a jsonl file (the live traces.jsonl grows unbounded). The first line of
# a truncated read is partial and is dropped. FileShare::ReadWrite keeps a
# concurrent appender (opencode) happy.
function Read-ExplainTraceLines {
    param([string]$Path, [int]$MaxBytes)
    $result = [ordered]@{ lines = @(); truncated = $false; error = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { $result.error = 'not configured'; return [pscustomobject]$result }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $result.error = 'missing'; return [pscustomobject]$result }
    if ($MaxBytes -le 0) { $result.error = 'invalid byte budget'; return [pscustomobject]$result }

    $start = 0
    try {
        $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($length -gt $MaxBytes) { $start = $length - $MaxBytes; $result.truncated = $true }
        $count = [int]($length - $start)
        if ($count -lt 0) { $count = 0 }
        if ($count -eq 0) {
            $text = ''
        } else {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
                $buffer = New-Object -TypeName 'byte[]' -ArgumentList $count
                $read = $stream.Read($buffer, 0, $count)
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            } finally {
                $stream.Dispose()
            }
        }
    } catch {
        $result.error = $_.Exception.Message
        return [pscustomobject]$result
    }

    $lines = @($text -split "`r?`n")
    if ($start -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    $result.lines = @($lines | Where-Object { $_.Trim().Length -gt 0 })
    return [pscustomobject]$result
}

# ===========================================================================
# CONTEXT-BUFFER self-reports
# ===========================================================================

# Task keys a block correlates with: explicit task_id > evidence path mention >
# task-shaped tag. Short names such as "UTF-8" are not tasks and are skipped.
function Get-ExplainTaskKeys {
    param([string]$Text)
    $keys = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($match in [regex]::Matches($Text, $script:ExplainTaskIdLabel)) {
        $key = $match.Groups[1].Value
        if (-not $keys.Contains($key)) { [void]$keys.Add($key) }
    }
    foreach ($match in [regex]::Matches($Text, $script:ExplainEvidenceMention)) {
        $key = $match.Groups[1].Value
        if (-not $keys.Contains($key)) { [void]$keys.Add($key) }
    }
    foreach ($match in [regex]::Matches($Text, $script:ExplainTaskTag)) {
        $key = $match.Value
        if ($key -match $script:ExplainNonTaskTag) { continue }
        if (-not $keys.Contains($key)) { [void]$keys.Add($key) }
    }
    return @($keys)
}

function New-ExplainSelfReport {
    param(
        [string]$Agent,
        [string]$To,
        [string]$Stamp,
        [int]$Line,
        [string]$HeaderLine,
        [string[]]$BodyLines
    )

    $bodyText = (@($BodyLines) -join "`n")
    $typeMatch = [regex]::Match($bodyText, $script:ExplainTypePattern)
    $statusMatch = [regex]::Match($bodyText, $script:ExplainStatusPattern)

    $snippet = ''
    $contentLines = @($BodyLines | Where-Object { $_ -match '^\s*CONTENT\s*:' })
    if ($contentLines.Count -gt 0) {
        $snippet = ($contentLines[0] -replace '^\s*CONTENT\s*:\s*', '').Trim()
    } elseif (@($BodyLines).Count -gt 0) {
        $snippet = ([string]$BodyLines[0]).Trim()
    }
    if ($snippet.Length -gt 160) { $snippet = $snippet.Substring(0, 157) + '...' }

    $timeValue = $null
    if ($script:ExplainVerdictsAvailable) {
        try { $timeValue = ConvertTo-ReviewTime -Stamp $Stamp } catch { $timeValue = $null }
    }
    if ($null -eq $timeValue) { $timeValue = ConvertTo-ExplainUtc -Text $Stamp }
    $timeValue = ConvertTo-ExplainUtcKind -Value $timeValue

    return [PSCustomObject]@{
        agent        = $Agent
        to           = $To
        stamp        = $Stamp
        type         = $(if ($typeMatch.Success) { $typeMatch.Groups['tok'].Value } else { '' })
        status       = $(if ($statusMatch.Success) { $statusMatch.Groups['tok'].Value } else { '' })
        line         = $Line
        task_keys    = @(Get-ExplainTaskKeys -Text ($HeaderLine + "`n" + $bodyText))
        snippet      = $snippet
        time         = $timeValue
        time_display = (Format-ExplainTime -Value $timeValue -Fallback $Stamp)
    }
}

function Get-ExplainSelfReports {
    param([string]$Text)
    $reports = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $lines = @($Text -split "`r?`n")
    $current = $null
    $body = New-Object System.Collections.ArrayList
    $lineNo = 0

    foreach ($line in $lines) {
        $lineNo++
        $header = [regex]::Match($line, $script:ExplainHeaderPattern)
        if ($header.Success) {
            if ($null -ne $current) {
                [void]$reports.Add((New-ExplainSelfReport -Agent $current.agent -To $current.to -Stamp $current.stamp `
                    -Line $current.line -HeaderLine $current.header -BodyLines @($body)))
            }
            $body.Clear()
            if (-not [string]::IsNullOrWhiteSpace($header.Groups['rest'].Value)) { [void]$body.Add($header.Groups['rest'].Value) }
            $current = [PSCustomObject]@{
                agent  = $header.Groups['agent'].Value.Trim().ToLowerInvariant()
                to     = $header.Groups['to'].Value.Trim().ToLowerInvariant()
                stamp  = $header.Groups['stamp'].Value
                line   = $lineNo
                header = $line
            }
        } elseif ($null -ne $current) {
            [void]$body.Add($line)
        }
    }
    if ($null -ne $current) {
        [void]$reports.Add((New-ExplainSelfReport -Agent $current.agent -To $current.to -Stamp $current.stamp `
            -Line $current.line -HeaderLine $current.header -BodyLines @($body)))
    }
    return @($reports)
}

# ===========================================================================
# Machine evidence (.memory\evidence\<task_id>.json)
# ===========================================================================

function Get-ExplainEvidence {
    param([string]$RootValue, [string]$TaskIdValue, [string]$AgentValue, [int]$MaxFiles)

    $dir = Get-ExplainEvidenceDir -RootValue $RootValue
    $out = [ordered]@{
        dir           = $dir
        file          = ''
        exists        = $false
        attempts      = @()
        read_errors   = @()
        scanned_files = 0
    }

    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $out.read_errors += 'evidence directory missing'
        return [pscustomobject]$out
    }

    $documents = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($TaskIdValue)) {
        if ($TaskIdValue -match '^[A-Za-z0-9._-]{1,64}$') {
            $candidate = Join-Path $dir ($TaskIdValue + '.json')
            $out.file = $candidate
            $out.exists = Test-Path -LiteralPath $candidate -PathType Leaf
            if ($out.exists) { [void]$documents.Add($candidate) }
            else { $out.read_errors += ('no evidence file for ' + $TaskIdValue) }
        } else {
            $out.read_errors += 'task id rejected by the file-name guard'
        }
    } else {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($files.Count -gt $MaxFiles) {
            $files = @($files | Select-Object -First $MaxFiles)
            $out.read_errors += ('evidence files capped at ' + $MaxFiles)
        }
        foreach ($file in $files) { [void]$documents.Add($file.FullName) }
        if ($documents.Count -eq 1) { $out.file = [string]$documents[0] }
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($document in $documents) {
        $out.scanned_files++
        $raw = Read-ExplainTextFile -Path $document
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $out.read_errors += ('unreadable evidence file: ' + $document)
            continue
        }
        $json = $null
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        if ($null -eq $json) {
            $out.read_errors += ('broken evidence json: ' + $document)
            continue
        }
        foreach ($attempt in @($json.attempts)) {
            if ($null -eq $attempt) { continue }
            $attemptAgent = [string]$attempt.agent
            if ((-not [string]::IsNullOrWhiteSpace($AgentValue)) -and ($attemptAgent -ne $AgentValue)) { continue }
            [void]$selected.Add([ordered]@{
                attempt_id    = [string]$attempt.attempt_id
                agent         = $attemptAgent
                command       = [string]$attempt.command
                exit_code     = ConvertTo-ExplainInt -Value $attempt.exit_code -Default -1
                status        = [string]$attempt.status
                reason        = [string]$attempt.reason
                started_at    = [string]$attempt.started_at
                finished_at   = [string]$attempt.finished_at
                duration_ms   = ConvertTo-ExplainInt -Value $attempt.duration_ms -Default 0
                stdout_length = ConvertTo-ExplainInt -Value $attempt.stdout_length -Default 0
                stderr_length = ConvertTo-ExplainInt -Value $attempt.stderr_length -Default 0
                source        = $document
            })
        }
    }

    $out.attempts = @($selected | Sort-Object -Property @{ Expression = {
        $instant = ConvertTo-ExplainUtc -Text $_.started_at
        if ($null -eq $instant) { [datetime]::MaxValue } else { $instant }
    } })
    return [pscustomobject]$out
}

# ===========================================================================
# Trace spans (traces.jsonl)
# ===========================================================================

function Get-ExplainTraceData {
    param([string]$TracesDirValue, [string]$TaskIdValue, [string]$AgentValue, [int]$MaxBytes, [int]$MaxSpans)

    $file = Join-Path $TracesDirValue 'traces.jsonl'
    $out = [ordered]@{
        dir           = $TracesDirValue
        file          = $file
        exists        = $false
        truncated     = $false
        records_total = 0
        broken_lines  = 0
        spans         = @()
        read_error    = ''
    }

    $read = Read-ExplainTraceLines -Path $file -MaxBytes $MaxBytes
    $out.truncated = [bool]$read.truncated
    $out.read_error = [string]$read.error
    $out.exists = Test-Path -LiteralPath $file -PathType Leaf
    if (-not $out.exists) { return [pscustomobject]$out }

    $records = New-Object System.Collections.ArrayList
    foreach ($line in @($read.lines)) {
        $record = $null
        try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { $record = $null }
        if ($null -eq $record) { $out.broken_lines++; continue }
        [void]$records.Add($record)
    }
    $out.records_total = $records.Count

    # Pass 1: spans that name the selected task/agent, plus the sessions they
    # belong to. Pass 2: add the start/end/error events of those sessions so the
    # chronology of a single run stays readable.
    $matchedIndex = New-Object 'System.Collections.Generic.HashSet[int]'
    $matchedSessions = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $recordTask = [string]$record.task_id
        $recordAgent = [string]$record.agent
        $isMatch = $false
        if ((-not [string]::IsNullOrWhiteSpace($TaskIdValue)) -and ($recordTask -eq $TaskIdValue)) { $isMatch = $true }
        if ((-not $isMatch) -and (-not [string]::IsNullOrWhiteSpace($AgentValue)) -and ($recordAgent -eq $AgentValue)) { $isMatch = $true }
        if ($isMatch) {
            [void]$matchedIndex.Add($index)
            $sessionId = [string]$record.session_id
            if (-not [string]::IsNullOrWhiteSpace($sessionId)) { [void]$matchedSessions.Add($sessionId) }
        }
    }

    $spans = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $include = $matchedIndex.Contains($index)
        if (-not $include) {
            $sessionId = [string]$record.session_id
            if ((-not [string]::IsNullOrWhiteSpace($sessionId)) -and $matchedSessions.Contains($sessionId)) { $include = $true }
        }
        if (-not $include) { continue }
        [void]$spans.Add([ordered]@{
            ts          = [string]$record.ts
            type        = [string]$record.type
            tool        = [string]$record.tool
            status      = [string]$record.status
            error       = [string]$record.error
            message     = [string]$record.message
            agent       = [string]$record.agent
            task_id     = [string]$record.task_id
            session_id  = [string]$record.session_id
            duration_ms = ConvertTo-ExplainInt -Value $record.duration_ms -Default (ConvertTo-ExplainInt -Value $record.ms -Default 0)
        })
    }

    $spans = @($spans | Sort-Object -Property @{ Expression = {
        $instant = ConvertTo-ExplainUtc -Text $_.ts
        if ($null -eq $instant) { [datetime]::MaxValue } else { $instant }
    } })
    if ($spans.Count -gt $MaxSpans) {
        $skipped = $spans.Count - $MaxSpans
        $spans = @($spans | Select-Object -Last $MaxSpans)
        $out.read_error = (@($out.read_error, ('spans capped to ' + $MaxSpans + ' (dropped ' + $skipped + ' older)') | Where-Object { $_ }) -join '; ')
    }
    $out.spans = $spans
    return [pscustomobject]$out
}

# ===========================================================================
# Reviewer verdicts (delegated to review-disagreement.ps1)
# ===========================================================================

function Get-ExplainVerdicts {
    param([string]$RootValue, [string]$BufferPathValue, [string]$TaskIdValue, [string]$AgentValue)
    if (-not $script:ExplainVerdictsAvailable) { return @() }
    $items = @()
    try {
        if (-not [string]::IsNullOrWhiteSpace($TaskIdValue)) {
            $items = @(Get-ReviewVerdicts -Root $RootValue -BufferPath $BufferPathValue -TaskId $TaskIdValue)
        } else {
            $items = @(Get-ReviewVerdicts -Root $RootValue -BufferPath $BufferPathValue)
        }
    } catch {
        return @()
    }
    if (-not [string]::IsNullOrWhiteSpace($AgentValue)) {
        $items = @($items | Where-Object { [string]$_.agent -eq $AgentValue })
    }
    return @($items)
}

# ===========================================================================
# Main
# ===========================================================================

$exitCode = 0
try {
    $explainRootPath = Get-ExplainRoot -RootValue $Root
    $explainTracesPath = Get-ExplainTracesDir -TracesDirValue $TracesDir
    $explainBuffer = Get-ExplainBufferPath -BufferPathValue $BufferPath -RootValue $explainRootPath

    $bufferText = Read-ExplainTextFile -Path $explainBuffer
    $selfReports = @(Get-ExplainSelfReports -Text $bufferText)

    $effectiveTaskId = $TaskId.Trim()
    $effectiveAgent = $Agent.Trim()
    $selectorSource = 'explicit'
    if ([string]::IsNullOrWhiteSpace($effectiveTaskId) -and [string]::IsNullOrWhiteSpace($effectiveAgent)) {
        $withKeys = @($selfReports | Where-Object { @($_.task_keys).Count -gt 0 })
        if ($withKeys.Count -gt 0) {
            $latest = $withKeys[$withKeys.Count - 1]
            $effectiveTaskId = [string]@($latest.task_keys)[0]
            $effectiveAgent = [string]$latest.agent
            $selectorSource = 'latest-self-report'
        } else {
            $selectorSource = 'none'
        }
    }

    $matchTask = (-not [string]::IsNullOrWhiteSpace($effectiveTaskId))
    $matchAgent = (-not [string]::IsNullOrWhiteSpace($effectiveAgent))

    $matchedReports = @($selfReports | Where-Object {
        $keep = $true
        if ($matchTask) { $keep = $keep -and (@($_.task_keys) -contains $effectiveTaskId) }
        if ($matchAgent) { $keep = $keep -and ([string]$_.agent -eq $effectiveAgent) }
        $keep
    })

    $evidence = Get-ExplainEvidence -RootValue $explainRootPath -TaskIdValue $effectiveTaskId -AgentValue $effectiveAgent -MaxFiles $MaxEvidenceFiles
    $traceData = Get-ExplainTraceData -TracesDirValue $explainTracesPath -TaskIdValue $effectiveTaskId -AgentValue $effectiveAgent `
        -MaxBytes $MaxTraceBytes -MaxSpans $MaxSpans
    $verdicts = @(Get-ExplainVerdicts -RootValue $explainRootPath -BufferPathValue $explainBuffer `
        -TaskIdValue $effectiveTaskId -AgentValue $effectiveAgent)

    $disagreements = @()
    if ($script:ExplainVerdictsAvailable -and ($matchTask -or $matchAgent)) {
        try {
            $allDisagreements = @(Find-ReviewDisagreement -Root $explainRootPath -BufferPath $explainBuffer -TaskId $effectiveTaskId)
            if ($matchTask) {
                $disagreements = @($allDisagreements)
            } else {
                $disagreements = @($allDisagreements | Where-Object {
                    ([string]$_.reviewers -match [regex]::Escape($effectiveAgent)) -or
                    ([string]$_.accept_agents -match [regex]::Escape($effectiveAgent)) -or
                    ([string]$_.reject_agents -match [regex]::Escape($effectiveAgent))
                })
            }
        } catch {
            $disagreements = @()
        }
    }

    # --- timeline ---------------------------------------------------------
    $timelineSource = New-Object System.Collections.ArrayList
    $entryIndex = 0

    foreach ($report in $matchedReports) {
        $text = ('{0} -> {1} STATUS {2} (TYPE {3}, line {4})' -f $report.agent, $report.to,
            $(if ([string]::IsNullOrWhiteSpace([string]$report.status)) { '<none>' } else { $report.status }),
            $(if ([string]::IsNullOrWhiteSpace([string]$report.type)) { '<none>' } else { $report.type }),
            $report.line)
        [void]$timelineSource.Add([ordered]@{
            sort_utc = $report.time
            time     = [string]$report.time_display
            kind     = 'self-report'
            text     = $text
            index    = $entryIndex
        })
        $entryIndex++
    }

    foreach ($attempt in @($evidence.attempts)) {
        $text = ('evidence {0} agent={1} status={2} exit_code={3} duration={4}' -f
            $(if ([string]::IsNullOrWhiteSpace([string]$attempt.attempt_id)) { '<no-id>' } else { $attempt.attempt_id }),
            $(if ([string]::IsNullOrWhiteSpace([string]$attempt.agent)) { '<none>' } else { $attempt.agent }),
            $(if ([string]::IsNullOrWhiteSpace([string]$attempt.status)) { '<none>' } else { $attempt.status }),
            $attempt.exit_code, (Format-ExplainDuration -Ms ([int]$attempt.duration_ms)))
        if (-not [string]::IsNullOrWhiteSpace([string]$attempt.reason)) { $text += (' reason="' + [string]$attempt.reason + '"') }
        [void]$timelineSource.Add([ordered]@{
            sort_utc = (ConvertTo-ExplainUtc -Text $attempt.started_at)
            time     = (Format-ExplainTime -Value (ConvertTo-ExplainUtc -Text $attempt.started_at) -Fallback $attempt.started_at)
            kind     = 'evidence'
            text     = $text
            index    = $entryIndex
        })
        $entryIndex++
    }

    foreach ($span in @($traceData.spans)) {
        $kind = 'trace-' + $(if ([string]::IsNullOrWhiteSpace([string]$span.type)) { 'event' } else { [string]$span.type })
        $text = [string]$span.text
        if ([string]$span.type -eq 'tool') {
            $text = ('trace tool={0} status={1} duration={2}' -f
                $(if ([string]::IsNullOrWhiteSpace([string]$span.tool)) { '<none>' } else { $span.tool }),
                $(if ([string]::IsNullOrWhiteSpace([string]$span.status)) { '<none>' } else { $span.status }),
                (Format-ExplainDuration -Ms ([int]$span.duration_ms)))
            if (-not [string]::IsNullOrWhiteSpace([string]$span.error)) { $text += (' error="' + [string]$span.error + '"') }
        } elseif ([string]$span.type -eq 'error') {
            $text = 'trace error: ' + $(if ([string]::IsNullOrWhiteSpace([string]$span.message)) { '<no message>' } else { [string]$span.message })
        } else {
            $text = ('trace {0}' -f $(if ([string]::IsNullOrWhiteSpace([string]$span.type)) { '<event>' } else { [string]$span.type }))
        }
        [void]$timelineSource.Add([ordered]@{
            sort_utc = (ConvertTo-ExplainUtc -Text $span.ts)
            time     = (Format-ExplainTime -Value (ConvertTo-ExplainUtc -Text $span.ts) -Fallback $span.ts)
            kind     = $kind
            text     = $text
            index    = $entryIndex
        })
        $entryIndex++
    }

    foreach ($verdict in $verdicts) {
        $text = ('{0} -> {1} [{2}] line {3}' -f $verdict.agent,
            $(if ([string]::IsNullOrWhiteSpace([string]$verdict.verdict)) { '<unknown>' } else { $verdict.verdict }),
            [string]$verdict.raw_verdict, $verdict.line)
        [void]$timelineSource.Add([ordered]@{
            sort_utc = (ConvertTo-ExplainUtcKind -Value $verdict.time)
            time     = (Format-ExplainTime -Value (ConvertTo-ExplainUtcKind -Value $verdict.time) -Fallback $verdict.time_display)
            kind     = 'verdict'
            text     = $text
            index    = $entryIndex
        })
        $entryIndex++
    }

    $timeline = @($timelineSource | Sort-Object -Property @{ Expression = {
        if ($null -eq $_.sort_utc) { [datetime]::MaxValue } else { $_.sort_utc }
    } }, @{ Expression = { [int]$_.index } })
    $timelineDropped = 0
    if ($timeline.Count -gt $MaxTimeline) {
        $timelineDropped = $timeline.Count - $MaxTimeline
        $timeline = @($timeline | Select-Object -Last $MaxTimeline)
    }

    # --- failures ---------------------------------------------------------
    $failures = New-Object System.Collections.ArrayList
    $evidenceFailed = 0
    foreach ($attempt in @($evidence.attempts)) {
        $statusText = ([string]$attempt.status).ToLowerInvariant()
        $isFailure = (([int]$attempt.exit_code -ne 0)) -or ($script:ExplainFailedStatuses -contains $statusText)
        if (-not $isFailure) { continue }
        $evidenceFailed++
        $detail = ('attempt {0} exit_code={1} reason="{2}"' -f
            $(if ([string]::IsNullOrWhiteSpace([string]$attempt.attempt_id)) { '<no-id>' } else { $attempt.attempt_id }),
            $attempt.exit_code,
            $(if ([string]::IsNullOrWhiteSpace([string]$attempt.reason)) { '<none>' } else { [string]$attempt.reason }))
        [void]$failures.Add([ordered]@{
            level  = 'FAILED'
            source = 'evidence'
            detail = $detail
            time   = (Format-ExplainTime -Value (ConvertTo-ExplainUtc -Text $attempt.started_at) -Fallback $attempt.started_at)
        })
    }

    $traceFailures = 0
    $traceErrors = 0
    foreach ($span in @($traceData.spans)) {
        if ([string]$span.type -eq 'error') {
            $traceErrors++
            [void]$failures.Add([ordered]@{
                level  = 'ERROR'
                source = 'trace'
                detail = ('error event: ' + $(if ([string]::IsNullOrWhiteSpace([string]$span.message)) { '<no message>' } else { [string]$span.message }))
                time   = (Format-ExplainTime -Value (ConvertTo-ExplainUtc -Text $span.ts) -Fallback $span.ts)
            })
            continue
        }
        if ([string]$span.type -ne 'tool') { continue }
        $spanStatus = [string]$span.status
        if ([string]::IsNullOrWhiteSpace($spanStatus) -or ($spanStatus -eq 'ok')) { continue }
        $traceFailures++
        $detail = ('tool {0} status={1}' -f
            $(if ([string]::IsNullOrWhiteSpace([string]$span.tool)) { '<none>' } else { [string]$span.tool }), $spanStatus)
        if (-not [string]::IsNullOrWhiteSpace([string]$span.error)) { $detail += (' error="' + [string]$span.error + '"') }
        [void]$failures.Add([ordered]@{
            level  = 'WARN'
            source = 'trace'
            detail = $detail
            time   = (Format-ExplainTime -Value (ConvertTo-ExplainUtc -Text $span.ts) -Fallback $span.ts)
        })
    }

    $evidenceAttempts = @($evidence.attempts).Count
    $traceSpansCount = @($traceData.spans).Count
    if (($evidenceFailed -gt 0) -or ($traceErrors -gt 0)) {
        $outcome = 'FAILED'
    } elseif (($evidenceAttempts -gt 0) -or ($traceSpansCount -gt 0)) {
        $outcome = 'PASSED'
    } else {
        $outcome = 'NO_DATA'
    }

    $notes = New-Object System.Collections.ArrayList
    if ($selectorSource -eq 'none') { [void]$notes.Add('no selector and no self-report with a task key in the buffer') }
    if ($selectorSource -eq 'latest-self-report') { [void]$notes.Add('selector derived from the last self-report in the buffer') }
    if (-not (Test-Path -LiteralPath $explainBuffer -PathType Leaf)) { [void]$notes.Add('buffer not found: ' + $explainBuffer) }
    if (-not $script:ExplainVerdictsAvailable) { [void]$notes.Add('review-disagreement.ps1 not available - verdicts skipped') }
    if (-not $traceData.exists) { [void]$notes.Add('traces not found: ' + $traceData.file) }
    if ($timelineDropped -gt 0) { [void]$notes.Add('timeline capped: dropped ' + $timelineDropped + ' older entr(ies)') }
    if ([int]$evidenceFailed -gt 0) { [void]$notes.Add('machine evidence proves at least one failed attempt - a "resolved" self-report would be a false done') }

    $emptyTaskKeys = @($effectiveTaskId, $effectiveAgent) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $selectorLine = if ($emptyTaskKeys.Count -eq 0) { '(none)' } else {
        (@(('task=' + $(if ($matchTask) { $effectiveTaskId } else { '-' })), ('agent=' + $(if ($matchAgent) { $effectiveAgent } else { '-' }))) -join ' ')
    }

    if ($Json) {
        $payload = [ordered]@{
            tool          = 'explain'
            generated_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            root          = $explainRootPath
            selectors     = [ordered]@{ task_id = $effectiveTaskId; agent = $effectiveAgent; source = $selectorSource }
            outcome       = $outcome
            counts        = [ordered]@{
                self_reports      = $matchedReports.Count
                self_reports_all  = $selfReports.Count
                evidence_attempts = $evidenceAttempts
                evidence_failed   = $evidenceFailed
                trace_spans       = $traceSpansCount
                trace_failures    = $traceFailures
                trace_errors      = $traceErrors
                verdicts          = $verdicts.Count
                timeline          = $timeline.Count
            }
            timeline      = @($timeline | ForEach-Object { [ordered]@{ time = [string]$_.time; kind = [string]$_.kind; text = [string]$_.text } })
            failures      = @($failures | ForEach-Object { [ordered]@{ level = [string]$_.level; source = [string]$_.source; detail = [string]$_.detail; time = [string]$_.time } })
            self_reports  = @($matchedReports | ForEach-Object { [ordered]@{
                agent = [string]$_.agent; to = [string]$_.to; stamp = [string]$_.stamp; type = [string]$_.type
                status = [string]$_.status; line = [int]$_.line; task_keys = @($_.task_keys)
                snippet = [string]$_.snippet; time = [string]$_.time_display
            } })
            evidence      = [ordered]@{
                dir           = $evidence.dir
                file          = $evidence.file
                exists        = [bool]$evidence.exists
                scanned_files = [int]$evidence.scanned_files
                read_errors   = @($evidence.read_errors)
                attempts      = @($evidence.attempts | ForEach-Object { [ordered]@{
                    attempt_id = [string]$_.attempt_id; agent = [string]$_.agent; command = [string]$_.command
                    exit_code = [int]$_.exit_code; status = [string]$_.status; reason = [string]$_.reason
                    started_at = [string]$_.started_at; finished_at = [string]$_.finished_at
                    duration_ms = [int]$_.duration_ms; stdout_length = [int]$_.stdout_length
                    stderr_length = [int]$_.stderr_length; source = [string]$_.source
                } })
            }
            traces        = [ordered]@{
                dir           = $traceData.dir
                file          = $traceData.file
                exists        = [bool]$traceData.exists
                truncated     = [bool]$traceData.truncated
                records_total = [int]$traceData.records_total
                broken_lines  = [int]$traceData.broken_lines
                read_error    = [string]$traceData.read_error
                spans         = @($traceData.spans | ForEach-Object { [ordered]@{
                    ts = [string]$_.ts; type = [string]$_.type; tool = [string]$_.tool; status = [string]$_.status
                    error = [string]$_.error; message = [string]$_.message; agent = [string]$_.agent
                    task_id = [string]$_.task_id; session_id = [string]$_.session_id; duration_ms = [int]$_.duration_ms
                } })
            }
            verdicts      = @($verdicts | ForEach-Object { [ordered]@{
                agent = [string]$_.agent; task_key = [string]$_.task_key; verdict = [string]$_.verdict
                raw = [string]$_.raw_verdict; source = [string]$_.source; time = [string]$_.time_display; line = [int]$_.line
            } })
            disagreements = @($disagreements | ForEach-Object { [ordered]@{
                task_key = [string]$_.task_key; accept_agents = [string]$_.accept_agents; reject_agents = [string]$_.reject_agents
                reviewers = [string]$_.reviewers; last_time = [string]$_.last_time; last_line = [int]$_.last_line
            } })
            artifacts     = [ordered]@{ buffer = $explainBuffer; evidence = $evidence.file; traces = $traceData.file }
            notes         = @($notes)
        }
        Write-Output (ConvertTo-ExplainJson -InputObject $payload -Depth 8)
    } else {
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('=== agent-hq explain ===')
        [void]$lines.Add('selectors : ' + $selectorLine + '   (source: ' + $selectorSource + ')')
        [void]$lines.Add('outcome   : ' + $outcome)
        [void]$lines.Add('root      : ' + $explainRootPath)
        [void]$lines.Add('buffer    : ' + $explainBuffer)
        [void]$lines.Add('evidence  : ' + $(if ([string]::IsNullOrWhiteSpace([string]$evidence.file)) { $evidence.dir } else { [string]$evidence.file }) + $(if ($evidence.exists) { '' } else { ' (missing)' }))
        [void]$lines.Add('traces    : ' + $traceData.file + $(if ($traceData.exists) { '' } else { ' (missing)' }))
        [void]$lines.Add('')
        [void]$lines.Add(('--- chronology (' + $timeline.Count + ' entr' + $(if ($timeline.Count -eq 1) { 'y' } else { 'ies' }) + ') ---'))
        if ($timeline.Count -eq 0) {
            [void]$lines.Add('  no dated activity for this selector')
        } else {
            foreach ($entry in $timeline) {
                [void]$lines.Add(('{0}  {1,-11} {2}' -f $entry.time, $entry.kind, $entry.text))
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add(('--- what went wrong (' + $failures.Count + ') ---'))
        if ($failures.Count -eq 0) {
            [void]$lines.Add('  no machine-verified failures')
        } else {
            foreach ($failure in $failures) {
                [void]$lines.Add(('  [{0}] {1}: {2}' -f $failure.level, $failure.source, $failure.detail))
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add(('--- reviewer verdicts (' + $verdicts.Count + ') ---'))
        if ($verdicts.Count -eq 0) {
            [void]$lines.Add('  none')
        } else {
            foreach ($verdict in $verdicts) {
                [void]$lines.Add(('  {0,-26} {1,-9} [{2}] line {3}' -f $verdict.agent, $verdict.verdict, $verdict.raw_verdict, $verdict.line))
            }
        }
        if ($disagreements.Count -gt 0) {
            [void]$lines.Add(('--- disagreements (' + $disagreements.Count + ') ---'))
            foreach ($disagreement in $disagreements) {
                [void]$lines.Add(('  task {0}: accept=[{1}] reject=[{2}]' -f $disagreement.task_key, $disagreement.accept_agents, $disagreement.reject_agents))
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add('--- artifacts ---')
        [void]$lines.Add('  buffer   : ' + $explainBuffer)
        [void]$lines.Add('  evidence : ' + $(if ([string]::IsNullOrWhiteSpace([string]$evidence.file)) { $evidence.dir } else { [string]$evidence.file }))
        [void]$lines.Add('  traces   : ' + $traceData.file)
        if ($notes.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('--- notes ---')
            foreach ($note in $notes) { [void]$lines.Add('  ' + $note) }
        }
        Write-Output ($lines -join "`r`n")
    }
} catch {
    Write-Output ('explain: internal error: ' + $_.Exception.Message)
    $exitCode = 1
}

exit $exitCode
