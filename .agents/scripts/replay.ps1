# replay.ps1 - replay a past task from its own traces (P3).
#
# Read-only inspection plus an OPTIONAL re-run through the inbox engine. Three
# artifact families are combined:
#   * machine evidence   .memory\evidence\<task_id>.json   (agent / command / exit_code / reason)
#   * self-reports       CONTEXT-BUFFER.md                 (via explain.ps1 -Json)
#   * original task text .memory\archive | .memory\dead-letter | .memory\inbox   (bus message payload)
#
# Usage:
#   .\replay.ps1 -TaskId P3-2 -DryRun      # default: plan only, nothing is executed
#   .\replay.ps1 -TaskId P3-2 -Run         # enqueue + process through inbox-engine.ps1
#   .\replay.ps1                           # latest FAILED task found in evidence
#   .\replay.ps1 -TaskId P3-2 -Agent qa-engineer -Json
#
# Safety: evidence is DATA. The command string stored in an evidence record is
# never executed as a shell; the only execution path is the shared inbox engine,
# and the replayed prompt is the payload of the archived bus message.
#
# Idempotent: every replay uses a fresh message id <task>-r<stamp>-<hex>, so a
# repeated replay appends a NEW evidence file and never rewrites the original.
#
# Root resolution: -Root > $env:AGENT_HQ_ROOT > repo derived from this script > cwd.
# In -Run mode the engine inherits the resolved root through $env:AGENT_HQ_ROOT
# (process-local, restored afterwards) so evidence/claim/log paths stay in one root.
#
# Exit codes:
#   0  plan produced (-DryRun) or replay completed (-Run)
#   1  cannot replay: no task selected / no payload found / no target agent
#   2  internal error
#
# Pure PowerShell 5.1. CRLF. No secrets are read, printed or written.

[CmdletBinding()]
param(
    [string]$TaskId = '',
    [string]$Agent = '',
    [switch]$DryRun,
    [switch]$Run,
    [switch]$Json,
    [string]$Root = '',
    [string]$BufferPath = '',
    [int]$MaxEvidenceFiles = 500,
    [int]$MaxMessageFiles = 1000,
    [int]$MaxPayloadChars = 4000
)

$script:ReplayScriptRoot = $PSScriptRoot
$script:ReplayUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:ReplayMaxFileBytes = 8 * 1024 * 1024
$script:ReplayTaskIdGuard = '^[A-Za-z0-9._-]{1,64}$'
$script:ReplayFailedStatuses = @('error', 'failed', 'failure', 'timeout', 'blocked', 'dead')

# ===========================================================================
# Path / value helpers
# ===========================================================================

function Get-ReplayRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:ReplayScriptRoot)) {
        return (Split-Path (Split-Path $script:ReplayScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-ReplayEvidenceDir {
    param([string]$RootValue)
    return (Join-Path (Join-Path $RootValue '.memory') 'evidence')
}

function Read-ReplayTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt $script:ReplayMaxFileBytes) { return '' }
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        return ''
    }
}

function Get-ReplayFileHash {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try {
                return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
            } finally {
                $stream.Dispose()
            }
        } finally {
            $sha.Dispose()
        }
    } catch {
        return ''
    }
}

