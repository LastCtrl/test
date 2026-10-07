# agent-watchdog.ps1 - live supervision of active agent-hq tasks (R3/R4).
# Read signals: traces.jsonl (last event per agent/task), .memory/driver.lock
# heartbeat, .memory/inbox/* (tasks in work), .memory/claims/*.claim.json.
# Modes: -Check (read-only table), -DryRun (show plan), -Enforce (act).
# Enforce on STALLED: failure-memory entry, registry instability++, reassign to
# another agent of the same role pool (cap 2 per task), outbox alert. No process
# killing, atomic writes only (temp + rename), bounded actions per run.

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Enforce,
    [switch]$DryRun,
    [int]$SuspectMin = 5,
    [int]$StalledMin = 10,
    [int]$MaxReassign = 3,
    [int]$ReassignCapPerTask = 2,
    [int]$InstabilityThreshold = 2,
    [int]$CooldownMinutes = 15,
    [string]$Root = "",
    [string]$TracesPath = "",
    [int]$MaxTraceLines = 20000,
    [int]$MaxTraceBytes = 8388608
)

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:FailureSignature = "orchestration|stalled"
$script:ReasonCode = "stalled"
$script:TsFormat = "yyyy-MM-ddTHH:mm:ss"
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# Root / paths
# ---------------------------------------------------------------------------

function Get-WatchdogRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-WatchdogTracesPath {
    param([string]$Root, [string]$TracesPath)
    if (-not [string]::IsNullOrWhiteSpace($TracesPath)) { return $TracesPath }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_TRACES)) { return $env:AGENT_HQ_TRACES }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces\traces.jsonl")
    }
    return (Join-Path $Root ".memory\traces\traces.jsonl")
}

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

function Format-WatchdogTime {
    param([datetime]$Value)
    return $Value.ToString($script:TsFormat, $script:Invariant)
}

function ConvertTo-WatchdogTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local)
        }
        return $dt
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $dto = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($text, $script:Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $dto.LocalDateTime
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($text, $script:Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local)
        }
        return $dt
    }
    return $null
}

function Get-MaxTime {
    param($Times)
    $best = $null
    foreach ($t in @($Times)) {
        if ($null -eq $t) { continue }
        if (($null -eq $best) -or ($t -gt $best)) { $best = $t }
    }
    return $best
}

# ---------------------------------------------------------------------------
# Atomic JSON write (temp + rename), mirrors model-registry / task-state.
# ---------------------------------------------------------------------------

