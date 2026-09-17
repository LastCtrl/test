# budget.ps1 - "how much of the daily budget is used / left" (P3-3).
#
# Read-only accounting over what the fleet already records. It writes nothing.
#
# Sources:
#   * performance.jsonl (@ .opencode\plugins\scoring.js) - one record per finished
#     opencode session { ts, session_id, duration_ms, score } plus { type:
#     "delegation" } markers for every `task` tool call.
#   * traces.jsonl (@ .opencode\plugins\tracer.js) - joined on session_id to
#     attribute a session to an agent / task (perf records carry no agent field).
#   * .opencode\agents\<agent>.json - the configured model of an agent, so usage
#     can be rolled up per model.
#   * .memory\evidence\*\json - stdout/stderr byte lengths, the only token-ish
#     signal available. Token counts are an ESTIMATE (chars / 4) and are always
#     labelled as such; the fleet does not record real token usage yet.
#
# Limits: .agents\config\model-limits.json (a built-in fallback is used when the
# file is missing). Only limits that are actually documented are numeric; every
# other model is null = "no published limit" and can never trigger a warning.
#
# Usage:
#   .\budget.ps1
#   .\budget.ps1 -SinceHours 6 -Json
#   .\budget.ps1 -Agent qa-engineer
#   .\budget.ps1 -LimitsPath C:\tmp\limits.json -WarnAt 0.6
#
# Exit code: 0 = within limits, 2 = WARN (>= WarnAt of a limit) or OVER (>= 100%),
# 1 = unexpected internal failure.
#
# Pure PowerShell 5.1. CRLF. No secrets are read, printed or written.

[CmdletBinding()]
param(
    [int]$SinceHours = 24,
    [switch]$Json,
    [string]$Agent = '',
    [string]$Root = '',
    [string]$TracesDir = '',
    [string]$LimitsPath = '',
    [double]$WarnAt = 0.8,
    [int]$MaxTraceBytes = 524288
)

$script:BudgetScriptRoot = $PSScriptRoot
# Fallback limits, kept in sync with .agents\config\model-limits.json. Only the
# two ceilings that are actually documented in AGENTS.md are numeric here.
$script:BudgetBuiltInLimits = [ordered]@{
    'opencode/big-pickle'     = [ordered]@{ provider = 'opencode'; tier = 'free'; requests_per_day = 100; tokens_per_day = 1000000; confidence = 'documented'; source = 'AGENTS.md section 1' }
    'aihubmix/gpt-5.5-free'   = [ordered]@{ provider = 'aihubmix'; tier = 'free'; requests_per_day = 100; tokens_per_day = 1000000; confidence = 'documented'; source = 'AGENTS.md section 1' }
    'aihubmix/coding-glm-5.1-free' = [ordered]@{ provider = 'aihubmix'; tier = 'free'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'no published limit (NOT ENOUGH EVIDENCE)' }
    'opencode/ling-3.0-flash-fin-free' = [ordered]@{ provider = 'opencode'; tier = 'free'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'no published limit (NOT ENOUGH EVIDENCE)' }
    'opencode/mimo-v2.5-free' = [ordered]@{ provider = 'opencode'; tier = 'free'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'no published limit (NOT ENOUGH EVIDENCE)' }
    'opencode/nemotron-3.5-lightning-free' = [ordered]@{ provider = 'opencode'; tier = 'free'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'no published limit (NOT ENOUGH EVIDENCE)' }
    'opencode-go/deepseek-v4.1-flash' = [ordered]@{ provider = 'opencode-go'; tier = 'paid'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'paid endpoint (approval-based)' }
    'opencode-go/qwen3.8-flash' = [ordered]@{ provider = 'opencode-go'; tier = 'paid'; requests_per_day = $null; tokens_per_day = $null; confidence = 'unknown'; source = 'paid endpoint (approval-based)' }
}

# ===========================================================================
# Path / value helpers
# ===========================================================================

function Get-BudgetRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:BudgetScriptRoot)) {
        return (Split-Path (Split-Path $script:BudgetScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-BudgetTracesDir {
    param([string]$TracesDirValue)
    if (-not [string]::IsNullOrWhiteSpace($TracesDirValue)) { return $TracesDirValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_TRACES_DIR)) { return $env:AGENT_HQ_TRACES_DIR }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'opencode') 'agent-hq-traces')
}