# ASCII-only JSON: a captured stdout is codepage-dependent, escaping keeps it stable.
function ConvertTo-ReplayJson {
    param($InputObject, [int]$Depth = 10)
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

function ConvertTo-ReplayUtc {
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

function ConvertTo-ReplayInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

# A bus payload is usually a string, but the queue also stores structured bodies.
function ConvertTo-ReplayPayloadText {
    param($Payload)
    if ($null -eq $Payload) { return '' }
    if ($Payload -is [string]) { return [string]$Payload }
    try {
        $text = ConvertTo-Json -InputObject $Payload -Depth 6 -Compress
        if ($null -ne $text) { return [string]$text }
    } catch { }
    return [string]$Payload
}

function New-ReplayId {
    param([string]$TaskIdValue)
    $base = $TaskIdValue
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    $stamp = (Get-Date).ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 4)
    return ($base + '-r' + $stamp + '-' + $suffix)
}

# ===========================================================================
# Evidence
# ===========================================================================

function Read-ReplayEvidenceAttempts {
    param([string]$Path)
    $list = New-Object System.Collections.ArrayList
    $raw = Read-ReplayTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if ($null -eq $doc) { return @() }
    foreach ($attempt in @($doc.attempts)) {
        if ($null -eq $attempt) { continue }
        [void]$list.Add([ordered]@{
            attempt_id  = [string]$attempt.attempt_id
            agent       = [string]$attempt.agent
            command     = [string]$attempt.command
            exit_code   = ConvertTo-ReplayInt -Value $attempt.exit_code -Default -1
            status      = [string]$attempt.status
            reason      = [string]$attempt.reason
            started_at  = [string]$attempt.started_at
            finished_at = [string]$attempt.finished_at
            duration_ms = ConvertTo-ReplayInt -Value $attempt.duration_ms -Default 0
            source      = $Path
        })
    }
    return @($list)
}

function Sort-ReplayAttempts {
    param($Attempts)
    return @(@($Attempts) | Sort-Object -Property @{ Expression = {
        $instant = ConvertTo-ReplayUtc -Text ([string]$_.started_at)
        if ($null -eq $instant) { [datetime]::MaxValue } else { $instant }
    } })
}

function Test-ReplayAttemptFailed {
    param($Attempt)
    if ($null -eq $Attempt) { return $false }
    if ((ConvertTo-ReplayInt -Value $Attempt.exit_code -Default -1) -ne 0) { return $true }
    return ($script:ReplayFailedStatuses -contains ([string]$Attempt.status).ToLowerInvariant())
}

# Latest task that has at least one failed attempt (default selector).
function Find-ReplayLatestFailedTask {
    param([string]$RootValue, [int]$MaxFiles)
    $dir = Get-ReplayEvidenceDir -RootValue $RootValue
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $MaxFiles) { $files = @($files | Select-Object -Last $MaxFiles) }

    $bestTask = ''
    $bestInstant = $null
    foreach ($file in $files) {
        foreach ($attempt in @(Read-ReplayEvidenceAttempts -Path $file.FullName)) {
            if (-not (Test-ReplayAttemptFailed -Attempt $attempt)) { continue }
            $instant = ConvertTo-ReplayUtc -Text ([string]$attempt.started_at)
            if ($null -eq $instant) { $instant = $file.LastWriteTimeUtc }
            if (($null -eq $bestInstant) -or ($instant -gt $bestInstant)) {
                $bestInstant = $instant
                $bestTask = $file.BaseName
            }
        }
    }
    return $bestTask
}

# ===========================================================================
# Original payload (archived bus message)
# ===========================================================================

function Get-ReplayMessageCandidates {
    param([string]$Dir, [string]$TaskIdValue, [bool]$Nested)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add($Dir)
    if ($Nested) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            [void]$roots.Add($sub.FullName)
        }
    }
    foreach ($root in $roots) {
        $exact = Join-Path $root ($TaskIdValue + '.json')
        if (Test-Path -LiteralPath $exact -PathType Leaf) { [void]$out.Add($exact) }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter ('*-' + $TaskIdValue + '.json') -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            [void]$out.Add($file.FullName)
        }
    }
    return @($out | Select-Object -Unique)
}