function Write-WatchdogJson {
    param([string]$Path, $Data)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $json = $Data | ConvertTo-Json -Depth 8
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-WatchdogText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Trace tail reader (bounded memory; large files supported)
# ---------------------------------------------------------------------------

function Get-TailText {
    param([string]$Path, [int]$MaxBytes)
    $result = @{ Text = ""; Truncated = $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $length = $fs.Length
        $start = 0
        if ($length -gt $MaxBytes) { $start = $length - $MaxBytes; $result.Truncated = $true }
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $remaining = [int]($length - $start)
        $buffer = New-Object byte[] $remaining
        $read = 0
        while ($read -lt $remaining) {
            $n = $fs.Read($buffer, $read, $remaining - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $result.Text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        return $result
    } catch {
        return $result
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Read-TraceActivity {
    param([string]$Path, [int]$MaxLines, [int]$MaxBytes)
    $agentActivity = @{}
    $taskActivity = @{}
    $tail = Get-TailText -Path $Path -MaxBytes $MaxBytes
    if ([string]::IsNullOrWhiteSpace($tail.Text)) {
        return [pscustomobject]@{ agents = $agentActivity; tasks = $taskActivity }
    }
    $lines = @($tail.Text -split "`n")
    if ($tail.Truncated -and $lines.Count -gt 1) {
        $lines = @($lines[1..($lines.Count - 1)])
    }
    if ($lines.Count -gt $MaxLines) {
        $lines = @($lines[($lines.Count - $MaxLines)..($lines.Count - 1)])
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $obj) { continue }
        $when = ConvertTo-WatchdogTime ([string]$obj.ts)
        if ($null -eq $when) { continue }
        $agent = [string]$obj.agent
        if (-not [string]::IsNullOrWhiteSpace($agent)) {
            $lower = $agent.ToLowerInvariant()
            $prev = $null
            if ($agentActivity.ContainsKey($lower)) { $prev = $agentActivity[$lower] }
            if (($null -eq $prev) -or ($when -gt $prev)) { $agentActivity[$lower] = $when }
        }
        $taskId = [string]$obj.task_id
        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $prevTask = $null
            if ($taskActivity.ContainsKey($taskId)) { $prevTask = $taskActivity[$taskId] }
            if (($null -eq $prevTask) -or ($when -gt $prevTask)) { $taskActivity[$taskId] = $when }
        }
    }
    return [pscustomobject]@{ agents = $agentActivity; tasks = $taskActivity }
}

# ---------------------------------------------------------------------------
# Agent catalog (.opencode/agents/*.json)
# ---------------------------------------------------------------------------

function Get-AgentCatalog {
    param([string]$AgentsDir)
    $map = @{}
    if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) { return $map }
    foreach ($file in @(Get-ChildItem -LiteralPath $AgentsDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $doc = $null
        try {
            $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if ($null -eq $doc) { continue }
        $name = [string]$doc.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $file.BaseName }
        if ($name -eq "registry") { continue }
        $model = [string]$doc.model
        if ([string]::IsNullOrWhiteSpace($model)) { continue }
        $map[$name] = [pscustomobject]@{
            name     = $name
            model    = $model
            division = [string]$doc.division
        }
    }
    return $map
}

# ---------------------------------------------------------------------------
# Active tasks: inbox files (tasks in work) + claims (leases)
# ---------------------------------------------------------------------------

function Read-ActiveTasks {
    param([string]$Memory, [hashtable]$AgentActivity, [hashtable]$TaskActivity)
    $inbox = Join-Path $Memory "inbox"
    $claims = Join-Path $Memory "claims"
    $items = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    $claimByTask = @{}
    if (Test-Path -LiteralPath $claims -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $claims -Filter "*.claim.json" -File -ErrorAction SilentlyContinue)) {
            $claim = $null
            try {
                $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                $claim = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch { continue }
            $taskId = [string]$claim.task_id
            if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = $file.BaseName -replace '\.claim$', '' }
            $claimByTask[$taskId] = [pscustomobject]@{
                agent     = [string]$claim.agent
                heartbeat = ConvertTo-WatchdogTime ([string]$claim.heartbeat_at)
                path      = $file.FullName
                mtime     = $file.LastWriteTime
            }
        }
    }

    if (Test-Path -LiteralPath $inbox -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
            $agent = $dir.Name
            foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
                $msg = $null
                try {
                    $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                    $msg = $raw | ConvertFrom-Json -ErrorAction Stop
                } catch { $msg = $null }
                $taskId = ""
                if ($null -ne $msg) { $taskId = [string]$msg.id }
                if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = $file.BaseName }

                $created = $null
                if ($null -ne $msg) { $created = ConvertTo-WatchdogTime ([string]$msg.created) }
                $claim = $null
                if ($claimByTask.ContainsKey($taskId)) { $claim = $claimByTask[$taskId] }
                $agentLower = $agent.ToLowerInvariant()
                $agentLast = $null
                if ($AgentActivity.ContainsKey($agentLower)) { $agentLast = $AgentActivity[$agentLower] }
                $taskLast = $null
                if ($TaskActivity.ContainsKey($taskId)) { $taskLast = $TaskActivity[$taskId] }
                $claimLast = $null
                if ($null -ne $claim) { $claimLast = $claim.heartbeat }

                $last = Get-MaxTime @($created, $file.LastWriteTime, $agentLast, $taskLast, $claimLast)

                $chain = @()
                $reassignCount = 0
                if ($null -ne $msg) {
                    if ($null -ne $msg.reassign_chain) { $chain = @($msg.reassign_chain | ForEach-Object { [string]$_ }) }
                    if ($null -ne $msg.reassign_count) {
                        [void][int]::TryParse([string]$msg.reassign_count, [ref]$reassignCount)
                    }
                    $from = [string]$msg.reassigned_from
                    if (-not [string]::IsNullOrWhiteSpace($from)) {
                        if ($chain -notcontains $from) { $chain += $from }
                        if ($reassignCount -lt 1) { $reassignCount = 1 }
                    }
                }

                $payload = ""
                $fromField = ""
                $priority = "normal"
                $msgSource = ""
                if ($null -ne $msg) {
                    $payload = [string]$msg.payload
                    $fromField = [string]$msg.from
                    if (-not [string]::IsNullOrWhiteSpace([string]$msg.priority)) { $priority = [string]$msg.priority }
                    $msgSource = [string]$msg.source
                }

                [void]$items.Add([pscustomobject]@{
                    TaskId         = $taskId
                    Agent          = $agent
                    Source         = "inbox"
                    FilePath       = $file.FullName
                    LastActivity   = $last
                    Payload        = $payload
                    From           = $fromField
                    Priority       = $priority
                    TaskSource     = $msgSource
                    ReassignCount  = $reassignCount
                    ReassignChain  = $chain
                })
                [void]$seen.Add($agent + "|" + $taskId)
            }
        }
    }

    foreach ($taskId in @($claimByTask.Keys)) {
        $claim = $claimByTask[$taskId]
        $agent = [string]$claim.agent
        $key = $agent + "|" + $taskId
        if ($seen.Contains($key)) { continue }
        $agentLower = $agent.ToLowerInvariant()
        $agentLast = $null
        if ($AgentActivity.ContainsKey($agentLower)) { $agentLast = $AgentActivity[$agentLower] }
        $taskLast = $null
        if ($TaskActivity.ContainsKey($taskId)) { $taskLast = $TaskActivity[$taskId] }
        $last = Get-MaxTime @($claim.heartbeat, $claim.mtime, $agentLast, $taskLast)
        [void]$items.Add([pscustomobject]@{
            TaskId        = $taskId
            Agent         = $agent
            Source        = "claim"
            FilePath      = ""
            LastActivity  = $last
            Payload       = ""
            From          = ""
            Priority      = "normal"
            TaskSource    = ""
            ReassignCount = 0
            ReassignChain = @()
        })
    }
    return @($items)
}