function Get-BudgetLimitsPath {
    param([string]$LimitsPathValue, [string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($LimitsPathValue)) { return $LimitsPathValue }
    return (Join-Path (Join-Path (Join-Path $RootValue '.agents') 'config') 'model-limits.json')
}

function ConvertTo-BudgetInt {
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $Default
}

# Nullable integer: a missing / null / non-numeric limit means "unknown".
function ConvertTo-BudgetNullableInt {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-BudgetUtc {
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

function Format-BudgetDuration {
    param([long]$Ms)
    if ($Ms -le 0) { return '0 ms' }
    if ($Ms -lt 1000) { return ($Ms.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' ms') }
    if ($Ms -lt 60000) {
        $seconds = [math]::Round($Ms / 1000.0, 1)
        return ($seconds.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' s')
    }
    $minutes = [math]::Round($Ms / 60000.0, 1)
    return ($minutes.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' min')
}

function Format-BudgetPercent {
    param([double]$Ratio)
    $percent = [math]::Round($Ratio * 100.0, 1)
    return ($percent.ToString([System.Globalization.CultureInfo]::InvariantCulture) + '%')
}

function ConvertTo-BudgetJson {
    param($InputObject, [int]$Depth = 8)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) }
        else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

function Read-BudgetTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        return ''
    }
}

# Tail of a jsonl file; a concurrent appender only needs a shared read handle.
function Read-BudgetJsonl {
    param([string]$Path, [int]$MaxBytes)
    $out = [ordered]@{ records = @(); broken_lines = 0; truncated = $false; error = ''; exists = $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { $out.error = 'not configured'; return [pscustomobject]$out }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $out.error = 'missing'; return [pscustomobject]$out }
    $out.exists = $true
    if ($MaxBytes -le 0) { $out.error = 'invalid byte budget'; return [pscustomobject]$out }
    $start = 0
    try {
        $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        if ($length -gt $MaxBytes) { $start = $length - $MaxBytes; $out.truncated = $true }
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
        $out.error = $_.Exception.Message
        return [pscustomobject]$out
    }

    $lines = @($text -split "`r?`n")
    if ($start -gt 0 -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    $parsed = New-Object System.Collections.ArrayList
    foreach ($line in @($lines | Where-Object { $_.Trim().Length -gt 0 })) {
        $record = $null
        try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { $record = $null }
        if ($null -eq $record) { $out.broken_lines++; continue }
        [void]$parsed.Add($record)
    }
    $out.records = @($parsed)
    return [pscustomobject]$out
}

# ===========================================================================
# Limits configuration
# ===========================================================================

function Read-BudgetLimits {
    param([string]$LimitsPathValue)
    $result = [ordered]@{
        path       = $LimitsPathValue
        source     = 'built-in'
        exists     = $false
        models     = @{}
        notes      = @()
    }

    $raw = Read-BudgetTextFile -Path $LimitsPathValue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.notes += ('limits config not found or empty: ' + $LimitsPathValue + ' - using the built-in table')
        foreach ($key in @($script:BudgetBuiltInLimits.Keys)) { $result.models[$key] = $script:BudgetBuiltInLimits[$key] }
        return [pscustomobject]$result
    }

    $json = $null
    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    if ($null -eq $json) {
        $result.notes += ('limits config is not valid JSON: ' + $LimitsPathValue + ' - using the built-in table')
        foreach ($key in @($script:BudgetBuiltInLimits.Keys)) { $result.models[$key] = $script:BudgetBuiltInLimits[$key] }
        return [pscustomobject]$result
    }

    $sourceNode = $json
    if ($null -ne $json.PSObject.Properties['models']) { $sourceNode = $json.models }
    if ($null -eq $sourceNode) {
        $result.notes += 'limits config has no "models" object - using the built-in table'
        foreach ($key in @($script:BudgetBuiltInLimits.Keys)) { $result.models[$key] = $script:BudgetBuiltInLimits[$key] }
        return [pscustomobject]$result
    }

    $count = 0
    foreach ($property in @($sourceNode.PSObject.Properties)) {
        $entry = $property.Value
        if ($null -eq $entry) { continue }
        $result.models[$property.Name] = [ordered]@{
            provider         = $(if ($null -ne $entry.provider) { [string]$entry.provider } else { '' })
            tier             = $(if ($null -ne $entry.tier) { [string]$entry.tier } else { '' })
            requests_per_day = ConvertTo-BudgetNullableInt -Value $entry.requests_per_day
            tokens_per_day   = ConvertTo-BudgetNullableInt -Value $entry.tokens_per_day
            confidence       = $(if ($null -ne $entry.confidence) { [string]$entry.confidence } else { '' })
            source           = $(if ($null -ne $entry.source) { [string]$entry.source } else { '' })
        }
        $count++
    }

    if ($count -eq 0) {
        $result.notes += 'limits config lists no models - using the built-in table'
        foreach ($key in @($script:BudgetBuiltInLimits.Keys)) { $result.models[$key] = $script:BudgetBuiltInLimits[$key] }
        return [pscustomobject]$result
    }

    $result.exists = $true
    $result.source = 'config'
    return [pscustomobject]$result
}