function Read-ReplayBusMessage {
    param([string]$Path, [string]$TaskIdValue)
    $raw = Read-ReplayTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $doc) { return $null }
    if (-not ($doc.PSObject.Properties.Name -contains 'payload')) { return $null }
    if ($null -eq $doc.payload) { return $null }

    $fileId = ''
    if ($doc.id) { $fileId = [string]$doc.id }
    $baseId = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $matched = ($baseId -eq $TaskIdValue) -or ($baseId.EndsWith('-' + $TaskIdValue)) -or ($fileId -eq $TaskIdValue)
    if (-not $matched) { return $null }

    $text = ConvertTo-ReplayPayloadText -Payload $doc.payload
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $kind = 'text'
    if (-not ($doc.payload -is [string])) { $kind = 'json' }

    return [pscustomobject]@{
        path         = $Path
        id           = $fileId
        from         = [string]$doc.from
        to           = [string]$doc.to
        priority     = [string]$doc.priority
        type         = [string]$doc.type
        payload_text = $text
        payload_kind = $kind
    }
}

# Search order: archive, dead-letter, inbox, then an explicit TASK:/PAYLOAD: marker
# in the context buffer. The first hit wins; nothing is executed.
function Find-ReplayPayload {
    param([string]$RootValue, [string]$TaskIdValue, [string]$BufferText, [int]$MaxFiles)

    $result = [ordered]@{
        found = $false; source = ''; path = ''; id = ''; from = ''; to = ''
        priority = ''; type = ''; payload_text = ''; payload_kind = ''
    }

    $memory = Join-Path $RootValue '.memory'
    $sources = @(
        [pscustomobject]@{ label = 'archive';     dir = (Join-Path $memory 'archive');     nested = $false },
        [pscustomobject]@{ label = 'dead-letter'; dir = (Join-Path $memory 'dead-letter'); nested = $false },
        [pscustomobject]@{ label = 'inbox';       dir = (Join-Path $memory 'inbox');       nested = $true }
    )

    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source.dir -PathType Container)) { continue }

        foreach ($candidate in @(Get-ReplayMessageCandidates -Dir $source.dir -TaskIdValue $TaskIdValue -Nested $source.nested)) {
            $message = Read-ReplayBusMessage -Path $candidate -TaskIdValue $TaskIdValue
            if ($null -eq $message) { continue }
            $result.found = $true
            $result.source = $source.label
            $result.path = $message.path
            $result.id = $message.id
            $result.from = $message.from
            $result.to = $message.to
            $result.priority = $message.priority
            $result.type = $message.type
            $result.payload_text = $message.payload_text
            $result.payload_kind = $message.payload_kind
            return [pscustomobject]$result
        }

        # Bounded fallback: match by the message id inside the JSON body.
        $scanned = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $source.dir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $scanned++
            if ($scanned -gt $MaxFiles) { break }
            $message = Read-ReplayBusMessage -Path $file.FullName -TaskIdValue $TaskIdValue
            if ($null -eq $message) { continue }
            $result.found = $true
            $result.source = $source.label
            $result.path = $message.path
            $result.id = $message.id
            $result.from = $message.from
            $result.to = $message.to
            $result.priority = $message.priority
            $result.type = $message.type
            $result.payload_text = $message.payload_text
            $result.payload_kind = $message.payload_kind
            return [pscustomobject]$result
        }
    }

    if ((-not [string]::IsNullOrWhiteSpace($BufferText)) -and $BufferText.Contains($TaskIdValue)) {
        $match = [regex]::Match($BufferText, '(?im)^[ \t]*(?:TASK|PAYLOAD)[ \t]*:[ \t]*(?<p>.+)$')
        if ($match.Success) {
            $text = $match.Groups['p'].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $result.found = $true
                $result.source = 'buffer-marker'
                $result.payload_text = $text
                $result.payload_kind = 'text'
            }
        }
    }

    return [pscustomobject]$result
}

# ===========================================================================
# Self-reports + failure narrative: delegated to explain.ps1 (P3-3)
# ===========================================================================