function Get-WatchdogStatus {
    param([double]$GapMinutes, [int]$SuspectMin, [int]$StalledMin)
    if ($GapMinutes -ge $StalledMin) { return "STALLED" }
    if ($GapMinutes -ge $SuspectMin) { return "SUSPECT" }
    return "ACTIVE"
}

# ---------------------------------------------------------------------------
# Role pool + target selection
# ---------------------------------------------------------------------------

function Get-PoolBase {
    param([string]$Name)
    return ($Name -replace '(-\d+)+$', '')
}

function Find-ReassignTarget {
    param(
        [string]$Base,
        [string]$StalledAgent,
        [hashtable]$Agents,
        [hashtable]$StatusByAgent,
        [hashtable]$LoadByAgent,
        [string[]]$Chain
    )
    $best = $null
    $bestLoad = [int]::MaxValue
    foreach ($name in @($Agents.Keys | Sort-Object)) {
        if ($name -eq $StalledAgent) { continue }
        if ((Get-PoolBase -Name $name) -ne $Base) { continue }
        if (@($Chain) -contains $name) { continue }
        $status = "ACTIVE"
        if ($StatusByAgent.ContainsKey($name)) { $status = [string]$StatusByAgent[$name] }
        if ($status -ne "ACTIVE") { continue }
        $load = 0
        if ($LoadByAgent.ContainsKey($name)) { $load = [int]$LoadByAgent[$name] }
        if ($load -lt $bestLoad) { $bestLoad = $load; $best = $name }
    }
    return $best
}

# ---------------------------------------------------------------------------
# Enforce side effects
# ---------------------------------------------------------------------------

function Add-FailureMemoryStalled {
    param([string]$Path, [string]$Agent, [string]$Model, [string]$TaskId, [datetime]$Now)
    $agentKey = $Agent.ToLowerInvariant()
    $stamp = Format-WatchdogTime -Value $Now
    $entries = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -ne $entry) { [void]$entries.Add($entry) }
        }
    }
    $updated = $false
    foreach ($entry in $entries) {
        if (([string]$entry.signature -eq $script:FailureSignature) -and
            (([string]$entry.agent).ToLowerInvariant() -eq $agentKey) -and
            ([string]$entry.reason_code -eq $script:ReasonCode)) {
            $entry.count = [int]$entry.count + 1
            $entry.last_seen = $stamp
            if ([string]::IsNullOrWhiteSpace([string]$entry.sample_task_id)) { $entry.sample_task_id = $TaskId }
            $entry.model = $Model
            $updated = $true
            break
        }
    }
    if (-not $updated) {
        [void]$entries.Add([pscustomobject]@{
            signature      = $script:FailureSignature
            task_type      = "orchestration"
            agent          = $agentKey
            model          = $Model
            reason_code    = $script:ReasonCode
            first_seen     = $stamp
            last_seen      = $stamp
            count          = 1
            sample_task_id = $TaskId
            fixed          = $false
        })
    }
    $lines = New-Object System.Collections.ArrayList
    foreach ($entry in $entries) {
        [void]$lines.Add(($entry | ConvertTo-Json -Compress -Depth 4))
    }
    $text = ($lines -join "`r`n")
    if ($lines.Count -gt 0) { $text += "`r`n" }
    return (Write-WatchdogText -Path $Path -Text $text)
}