# ===========================================================================
# Trace / agent / model attribution
# ===========================================================================

# session_id -> agent from the trace spans (perf records have no agent field).
function Get-BudgetSessionAgents {
    param([string]$TracesDirValue, [int]$MaxBytes)
    $map = @{}
    $file = Join-Path $TracesDirValue 'traces.jsonl'
    $read = Read-BudgetJsonl -Path $file -MaxBytes $MaxBytes
    foreach ($record in @($read.records)) {
        $sessionId = [string]$record.session_id
        $agentName = [string]$record.agent
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        if ([string]::IsNullOrWhiteSpace($agentName)) { continue }
        if (-not $map.ContainsKey($sessionId)) { $map[$sessionId] = $agentName }
    }
    return [pscustomobject]@{ map = $map; file = $file; exists = [bool]$read.exists; broken_lines = [int]$read.broken_lines; error = [string]$read.error }
}

# agent -> configured model from .opencode\agents\<agent>.json (regex-guarded name).
function Get-BudgetAgentModels {
    param([string]$RootValue, [string[]]$AgentNames)
    $map = @{}
    foreach ($name in @($AgentNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $map[$name] = ''; continue }
        $file = Join-Path (Join-Path $RootValue '.opencode\agents') ($name + '.json')
        $raw = Read-BudgetTextFile -Path $file
        if ([string]::IsNullOrWhiteSpace($raw)) { $map[$name] = ''; continue }
        $json = $null
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        if (($null -ne $json) -and ($null -ne $json.model)) { $map[$name] = [string]$json.model } else { $map[$name] = '' }
    }
    return $map
}

# Estimated token usage per agent from evidence stdout/stderr lengths.
function Get-BudgetEvidenceTokens {
    param([string]$RootValue, [string]$AgentValue)
    $usage = @{}
    $dir = Join-Path (Join-Path $RootValue '.memory') 'evidence'
    $notes = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void]$notes.Add('evidence directory missing - token usage cannot be estimated')
        return [pscustomobject]@{ usage = $usage; notes = @($notes); files = 0 }
    }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($file in $files) {
        $raw = Read-BudgetTextFile -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $json = $null
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        if ($null -eq $json) {
            [void]$notes.Add('broken evidence json: ' + $file.Name)
            continue
        }
        foreach ($attempt in @($json.attempts)) {
            if ($null -eq $attempt) { continue }
            $attemptAgent = [string]$attempt.agent
            if ([string]::IsNullOrWhiteSpace($attemptAgent)) { $attemptAgent = '(unknown)' }
            if ((-not [string]::IsNullOrWhiteSpace($AgentValue)) -and ($attemptAgent -ne $AgentValue)) { continue }
            $chars = (ConvertTo-BudgetInt -Value $attempt.stdout_length -Default 0) + (ConvertTo-BudgetInt -Value $attempt.stderr_length -Default 0)
            if (-not $usage.ContainsKey($attemptAgent)) { $usage[$attemptAgent] = [ordered]@{ chars = 0; tokens = 0; attempts = 0 } }
            $usage[$attemptAgent].chars += $chars
            $usage[$attemptAgent].attempts += 1
        }
    }
    foreach ($key in @($usage.Keys)) {
        # ~4 characters per token: an explicit ESTIMATE, not measured usage.
        $usage[$key].tokens = [int][math]::Round($usage[$key].chars / 4.0)
    }
    return [pscustomobject]@{ usage = $usage; notes = @($notes); files = $files.Count }
}