function Get-ReplayExplainSummary {
    param([string]$RootValue, [string]$TaskIdValue, [string]$BufferPathValue)

    $out = [ordered]@{ available = $false; outcome = ''; self_reports = @(); failures = @(); notes = @() }
    $explainPath = Join-Path $script:ReplayScriptRoot 'explain.ps1'
    if (-not (Test-Path -LiteralPath $explainPath -PathType Leaf)) {
        $out.notes = @('explain.ps1 missing - self-reports skipped')
        return [pscustomobject]$out
    }

    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $explainPath, '-TaskId', $TaskIdValue, '-Json', '-Root', $RootValue)
    if (-not [string]::IsNullOrWhiteSpace($BufferPathValue)) { $arguments += @('-BufferPath', $BufferPathValue) }

    $text = ''
    try {
        $text = (& $psExe @arguments 2>$null | Out-String)
    } catch {
        $out.notes = @('explain.ps1 invocation failed')
        return [pscustomobject]$out
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        $out.notes = @('explain.ps1 returned no data')
        return [pscustomobject]$out
    }

    $doc = $null
    try { $doc = $text | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
    if ($null -eq $doc) {
        $out.notes = @('explain.ps1 output is not valid JSON')
        return [pscustomobject]$out
    }

    $out.available = $true
    $out.outcome = [string]$doc.outcome

    $reports = New-Object System.Collections.ArrayList
    foreach ($report in @($doc.self_reports)) {
        if ($null -eq $report) { continue }
        [void]$reports.Add([ordered]@{
            agent   = [string]$report.agent
            to      = [string]$report.to
            stamp   = [string]$report.stamp
            type    = [string]$report.type
            status  = [string]$report.status
            snippet = [string]$report.snippet
            time    = [string]$report.time
        })
    }
    $out.self_reports = @($reports)

    $failures = New-Object System.Collections.ArrayList
    foreach ($failure in @($doc.failures)) {
        if ($null -eq $failure) { continue }
        [void]$failures.Add([ordered]@{
            level  = [string]$failure.level
            source = [string]$failure.source
            detail = [string]$failure.detail
            time   = [string]$failure.time
        })
    }
    $out.failures = @($failures)

    return [pscustomobject]$out
}

# ===========================================================================
# Plan / run
# ===========================================================================