function Add-RegistryInstability {
    param([string]$Path, [string]$Model, [datetime]$Now, [int]$Threshold, [int]$CooldownMin)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $doc = $null
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return $false }
    if ($null -eq $doc) { return $false }

    $models = [ordered]@{}
    if ($null -ne $doc.models) {
        foreach ($property in @($doc.models.PSObject.Properties)) {
            $models[$property.Name] = $property.Value
        }
    }
    # Unknown models are NOT injected into discovery output (avoids ghost
    # "unprobed" entries); instability for them is simply skipped.
    if (-not $models.Contains($Model)) { return $false }
    $entry = $models[$Model]
    if ($null -eq $entry) { return $false }
    $failCount = 0
    [void][int]::TryParse([string]$entry.fail_count, [ref]$failCount)
    $failCount = $failCount + 1
    $entry | Add-Member -NotePropertyName 'fail_count' -NotePropertyValue $failCount -Force
    if ($failCount -ge $Threshold) {
        $entry | Add-Member -NotePropertyName 'unstable_until' -NotePropertyValue (Format-WatchdogTime -Value ($Now.AddMinutes($CooldownMin))) -Force
    }

    # Preserve every top-level key (except "models", rebuilt below) and every
    # per-model field, so future schema additions are not silently dropped.
    $out = [ordered]@{}
    foreach ($property in @($doc.PSObject.Properties)) {
        if ($property.Name -eq "models") { continue }
        $out[$property.Name] = $property.Value
    }
    $outModels = [ordered]@{}
    foreach ($key in @($models.Keys | Sort-Object)) {
        $fields = [ordered]@{}
        foreach ($field in @($models[$key].PSObject.Properties)) {
            $fields[$field.Name] = $field.Value
        }
        $outModels[$key] = $fields
    }
    $out["models"] = $outModels
    return (Write-WatchdogJson -Path $Path -Data $out)
}

function Write-WatchdogAlert {
    param([string]$Outbox, [string]$Id, [string]$To, [string]$Payload, [datetime]$Now)
    $stamp = Format-WatchdogTime -Value $Now
    $msg = [ordered]@{
        id         = $Id
        from       = "agent-watchdog"
        to         = $To
        type       = "alert"
        priority   = "high"
        payload    = $Payload
        status     = "alert"
        created    = $stamp
        finishedAt = $stamp
        response   = $Payload
    }
    return (Write-WatchdogJson -Path (Join-Path $Outbox "$Id.json") -Data $msg)
}

function Move-WatchdogDeadLetter {
    param([string]$FilePath, [string]$DeadLetter, [string]$To, [string]$Payload, [string]$Response, [string]$Id, [datetime]$Now)
    $stamp = Format-WatchdogTime -Value $Now
    $msg = [ordered]@{
        id         = $Id
        from       = "agent-watchdog"
        to         = $To
        type       = "failed"
        priority   = "high"
        payload    = $Payload
        status     = "failed"
        startedAt  = $stamp
        finishedAt = $stamp
        response   = $Response
    }
    $ok = Write-WatchdogJson -Path (Join-Path $DeadLetter "$Id.json") -Data $msg
    if ($ok -and (-not [string]::IsNullOrWhiteSpace($FilePath)) -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
    }
    return $ok
}