# ===========================================================================
# Main
# ===========================================================================

$exitCode = 0
try {
    $budgetRootPath = Get-BudgetRoot -RootValue $Root
    $budgetTracesPath = Get-BudgetTracesDir -TracesDirValue $TracesDir
    $budgetLimitsPath = Get-BudgetLimitsPath -LimitsPathValue $LimitsPath -RootValue $budgetRootPath
    $budgetLimits = Read-BudgetLimits -LimitsPathValue $budgetLimitsPath

    $nowUtc = (Get-Date).ToUniversalTime()
    $cutoff = $null
    if ($SinceHours -gt 0) { $cutoff = $nowUtc.AddHours(-$SinceHours) }

    $perfFile = Join-Path $budgetTracesPath 'performance.jsonl'
    $perf = Read-BudgetJsonl -Path $perfFile -MaxBytes $MaxTraceBytes

    $sessionAgents = Get-BudgetSessionAgents -TracesDirValue $budgetTracesPath -MaxBytes $MaxTraceBytes

    $notes = New-Object System.Collections.ArrayList
    foreach ($note in @($budgetLimits.notes)) { [void]$notes.Add([string]$note) }
    if (-not $perf.exists) { [void]$notes.Add('performance.jsonl not found: ' + $perfFile) }
    if (-not [string]::IsNullOrWhiteSpace([string]$perf.error)) { [void]$notes.Add('performance read: ' + [string]$perf.error) }
    if ($perf.truncated) { [void]$notes.Add('performance.jsonl was read from its tail (older records not counted)') }
    if ([int]$perf.broken_lines -gt 0) { [void]$notes.Add('broken performance lines skipped: ' + [int]$perf.broken_lines) }
    if (-not $sessionAgents.exists) { [void]$notes.Add('traces.jsonl not found: agent attribution degraded to (unknown)') }

    $sessionRows = New-Object System.Collections.ArrayList
    $delegationRows = New-Object System.Collections.ArrayList
    $otherRecords = 0
    $undated = 0
    foreach ($record in @($perf.records)) {
        $tsText = [string]$record.ts
        $instant = ConvertTo-BudgetUtc -Text $tsText
        if ($null -eq $instant) { $undated++ }
        $recordType = [string]$record.type
        if (-not [string]::IsNullOrWhiteSpace([string]$record.session_id)) {
            if (($null -ne $cutoff) -and ($null -ne $instant) -and ($instant -lt $cutoff)) { continue }
            [void]$sessionRows.Add([ordered]@{
                ts          = $tsText
                instant     = $instant
                session_id  = [string]$record.session_id
                duration_ms = ConvertTo-BudgetInt -Value $record.duration_ms -Default 0
                score       = ConvertTo-BudgetNullableInt -Value $record.score
            })
            continue
        }
        if ($recordType -eq 'delegation') {
            if (($null -ne $cutoff) -and ($null -ne $instant) -and ($instant -lt $cutoff)) { continue }
            [void]$delegationRows.Add([ordered]@{ ts = $tsText; instant = $instant })
            continue
        }
        $otherRecords++
    }
    if ($undated -gt 0) { [void]$notes.Add('records with an unparsable timestamp are kept (window filter skipped for them): ' + $undated) }

    # --- per-agent aggregation -------------------------------------------
    $byAgent = @{}
    $attributedSessions = 0
    $unattributedSessions = 0
    foreach ($row in $sessionRows) {
        $sessionId = [string]$row.session_id
        $agentName = '(unknown)'
        if ($sessionAgents.map.ContainsKey($sessionId)) {
            $agentName = [string]$sessionAgents.map[$sessionId]
            $attributedSessions++
        } else {
            $unattributedSessions++
        }
        if ((-not [string]::IsNullOrWhiteSpace($Agent)) -and ($agentName -ne $Agent)) { continue }
        if (-not $byAgent.ContainsKey($agentName)) {
            $byAgent[$agentName] = [ordered]@{ agent = $agentName; runs = 0; delegations = 0; duration_ms = [long]0; tokens_estimated = $false; tokens = 0; model = '' }
        }
        $byAgent[$agentName].runs += 1
        $byAgent[$agentName].duration_ms += [long]$row.duration_ms
    }
    if ([string]::IsNullOrWhiteSpace($Agent)) {
        foreach ($row in $delegationRows) {
            $agentName = '(unattributed)'
            if (-not $byAgent.ContainsKey($agentName)) {
                $byAgent[$agentName] = [ordered]@{ agent = $agentName; runs = 0; delegations = 0; duration_ms = [long]0; tokens_estimated = $false; tokens = 0; model = '' }
            }
            $byAgent[$agentName].delegations += 1
        }
    }
    if ($unattributedSessions -gt 0) {
        [void]$notes.Add('sessions without agent attribution: ' + $unattributedSessions + ' of ' + ($attributedSessions + $unattributedSessions) + ' (no matching agent field inside the traces read window)')
    }

    $agentNames = @($byAgent.Keys)
    $agentModels = Get-BudgetAgentModels -RootValue $budgetRootPath -AgentNames $agentNames
    foreach ($name in @($agentNames)) {
        if ($agentModels.ContainsKey($name)) { $byAgent[$name].model = [string]$agentModels[$name] }
    }

    $tokenUsage = Get-BudgetEvidenceTokens -RootValue $budgetRootPath -AgentValue $Agent
    foreach ($note in @($tokenUsage.notes)) { [void]$notes.Add([string]$note) }
    foreach ($name in @($tokenUsage.usage.Keys)) {
        if ($byAgent.ContainsKey($name)) {
            $byAgent[$name].tokens = [int]$tokenUsage.usage[$name].tokens
            $byAgent[$name].tokens_estimated = $true
        }
    }

    # --- per-model aggregation -------------------------------------------
    $byModel = @{}
    foreach ($name in @($byAgent.Keys)) {
        $entry = $byAgent[$name]
        $modelName = [string]$entry.model
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = '(unknown)' }
        if (-not $byModel.ContainsKey($modelName)) {
            $byModel[$modelName] = [ordered]@{
                model = $modelName; agents = @(); runs = 0; delegations = 0
                duration_ms = [long]0; tokens_estimated = $false; tokens = 0
                requests_per_day = $null; tokens_per_day = $null; level = 'OK'; confidence = ''; source = ''
            }
        }
        $model = $byModel[$modelName]
        if (-not (@($model.agents) -contains $name)) { $model.agents = @($model.agents) + @($name) }
        $model.runs += [int]$entry.runs
        $model.delegations += [int]$entry.delegations
        $model.duration_ms += [long]$entry.duration_ms
        if ($entry.tokens_estimated) {
            $model.tokens_estimated = $true
            $model.tokens += [int]$entry.tokens
        }
    }

    # --- warnings ---------------------------------------------------------
    $warnings = New-Object System.Collections.ArrayList
    foreach ($modelName in @($byModel.Keys)) {
        $model = $byModel[$modelName]
        $limitEntry = $null
        if ($budgetLimits.models.ContainsKey($modelName)) { $limitEntry = $budgetLimits.models[$modelName] }

        $requestsLimit = $null
        $tokensLimit = $null
        if ($null -ne $limitEntry) {
            $requestsLimit = $limitEntry.requests_per_day
            $tokensLimit = $limitEntry.tokens_per_day
            $model.confidence = [string]$limitEntry.confidence
            $model.source = [string]$limitEntry.source
        }
        $model.requests_per_day = $requestsLimit
        $model.tokens_per_day = $tokensLimit

        if (($null -ne $requestsLimit) -and ([int]$requestsLimit -gt 0)) {
            $ratio = [double]$model.runs / [double]$requestsLimit
            if ($ratio -ge 1.0) {
                $model.level = 'OVER'
                [void]$warnings.Add([ordered]@{
                    level = 'OVER'; scope = 'requests'; model = $modelName
                    used = [int]$model.runs; limit = [int]$requestsLimit; ratio = $ratio
                    message = ('requests {0}/{1} ({2}) - daily limit reached' -f $model.runs, $requestsLimit, (Format-BudgetPercent -Ratio $ratio))
                })
            } elseif ($ratio -ge $WarnAt) {
                $model.level = 'WARN'
                [void]$warnings.Add([ordered]@{
                    level = 'WARN'; scope = 'requests'; model = $modelName
                    used = [int]$model.runs; limit = [int]$requestsLimit; ratio = $ratio
                    message = ('requests {0}/{1} ({2}) - approaching the daily limit' -f $model.runs, $requestsLimit, (Format-BudgetPercent -Ratio $ratio))
                })
            }
        } else {
            [void]$notes.Add('no published request limit for ' + $modelName + ' (unknown, cannot warn)')
        }

        if ($model.tokens_estimated -and ($null -ne $tokensLimit) -and ([int]$tokensLimit -gt 0)) {
            $tokenRatio = [double]$model.tokens / [double]$tokensLimit
            if ($tokenRatio -ge 1.0) {
                if ($model.level -ne 'OVER') { $model.level = 'OVER' }
                [void]$warnings.Add([ordered]@{
                    level = 'OVER'; scope = 'tokens'; model = $modelName
                    used = [int]$model.tokens; limit = [int]$tokensLimit; ratio = $tokenRatio
                    message = ('tokens(est) {0}/{1} ({2}) - daily limit reached (estimate: evidence chars / 4)' -f $model.tokens, $tokensLimit, (Format-BudgetPercent -Ratio $tokenRatio))
                })
            } elseif ($tokenRatio -ge $WarnAt) {
                if ($model.level -eq 'OK') { $model.level = 'WARN' }
                [void]$warnings.Add([ordered]@{
                    level = 'WARN'; scope = 'tokens'; model = $modelName
                    used = [int]$model.tokens; limit = [int]$tokensLimit; ratio = $tokenRatio
                    message = ('tokens(est) {0}/{1} ({2}) - approaching the daily limit (estimate: evidence chars / 4)' -f $model.tokens, $tokensLimit, (Format-BudgetPercent -Ratio $tokenRatio))
                })
            }
        } elseif ($model.tokens_estimated) {
            [void]$notes.Add('no published token limit for ' + $modelName + ' (token figure stays an estimate)')
        }
    }

    $hasOver = (@($warnings | Where-Object { $_.level -eq 'OVER' }).Count -gt 0)
    $hasWarn = (@($warnings | Where-Object { $_.level -eq 'WARN' }).Count -gt 0)
    $overallLevel = 'OK'
    if ($hasOver) { $overallLevel = 'OVER' } elseif ($hasWarn) { $overallLevel = 'WARN' }
    if ($overallLevel -ne 'OK') { $exitCode = 2 }

    $totalRuns = 0
    $totalDelegations = 0
    $totalDuration = [long]0
    $totalTokens = 0
    foreach ($name in @($byAgent.Keys)) {
        $totalRuns += [int]$byAgent[$name].runs
        $totalDelegations += [int]$byAgent[$name].delegations
        $totalDuration += [long]$byAgent[$name].duration_ms
        $totalTokens += [int]$byAgent[$name].tokens
    }

    if ($Json) {
        $payload = [ordered]@{
            tool          = 'budget'
            generated_at  = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            root          = $budgetRootPath
            window        = [ordered]@{
                hours = $SinceHours
                since = $(if ($null -eq $cutoff) { '' } else { $cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) })
            }
            files         = [ordered]@{ traces = $sessionAgents.file; performance = $perfFile; limits = $budgetLimitsPath }
            limits_source = [string]$budgetLimits.source
            totals        = [ordered]@{
                runs             = $totalRuns
                delegations      = $totalDelegations
                duration_ms      = $totalDuration
                records          = @($perf.records).Count
                other_records    = $otherRecords
                broken_lines     = [int]$perf.broken_lines
                tokens_estimated = ($totalTokens -gt 0)
                tokens           = $totalTokens
            }
            by_agent      = @($byAgent.Keys | Sort-Object | ForEach-Object {
                $entry = $byAgent[$_]
                [ordered]@{
                    agent = [string]$entry.agent; runs = [int]$entry.runs; delegations = [int]$entry.delegations
                    duration_ms = [long]$entry.duration_ms; model = [string]$entry.model
                    tokens_estimated = [bool]$entry.tokens_estimated; tokens = [int]$entry.tokens
                }
            })
            by_model      = @($byModel.Keys | Sort-Object | ForEach-Object {
                $model = $byModel[$_]
                [ordered]@{
                    model = [string]$model.model; agents = @($model.agents); runs = [int]$model.runs
                    delegations = [int]$model.delegations; duration_ms = [long]$model.duration_ms
                    requests_per_day = $model.requests_per_day; tokens_per_day = $model.tokens_per_day
                    tokens_estimated = [bool]$model.tokens_estimated; tokens = [int]$model.tokens
                    level = [string]$model.level; confidence = [string]$model.confidence; source = [string]$model.source
                }
            })
            warnings      = @($warnings | ForEach-Object { [ordered]@{
                level = [string]$_.level; scope = [string]$_.scope; model = [string]$_.model
                used = [int]$_.used; limit = [int]$_.limit; ratio = [math]::Round([double]$_.ratio, 4); message = [string]$_.message
            } })
            overall_level = $overallLevel
            exit_code     = $exitCode
            notes         = @($notes)
        }
        Write-Output (ConvertTo-BudgetJson -InputObject $payload -Depth 8)
    } else {
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('=== agent-hq budget ===')
        [void]$lines.Add('root    : ' + $budgetRootPath)
        [void]$lines.Add('window  : last ' + $SinceHours + 'h' + $(if ($null -eq $cutoff) { ' (unbounded)' } else { ' (since ' + $cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) + ')' }))
        [void]$lines.Add('traces  : ' + $sessionAgents.file)
        [void]$lines.Add('perf    : ' + $perfFile)
        [void]$lines.Add('limits  : ' + $budgetLimitsPath + ' (' + $budgetLimits.source + ')')
        [void]$lines.Add('')
        [void]$lines.Add(('totals  : runs=' + $totalRuns + ' delegations=' + $totalDelegations + ' duration=' + (Format-BudgetDuration -Ms $totalDuration) + ' tokens(est)=' + $(if ($totalTokens -gt 0) { $totalTokens } else { 'n/a' })))
        [void]$lines.Add('')
        [void]$lines.Add('--- by agent ---')
        if ($byAgent.Count -eq 0) {
            [void]$lines.Add('  no sessions in the selected window')
        } else {
            [void]$lines.Add(('{0,-20} {1,5} {2,6} {3,10}  {4,-32} {5}' -f 'AGENT', 'RUNS', 'DELEG', 'DURATION', 'MODEL', 'TOKENS(est)'))
            foreach ($name in @($byAgent.Keys | Sort-Object)) {
                $entry = $byAgent[$name]
                [void]$lines.Add(('{0,-20} {1,5} {2,6} {3,10}  {4,-32} {5}' -f $entry.agent, $entry.runs, $entry.delegations,
                    (Format-BudgetDuration -Ms ([long]$entry.duration_ms)),
                    $(if ([string]::IsNullOrWhiteSpace([string]$entry.model)) { '-' } else { [string]$entry.model }),
                    $(if ($entry.tokens_estimated) { [string]$entry.tokens } else { 'n/a' })))
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add('--- by model ---')
        if ($byModel.Count -eq 0) {
            [void]$lines.Add('  no model usage in the selected window')
        } else {
            [void]$lines.Add(('{0,-32} {1,5} {2,12} {3,10}  {4}' -f 'MODEL', 'RUNS', 'REQ USED', 'TOKENS(est)', 'LEVEL'))
            foreach ($modelName in @($byModel.Keys | Sort-Object)) {
                $model = $byModel[$modelName]
                $requestText = '-'
                if (($null -ne $model.requests_per_day) -and ([int]$model.requests_per_day -gt 0)) {
                    $requestText = ('{0}/{1}' -f $model.runs, $model.requests_per_day)
                }
                $tokenText = '-'
                if ($model.tokens_estimated) { $tokenText = [string]$model.tokens }
                [void]$lines.Add(('{0,-32} {1,5} {2,12} {3,10}  {4}' -f $modelName, $model.runs, $requestText, $tokenText, $model.level))
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add(('--- warnings (' + $warnings.Count + ') ---'))
        if ($warnings.Count -eq 0) {
            [void]$lines.Add('  none - within limits')
        } else {
            foreach ($warning in $warnings) { [void]$lines.Add(('  {0}: {1}' -f $warning.level, $warning.message)) }
        }
        if ($notes.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('--- notes ---')
            foreach ($note in $notes) { [void]$lines.Add('  ' + $note) }
        }
        [void]$lines.Add('')
        [void]$lines.Add('BUDGET: ' + $overallLevel)
        Write-Output ($lines -join "`r`n")
    }
} catch {
    Write-Output ('budget: internal error: ' + $_.Exception.Message)
    $exitCode = 1
}

exit $exitCode