function Invoke-ReplayPlan {
    param($Settings)

    $rootPath      = [string]$Settings.Root
    $evidenceDir   = [string]$Settings.EvidenceDir
    $bufferText    = [string]$Settings.BufferText
    $bufferFull    = [string]$Settings.BufferFull
    $selectorSrc   = [string]$Settings.SelectorSource
    $runMode       = [bool]$Settings.RunMode
    $maxPayload    = [int]$Settings.MaxPayloadChars
    $maxMessages   = [int]$Settings.MaxMessageFiles
    $agentOverride = [string]$Settings.Agent

    $report = [ordered]@{
        tool         = 'replay'
        generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        ok           = $false
        mode         = $(if ($runMode) { 'run' } else { 'dry-run' })
        root         = $rootPath
        buffer       = $bufferFull
        selector     = [ordered]@{ task_id = ''; source = $selectorSrc }
        task_id      = ''
        replay_id    = ''
        agent        = [ordered]@{ name = ''; source = '' }
        payload      = [ordered]@{ found = $false; source = ''; path = ''; kind = ''; from = ''; to = ''; priority = ''; length = 0; truncated = $false; text = '' }
        evidence     = [ordered]@{ dir = $evidenceDir; file = ''; exists = $false; attempts = @() }
        self_reports = @()
        last_run     = [ordered]@{ explain_available = $false; outcome = ''; failures = @(); notes = @() }
        inbox        = [ordered]@{ file = ''; written = $false }
        engine       = [ordered]@{ executed = $false; status = ''; reason = '' }
        integrity    = [ordered]@{ original_evidence_sha256 = ''; original_untouched = $true }
        new_evidence = [ordered]@{ file = ''; exists = $false; attempts = @() }
        notes        = @()
        error        = ''
    }

    $notes = New-Object System.Collections.ArrayList
    $failReason = ''

    $effectiveTaskId = [string]$Settings.TaskId
    $report.selector.task_id = $effectiveTaskId
    $report.task_id = $effectiveTaskId

    if ([string]::IsNullOrWhiteSpace($effectiveTaskId)) {
        $failReason = ('cannot determine a task to replay: no -TaskId given and no failed attempt found in ' + $evidenceDir)
    } elseif ($effectiveTaskId -notmatch $script:ReplayTaskIdGuard) {
        $failReason = ("task id '" + $effectiveTaskId + "' rejected by the file-name guard")
    } else {
        $evidenceFile = Join-Path $evidenceDir ($effectiveTaskId + '.json')
        $report.evidence.file = $evidenceFile
        $report.evidence.exists = Test-Path -LiteralPath $evidenceFile -PathType Leaf
        $attempts = @(Sort-ReplayAttempts -Attempts (Read-ReplayEvidenceAttempts -Path $evidenceFile))
        $report.evidence.attempts = @($attempts)
        if (-not $report.evidence.exists) { [void]$notes.Add('no evidence file for this task: ' + $evidenceFile) }
        if ($attempts.Count -eq 0) { [void]$notes.Add('evidence holds no attempts for this task') }

        $explain = Get-ReplayExplainSummary -RootValue $rootPath -TaskIdValue $effectiveTaskId -BufferPathValue $bufferFull
        $report.self_reports = @($explain.self_reports)
        $report.last_run.explain_available = [bool]$explain.available
        $report.last_run.outcome = [string]$explain.outcome
        $report.last_run.failures = @($explain.failures)
        $report.last_run.notes = @($explain.notes)

        $payload = Find-ReplayPayload -RootValue $rootPath -TaskIdValue $effectiveTaskId -BufferText $bufferText -MaxFiles $maxMessages
        if (-not $payload.found) {
            [void]$notes.Add('checked payload sources: archive, dead-letter, inbox, buffer marker')
            $failReason = ("no payload found for task '" + $effectiveTaskId + "' - nothing to replay")
        } else {
            $fullPayload = [string]$payload.payload_text
            $preview = $fullPayload
            $truncated = $false
            if ($preview.Length -gt $maxPayload) {
                $preview = $preview.Substring(0, $maxPayload) + '...[truncated]'
                $truncated = $true
            }
            $report.payload.found = $true
            $report.payload.source = [string]$payload.source
            $report.payload.path = [string]$payload.path
            $report.payload.kind = [string]$payload.payload_kind
            $report.payload.from = [string]$payload.from
            $report.payload.to = [string]$payload.to
            $report.payload.priority = [string]$payload.priority
            $report.payload.length = $fullPayload.Length
            $report.payload.truncated = $truncated
            $report.payload.text = $preview

            $agentName = $agentOverride.Trim()
            $agentSource = 'override'
            if ([string]::IsNullOrWhiteSpace($agentName)) {
                $agentSource = 'none'
                for ($index = $attempts.Count - 1; $index -ge 0; $index--) {
                    $candidateAgent = [string]$attempts[$index].agent
                    if (-not [string]::IsNullOrWhiteSpace($candidateAgent)) {
                        $agentName = $candidateAgent
                        $agentSource = 'evidence'
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($agentName) -and (-not [string]::IsNullOrWhiteSpace([string]$payload.to))) {
                    $agentName = [string]$payload.to
                    $agentSource = 'bus-message'
                }
            }
            $report.agent.name = $agentName
            $report.agent.source = $agentSource

            if ([string]::IsNullOrWhiteSpace($agentName)) {
                [void]$notes.Add('no agent in evidence and no recipient in the archived message; pass -Agent')
                $failReason = ("cannot determine target agent for task '" + $effectiveTaskId + "'")
            } elseif ($agentName -notmatch $script:ReplayTaskIdGuard) {
                $failReason = ("agent name '" + $agentName + "' rejected by the file-name guard")
            } else {
                $replayId = New-ReplayId -TaskIdValue $effectiveTaskId
                $report.replay_id = $replayId
                $inboxDir = Join-Path (Join-Path (Join-Path $rootPath '.memory') 'inbox') $agentName
                $inboxFile = Join-Path $inboxDir ($replayId + '.json')
                $report.inbox.file = $inboxFile

                $priority = 'normal'
                if (-not [string]::IsNullOrWhiteSpace([string]$payload.priority)) { $priority = [string]$payload.priority }

                if (-not $runMode) {
                    [void]$notes.Add('dry-run: nothing was executed; pass -Run to replay')
                    $report.ok = $true
                } else {
                    $enginePath = Join-Path $script:ReplayScriptRoot 'inbox-engine.ps1'
                    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
                        [void]$notes.Add('inbox-engine.ps1 missing at ' + $enginePath)
                        $failReason = 'inbox-engine.ps1 missing - cannot run'
                    } else {
                        $report.integrity.original_evidence_sha256 = Get-ReplayFileHash -Path $evidenceFile
                        $hashBefore = $report.integrity.original_evidence_sha256

                        if (-not (Test-Path -LiteralPath $inboxDir -PathType Container)) {
                            New-Item -ItemType Directory -Path $inboxDir -Force | Out-Null
                        }
                        $message = [ordered]@{
                            id       = $replayId
                            from     = 'replay'
                            to       = $agentName
                            type     = 'task'
                            priority = $priority
                            payload  = $fullPayload
                            created  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                            replay_of          = $effectiveTaskId
                            replay_source      = [string]$payload.source
                            replay_payload_kind = [string]$payload.payload_kind
                        }
                        [System.IO.File]::WriteAllText($inboxFile, ($message | ConvertTo-Json -Depth 6), $script:ReplayUtf8NoBom)
                        $report.inbox.written = (Test-Path -LiteralPath $inboxFile -PathType Leaf)

                        # The engine resolves its root from the environment: pin it to the
                        # root this plan was built against, then restore the previous value.
                        $previousRoot = $env:AGENT_HQ_ROOT
                        try {
                            $env:AGENT_HQ_ROOT = $rootPath
                            . $enginePath
                            $engineResult = & { Process-InboxFile -filePath $inboxFile -agentName $agentName } 6>$null
                        } finally {
                            if ($null -eq $previousRoot) {
                                Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
                            } else {
                                $env:AGENT_HQ_ROOT = $previousRoot
                            }
                        }

                        $report.engine.executed = $true
                        if ($null -ne $engineResult) {
                            $report.engine.status = [string]$engineResult.Status
                            $report.engine.reason = [string]$engineResult.Reason
                        }

                        $newEvidenceFile = Join-Path $evidenceDir ($replayId + '.json')
                        $report.new_evidence.file = $newEvidenceFile
                        $report.new_evidence.exists = Test-Path -LiteralPath $newEvidenceFile -PathType Leaf
                        $report.new_evidence.attempts = @(Sort-ReplayAttempts -Attempts (Read-ReplayEvidenceAttempts -Path $newEvidenceFile))

                        $hashAfter = Get-ReplayFileHash -Path $evidenceFile
                        if ([string]::IsNullOrWhiteSpace($hashBefore) -and [string]::IsNullOrWhiteSpace($hashAfter)) {
                            $report.integrity.original_untouched = $true
                        } else {
                            $report.integrity.original_untouched = ($hashBefore -eq $hashAfter)
                        }

                        if (-not $report.new_evidence.exists) {
                            [void]$notes.Add('no new evidence file after the run (engine did not record an attempt)')
                        }
                        $report.ok = $true
                    }
                }
            }
        }
    }

    $report.notes = @($notes)
    if (-not [string]::IsNullOrWhiteSpace($failReason)) {
        $report.ok = $false
        $report.error = $failReason
    }

    $exitCode = 0
    if (-not $report.ok) { $exitCode = 1 }
    return [pscustomobject]@{ ok = [bool]$report.ok; exit_code = $exitCode; report = $report }
}