function Move-WatchdogArchive {
    param([string]$FilePath, [string]$Agent, [string]$ArchiveDir)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or (-not (Test-Path -LiteralPath $FilePath -PathType Leaf))) { return $false }
    $archive = $ArchiveDir
    if ([string]::IsNullOrWhiteSpace($archive)) { return $false }
    if (-not (Test-Path -LiteralPath $archive -PathType Container)) {
        New-Item -ItemType Directory -Path $archive -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $leaf = Split-Path $FilePath -Leaf
    $dest = Join-Path $archive ("$Agent-$leaf")
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        $dest = Join-Path $archive ("$Agent-$([guid]::NewGuid().ToString('N'))-$leaf")
    }
    try {
        Move-Item -LiteralPath $FilePath -Destination $dest -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:Root = Get-WatchdogRoot -Root $Root
$memory = Join-Path $script:Root ".memory"
$inbox = Join-Path $memory "inbox"
$outbox = Join-Path $memory "outbox"
$archive = Join-Path $memory "archive"
$deadLetter = Join-Path $memory "dead-letter"
$registryPath = Join-Path $memory "model-registry.json"
$failurePath = Join-Path $memory "failure-memory.jsonl"
$driverLockPath = Join-Path $memory "driver.lock"
$agentsDir = Join-Path $script:Root ".opencode\agents"
$tracesPath = Get-WatchdogTracesPath -Root $script:Root -TracesPath $TracesPath

$now = Get-Date
$agents = Get-AgentCatalog -AgentsDir $agentsDir
$activity = Read-TraceActivity -Path $tracesPath -MaxLines $MaxTraceLines -MaxBytes $MaxTraceBytes
$active = @(Read-ActiveTasks -Memory $memory -AgentActivity $activity.agents -TaskActivity $activity.tasks)

# driver.lock heartbeat (informational: Go loop liveness)
$driverHeartbeat = $null
if (Test-Path -LiteralPath $driverLockPath -PathType Leaf) {
    try {
        $lock = [System.IO.File]::ReadAllText($driverLockPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $driverHeartbeat = ConvertTo-WatchdogTime ([string]$lock.heartbeat_at)
    } catch { $driverHeartbeat = $null }
}

$rows = New-Object System.Collections.ArrayList
$statusByAgent = @{}
$loadByAgent = @{}
foreach ($task in $active) {
    $agentLower = ([string]$task.Agent).ToLowerInvariant()
    if ($loadByAgent.ContainsKey($agentLower)) { $loadByAgent[$agentLower] = [int]$loadByAgent[$agentLower] + 1 }
    else { $loadByAgent[$agentLower] = 1 }
}

foreach ($task in @($active | Sort-Object -Property Agent, TaskId)) {
    $gap = 0.0
    if ($null -ne $task.LastActivity) { $gap = ($now - $task.LastActivity).TotalMinutes }
    if ($gap -lt 0) { $gap = 0.0 }
    $status = Get-WatchdogStatus -GapMinutes $gap -SuspectMin $SuspectMin -StalledMin $StalledMin
    $agentLower = ([string]$task.Agent).ToLowerInvariant()
    if ($statusByAgent.ContainsKey($agentLower)) {
        $existing = [string]$statusByAgent[$agentLower]
        $rank = @{ "ACTIVE" = 0; "SUSPECT" = 1; "STALLED" = 2 }
        if ($rank[$status] -gt $rank[$existing]) { $statusByAgent[$agentLower] = $status }
    } else {
        $statusByAgent[$agentLower] = $status
    }
    $lastText = "-"
    if ($null -ne $task.LastActivity) { $lastText = Format-WatchdogTime -Value $task.LastActivity }
    [void]$rows.Add([pscustomobject]@{
        Agent        = $task.Agent
        Task         = $task.TaskId
        Source       = $task.Source
        LastActivity = $lastText
        Gap          = [math]::Round($gap, 1)
        Status       = $status
        Raw          = $task
    })
}

$driverText = "absent"
if ($null -ne $driverHeartbeat) {
    $driverGap = [math]::Round(($now - $driverHeartbeat).TotalMinutes, 1)
    $driverText = (Format-WatchdogTime -Value $driverHeartbeat) + " (gap " + $driverGap + "m)"
}

$mode = "CHECK"
if ($DryRun) { $mode = "DRYRUN" }
elseif ($Enforce) { $mode = "ENFORCE" }

Write-Host ""
Write-Host ("AGENT WATCHDOG  root=" + $script:Root + "  mode=" + $mode) -ForegroundColor Cyan
Write-Host ("  traces      : " + $tracesPath) -ForegroundColor DarkGray
Write-Host ("  driver.lock : " + $driverText) -ForegroundColor DarkGray
Write-Host ("  thresholds  : suspect=" + $SuspectMin + "m stalled=" + $StalledMin + "m  cap/task=" + $ReassignCapPerTask + " max/run=" + $MaxReassign) -ForegroundColor DarkGray
Write-Host ""

if ($rows.Count -eq 0) {
    Write-Host "No active tasks found." -ForegroundColor Green
} else {
    $table = @()
    foreach ($row in $rows) {
        $table += [pscustomobject][ordered]@{
            AGENT         = $row.Agent
            TASK          = $row.Task
            LAST_ACTIVITY = $row.LastActivity
            GAP_MIN       = $row.Gap
            STATUS        = $row.Status
        }
    }
    $table | Format-Table -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# Enforce / DryRun plan
# ---------------------------------------------------------------------------

if ($Enforce -or $DryRun) {
    $stalled = @($rows | Where-Object { $_.Status -eq "STALLED" } | Sort-Object -Property @{ Expression = { [double]$_.Gap }; Descending = $true })
    Write-Host ("STALLED tasks: " + $stalled.Count) -ForegroundColor Yellow

    $actions = 0
    $plans = New-Object System.Collections.ArrayList
    foreach ($row in $stalled) {
        if ($actions -ge $MaxReassign) {
            Write-Host ("  action cap reached (" + $MaxReassign + "); remaining stalled tasks are left untouched this run") -ForegroundColor Yellow
            break
        }
        $task = $row.Raw
        if ([string]::IsNullOrWhiteSpace([string]$task.FilePath)) {
            Write-Host ("  [" + $row.Agent + "/" + $row.Task + "] no inbox file (claim-only) - alert only") -ForegroundColor Yellow
            $payload = "Watchdog: task '" + $row.Task + "' of agent '" + $row.Agent + "' is STALLED (gap " + $row.Gap + "m) but has no inbox payload; manual review needed."
            if ($DryRun) {
                Write-Host ("    PLAN: outbox alert -> " + $row.Agent) -ForegroundColor Gray
            } else {
                $alertId = "watchdog-alert-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
                [void](Write-WatchdogAlert -Outbox $outbox -Id $alertId -To $row.Agent -Payload $payload -Now $now)
                Write-Host ("    wrote outbox alert " + $alertId) -ForegroundColor Green
            }
            $actions++
            continue
        }

        $agentName = [string]$row.Agent
        $agentLower = $agentName.ToLowerInvariant()
        $model = ""
        if ($agents.ContainsKey($agentName)) { $model = [string]$agents[$agentName].model }
        $base = Get-PoolBase -Name $agentName

        if ([int]$task.ReassignCount -ge $ReassignCapPerTask) {
            $msg = "Watchdog: reassign cap (" + $ReassignCapPerTask + ") reached for task '" + $row.Task + "' (agent " + $agentName + ", gap " + $row.Gap + "m); dead-letter + alert."
            if ($DryRun) {
                Write-Host ("  [" + $agentName + "/" + $row.Task + "] PLAN: dead-letter + alert (cap reached, model=" + $model + ")") -ForegroundColor Gray
            } else {
                $dlId = [guid]::NewGuid().ToString()
                [void](Move-WatchdogDeadLetter -FilePath $task.FilePath -DeadLetter $deadLetter -To $agentName -Payload $task.Payload -Response $msg -Id $dlId -Now $now)
                $alertId = "watchdog-alert-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
                [void](Write-WatchdogAlert -Outbox $outbox -Id $alertId -To $agentName -Payload $msg -Now $now)
                [void](Add-FailureMemoryStalled -Path $failurePath -Agent $agentName -Model $model -TaskId $row.Task -Now $now)
                [void](Add-RegistryInstability -Path $registryPath -Model $model -Now $now -Threshold $InstabilityThreshold -CooldownMin $CooldownMinutes)
                Write-Host ("  [" + $agentName + "/" + $row.Task + "] dead-letter + alert done") -ForegroundColor Green
            }
            $actions++
            continue
        }

        $target = Find-ReassignTarget -Base $base -StalledAgent $agentName -Agents $agents -StatusByAgent $statusByAgent -LoadByAgent $loadByAgent -Chain $task.ReassignChain
        if ([string]::IsNullOrWhiteSpace($target)) {
            $msg = "Watchdog: task '" + $row.Task + "' of agent " + $agentName + " is STALLED (gap " + $row.Gap + "m) and no free peer in role pool '" + $base + "'; dead-letter + alert."
            if ($DryRun) {
                Write-Host ("  [" + $agentName + "/" + $row.Task + "] PLAN: NO free peer in pool '" + $base + "' -> dead-letter + alert") -ForegroundColor Gray
            } else {
                $dlId = [guid]::NewGuid().ToString()
                [void](Move-WatchdogDeadLetter -FilePath $task.FilePath -DeadLetter $deadLetter -To $agentName -Payload $task.Payload -Response $msg -Id $dlId -Now $now)
                $alertId = "watchdog-alert-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
                [void](Write-WatchdogAlert -Outbox $outbox -Id $alertId -To $agentName -Payload $msg -Now $now)
                [void](Add-FailureMemoryStalled -Path $failurePath -Agent $agentName -Model $model -TaskId $row.Task -Now $now)
                [void](Add-RegistryInstability -Path $registryPath -Model $model -Now $now -Threshold $InstabilityThreshold -CooldownMin $CooldownMinutes)
                Write-Host ("  [" + $agentName + "/" + $row.Task + "] no peer -> dead-letter + alert done") -ForegroundColor Green
            }
            $actions++
            continue
        }

        $newCount = [int]$task.ReassignCount + 1
        $newChain = @($task.ReassignChain) + @($agentName)
        $newChain = @($newChain | Select-Object -Unique)
        $stamp = Format-WatchdogTime -Value $now
        $newId = "reassign-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $newTask = [ordered]@{
            id              = $newId
            from            = "agent-watchdog"
            to              = $target
            type            = "task"
            priority        = $task.Priority
            payload         = $task.Payload
            created         = $stamp
            source          = $task.TaskSource
            reassigned_from = $agentName
            reassign_chain  = $newChain
            reassign_count  = $newCount
        }
        $targetInbox = Join-Path $inbox $target
        $alertMsg = "Watchdog: reassigned STALLED task '" + $row.Task + "' from " + $agentName + " to " + $target + " (gap " + $row.Gap + "m, attempt " + $newCount + "/" + $ReassignCapPerTask + ", model=" + $model + ")."

        if ($DryRun) {
            Write-Host ("  [" + $agentName + "/" + $row.Task + "] PLAN: reassign -> " + $target + " (pool '" + $base + "', attempt " + $newCount + "/" + $ReassignCapPerTask + ")") -ForegroundColor Gray
            Write-Host ("    also: failure-memory += " + $script:FailureSignature + ", registry instability++ " + $model + ", outbox alert") -ForegroundColor DarkGray
        } else {
            $archived = Move-WatchdogArchive -FilePath $task.FilePath -Agent $agentName -ArchiveDir $archive
            $written = Write-WatchdogJson -Path (Join-Path $targetInbox ($newId + ".json")) -Data $newTask
            [void](Add-FailureMemoryStalled -Path $failurePath -Agent $agentName -Model $model -TaskId $row.Task -Now $now)
            [void](Add-RegistryInstability -Path $registryPath -Model $model -Now $now -Threshold $InstabilityThreshold -CooldownMin $CooldownMinutes)
            $alertId = "watchdog-alert-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
            [void](Write-WatchdogAlert -Outbox $outbox -Id $alertId -To $target -Payload $alertMsg -Now $now)
            Write-Host ("  [" + $agentName + "/" + $row.Task + "] reassigned -> " + $target + " (new " + $newId + ", archived=" + $archived + ", written=" + $written + ")") -ForegroundColor Green
        }
        $targetLower = $target.ToLowerInvariant()
        if ($loadByAgent.ContainsKey($targetLower)) { $loadByAgent[$targetLower] = [int]$loadByAgent[$targetLower] + 1 }
        else { $loadByAgent[$targetLower] = 1 }
        $actions++
    }
    Write-Host ("Actions executed/planned: " + $actions) -ForegroundColor Cyan
}

Write-Host ""
Write-Host ("rows=" + $rows.Count + " stalled=" + @($rows | Where-Object { $_.Status -eq 'STALLED' }).Count + " suspect=" + @($rows | Where-Object { $_.Status -eq 'SUSPECT' }).Count + " mode=" + $mode)