# ===========================================================================
# Human output
# ===========================================================================

function Format-ReplayHuman {
    param($Report)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== agent-hq replay ===')
    [void]$lines.Add('mode      : ' + [string]$Report.mode)
    [void]$lines.Add('task id   : ' + [string]$Report.task_id + '   (source: ' + [string]$Report.selector.source + ')')
    [void]$lines.Add('replay id : ' + $(if ([string]::IsNullOrWhiteSpace([string]$Report.replay_id)) { '(not assigned)' } else { [string]$Report.replay_id }))
    [void]$lines.Add('agent     : ' + $(if ([string]::IsNullOrWhiteSpace([string]$Report.agent.name)) { '(unknown)' } else { [string]$Report.agent.name }) + '   (source: ' + [string]$Report.agent.source + ')')
    [void]$lines.Add('root      : ' + [string]$Report.root)
    [void]$lines.Add('buffer    : ' + [string]$Report.buffer)
    [void]$lines.Add('evidence  : ' + [string]$Report.evidence.file + $(if ([bool]$Report.evidence.exists) { '' } else { ' (missing)' }))
    [void]$lines.Add('')

    $attempts = @($Report.evidence.attempts)
    $failedCount = 0
    foreach ($attempt in $attempts) { if (Test-ReplayAttemptFailed -Attempt $attempt) { $failedCount++ } }
    [void]$lines.Add(('--- evidence attempts (' + $attempts.Count + ', failed ' + $failedCount + ') ---'))
    if ($attempts.Count -eq 0) {
        [void]$lines.Add('  none')
    } else {
        foreach ($attempt in $attempts) {
            [void]$lines.Add(('  {0} agent={1} exit_code={2} status={3}' -f
                $(if ([string]::IsNullOrWhiteSpace([string]$attempt.attempt_id)) { '<no-id>' } else { [string]$attempt.attempt_id }),
                $(if ([string]::IsNullOrWhiteSpace([string]$attempt.agent)) { '<none>' } else { [string]$attempt.agent }),
                $attempt.exit_code,
                $(if ([string]::IsNullOrWhiteSpace([string]$attempt.status)) { '<none>' } else { [string]$attempt.status })))
            if (-not [string]::IsNullOrWhiteSpace([string]$attempt.command)) {
                [void]$lines.Add(('    command: ' + [string]$attempt.command))
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$attempt.reason)) {
                [void]$lines.Add(('    reason : ' + [string]$attempt.reason))
            }
        }
    }
    [void]$lines.Add('')

    [void]$lines.Add('--- payload ---')
    if (-not [bool]$Report.payload.found) {
        [void]$lines.Add('  not found')
    } else {
        [void]$lines.Add(('  source  : ' + [string]$Report.payload.source + ' (' + [string]$Report.payload.path + ')'))
        [void]$lines.Add(('  from/to : ' + [string]$Report.payload.from + ' -> ' + [string]$Report.payload.to + '  priority=' + [string]$Report.payload.priority + '  kind=' + [string]$Report.payload.kind + '  chars=' + [string]$Report.payload.length))
        [void]$lines.Add('  text    :')
        foreach ($payloadLine in @(([string]$Report.payload.text) -split "`r?`n")) {
            [void]$lines.Add('    ' + $payloadLine)
        }
    }
    [void]$lines.Add('')

    [void]$lines.Add('--- last run (explain) ---')
    if (-not [bool]$Report.last_run.explain_available) {
        [void]$lines.Add('  explain.ps1 unavailable')
    } else {
        [void]$lines.Add('  outcome     : ' + [string]$Report.last_run.outcome)
        [void]$lines.Add('  self-reports: ' + @($Report.self_reports).Count)
        $failures = @($Report.last_run.failures)
        if ($failures.Count -eq 0) {
            [void]$lines.Add('  failures    : none recorded')
        } else {
            foreach ($failure in $failures) {
                [void]$lines.Add(('  [{0}] {1}: {2}' -f [string]$failure.level, [string]$failure.source, [string]$failure.detail))
            }
        }
    }
    [void]$lines.Add('')

    [void]$lines.Add('--- plan ---')
    [void]$lines.Add('  inbox file: ' + $(if ([string]::IsNullOrWhiteSpace([string]$Report.inbox.file)) { '(none)' } else { [string]$Report.inbox.file }))
    if ([string]$Report.mode -eq 'dry-run') {
        [void]$lines.Add('  execution : dry-run - nothing was executed (use -Run to replay)')
    } else {
        [void]$lines.Add('  inbox written : ' + [string]$Report.inbox.written)
        [void]$lines.Add('  engine result : status=' + [string]$Report.engine.status + ' reason=' + [string]$Report.engine.reason)
        [void]$lines.Add('  new evidence  : ' + [string]$Report.new_evidence.file + ' (' + @($Report.new_evidence.attempts).Count + ' attempt(s))')
        [void]$lines.Add('  original evidence untouched: ' + [string]$Report.integrity.original_untouched)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        [void]$lines.Add('')
        [void]$lines.Add('replay: ' + [string]$Report.error)
    }
    $notes = @($Report.notes)
    if ($notes.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('--- notes ---')
        foreach ($note in $notes) { [void]$lines.Add('  ' + $note) }
    }
    return ($lines -join "`r`n")
}

# ===========================================================================
# Main
# ===========================================================================

$exitCode = 0
try {
    $rootPath = Get-ReplayRoot -RootValue $Root
    $bufferFull = if (-not [string]::IsNullOrWhiteSpace($BufferPath)) { $BufferPath } else { Join-Path $rootPath 'CONTEXT-BUFFER.md' }
    $bufferText = Read-ReplayTextFile -Path $bufferFull

    $effectiveTaskId = $TaskId.Trim()
    $selectorSource = 'explicit'
    if ([string]::IsNullOrWhiteSpace($effectiveTaskId)) {
        $effectiveTaskId = Find-ReplayLatestFailedTask -RootValue $rootPath -MaxFiles $MaxEvidenceFiles
        $selectorSource = 'latest-failed'
    }

    $settings = [pscustomobject]@{
        Root           = $rootPath
        EvidenceDir    = (Get-ReplayEvidenceDir -RootValue $rootPath)
        BufferText     = $bufferText
        BufferFull     = $bufferFull
        TaskId         = $effectiveTaskId
        SelectorSource = $selectorSource
        Agent          = $Agent
        RunMode        = ([bool]$Run -and (-not [bool]$DryRun))
        MaxPayloadChars = $MaxPayloadChars
        MaxMessageFiles = $MaxMessageFiles
    }

    $outcome = Invoke-ReplayPlan -Settings $settings
    $report = $outcome.report
    if (([bool]$Run) -and ([bool]$DryRun)) {
        $report.notes = @(@($report.notes) + 'both -Run and -DryRun were given: dry-run wins')
    }

    if ($Json) {
        Write-Output (ConvertTo-ReplayJson -InputObject $report -Depth 10)
    } else {
        Write-Output (Format-ReplayHuman -Report $report)
    }
    $exitCode = [int]$outcome.exit_code
} catch {
    $exitCode = 2
    if ($Json) {
        Write-Output (ConvertTo-ReplayJson -InputObject ([ordered]@{
            tool = 'replay'; ok = $false; mode = $(if ([bool]$Run) { 'run' } else { 'dry-run' })
            error = ('internal error: ' + $_.Exception.Message)
        }) -Depth 6)
    } else {
        Write-Output ('replay: internal error: ' + $_.Exception.Message)
    }
}

exit $exitCode
