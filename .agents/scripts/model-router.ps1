<#
.SYNOPSIS
    Model router for the agent-hq fleet: health probe, circuit breaker, fallback ladder.
.DESCRIPTION
    The opencode free tier is periodically exhausted ("Free usage exceeded,
    subscribe to Go"), tokenrouter is dead ($0) and single models return
    "No available channel". Substituting models by hand does not scale, so this
    router does it from a health state file:

      .memory/model-health.json
        <model-id> => { model, status, checked_at, fail_count, open_until }

    Test-ModelHealth runs `opencode run --model <id> "Reply with exactly: PONG"`
    and classifies the outcome as OK / RATE_LIMIT / DEAD / TIMEOUT. Every
    non-OK outcome increments fail_count; after -FailThreshold consecutive
    failures (default 2) the model is marked OPEN until now + -CooldownMinutes
    (default 15). Get-ModelRoute walks the agent's configured model and then the
    fallback ladder from .agents/skills/model-router/SKILL.md (free -> 
    aihubmix/gpt-5.5-free -> senior opencode-go/qwen3.8-flash) and returns the
    first candidate whose breaker is CLOSED.

    Nothing is written to the agent config unless -Apply is passed; even then a
    timestamped backup of the agent JSON is created first and sync-agents.ps1
    runs afterwards. If sync-agents.ps1 fails, the agent file is rolled back.

    Environment hooks (used by tests, ignored in normal operation):
      $env:AGENT_HQ_ROOT      - repository root override
      $env:AGENT_HQ_OPENCODE  - CLI path override (fake CLI in tests)

    Deliberately NO param() block: this file is dot-sourced by
    tests/test-model-router.ps1, and a param() block would overwrite the
    caller's variables ($Root / $Agent / ...) - a well-known PowerShell 5.1
    dot-source gotcha. The command line is therefore parsed from $args inside
    the direct-invocation branch only, and dot-sourcing just defines functions.

.PARAMETER Status
    Print the health/breaker table from .memory/model-health.json.
.PARAMETER Probe
    Probe the candidate set from the model-router SKILL (or -Models) and refresh state.
.PARAMETER Route
    Resolve the model for -Agent (never writes unless -Apply is also given).
.PARAMETER Agent
    Agent name used with -Route (and with -Apply).
.PARAMETER Apply
    With -Route: write the routed model into .opencode\agents\<agent>.json and run sync-agents.ps1.
.PARAMETER Models
    Comma separated model list for -Probe (overrides the built-in candidate set).
.PARAMETER FailThreshold
    Consecutive failures before the breaker opens (default 2).
.PARAMETER CooldownMinutes
    How long an OPEN breaker stays open (default 15).
.PARAMETER TimeoutSec
    Per-probe CLI timeout in seconds (default 60).
.EXAMPLE
    .\model-router.ps1 -Status
.EXAMPLE
    .\model-router.ps1 -Probe -TimeoutSec 30
.EXAMPLE
    .\model-router.ps1 -Route -Agent qa-engineer
.EXAMPLE
    .\model-router.ps1 -Route -Agent qa-engineer -Apply
#>

$script:ModelHealthFileName   = "model-health.json"
$script:DefaultFailThreshold  = 2
$script:DefaultCooldownMinutes = 15
$script:DefaultTimeoutSec     = 60
$script:RuntimeConfigTimeoutSec = 15

# Fallback ladder per .agents/skills/model-router/SKILL.md (state of 2026-09-15):
# free checkers first, then the aihubmix free endpoint, then the paid senior.
$script:FallbackLadder = @(
    "opencode/ling-3.0-flash-fin-free",
    "opencode/mimo-v2.5-free",
    "opencode/big-pickle",
    "opencode/nemotron-3.5-lightning-free",
    "aihubmix/coding-glm-5.1-free",
    "aihubmix/gpt-5.5-free",
    "opencode-go/qwen3.8-flash"
)

# Candidate set from the same SKILL: every model the fleet actually runs on.
$script:ProbeCandidates = @(
    "opencode-go/deepseek-v4.1-flash",
    "opencode-go/qwen3.8-flash",
    "opencode/big-pickle",
    "opencode/ling-3.0-flash-fin-free",
    "opencode/mimo-v2.5-free",
    "opencode/nemotron-3.5-lightning-free",
    "aihubmix/coding-glm-5.1-free",
    "aihubmix/gpt-5.5-free"
)

$script:ProbePrompt = "Reply with exactly: PONG"

# ===========================================================================
# Path / CLI resolution
# ===========================================================================

function Get-RouterRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-ModelHealthPath {
    param([string]$Root)
    return (Join-Path (Get-RouterRoot -Root $Root) (".memory\" + $script:ModelHealthFileName))
}

function Get-AgentFilePath {
    param([string]$Agent, [string]$Root)
    if ($Agent -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return "" }
    return (Join-Path (Get-RouterRoot -Root $Root) (".opencode\agents\" + $Agent + ".json"))
}

function Resolve-ModelCli {
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_OPENCODE)) { return $env:AGENT_HQ_OPENCODE }
    return "opencode"
}

# ===========================================================================
# Timestamps (PS 5.1 safe: invariant format, explicit parse)
# ===========================================================================

function Format-RouterTimestamp {
    param([datetime]$Value)
    return $Value.ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-RouterDate {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Text.Trim(),
        "yyyy-MM-ddTHH:mm:ss",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed)
    if ($ok) { return $parsed }
    $ok2 = [datetime]::TryParse($Text.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if ($ok2) { return $parsed }
    return $null
}

# ===========================================================================
# Health state (.memory/model-health.json)
# ===========================================================================

function Read-ModelHealthState {
    param([string]$Root)
    $state = @{}
    $path = Get-ModelHealthPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $state }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $json = $raw | ConvertFrom-Json
        foreach ($property in @($json.PSObject.Properties)) {
            $entry = $property.Value
            $model = if ($entry.model) { [string]$entry.model } else { [string]$property.Name }
            $status = [string]$entry.status
            $checkedAt = [string]$entry.checked_at
            $failCount = 0
            if ($null -ne $entry.fail_count) { $failCount = [int]$entry.fail_count }
            $openUntil = ""
            if ($null -ne $entry.open_until) { $openUntil = [string]$entry.open_until }
            $state[$model] = [pscustomobject]@{
                model      = $model
                status     = $status
                checked_at = $checkedAt
                fail_count = $failCount
                open_until = $openUntil
            }
        }
    } catch {
        Write-Warning "model-health state is unreadable ($path): $($_.Exception.Message) - starting from an empty state"
        $state = @{}
    }
    return $state
}

function Save-ModelHealthState {
    param([hashtable]$State, [string]$Root)
    $path = Get-ModelHealthPath -Root $Root
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $ordered = [ordered]@{}
    foreach ($key in @($State.Keys | Sort-Object)) { $ordered[$key] = $State[$key] }
    $json = ConvertTo-Json -InputObject $ordered -Depth 6
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-ModelHealthEntry {
    param([Parameter(Mandatory = $true)][string]$Model, [string]$Root)
    $state = Read-ModelHealthState -Root $Root
    if ($state.Contains($Model)) { return $state[$Model] }
    return $null
}

# Circuit breaker: $true while the model is parked after too many failures.
function Test-ModelOpen {
    param([Parameter(Mandatory = $true)][string]$Model, [string]$Root)
    $entry = Get-ModelHealthEntry -Model $Model -Root $Root
    if ($null -eq $entry) { return $false }
    $until = ConvertTo-RouterDate -Text ([string]$entry.open_until)
    if ($null -eq $until) { return $false }
    return ($until -gt (Get-Date))
}

function Set-ModelHealthResult {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Status,
        [int]$FailThreshold = 0,
        [int]$CooldownMinutes = 0,
        [string]$Root
    )
    if ($FailThreshold -le 0) { $FailThreshold = $script:DefaultFailThreshold }
    if ($CooldownMinutes -le 0) { $CooldownMinutes = $script:DefaultCooldownMinutes }

    $state = Read-ModelHealthState -Root $Root
    $previous = $null
    if ($state.Contains($Model)) { $previous = $state[$Model] }

    $failCount = 0
    if ($null -ne $previous) { $failCount = [int]$previous.fail_count }

    # Half-open semantics: an expired cooldown grants a clean probe. A success
    # closes the breaker, the next failure opens it again immediately.
    if ($null -ne $previous) {
        $previousUntil = ConvertTo-RouterDate -Text ([string]$previous.open_until)
        if (($null -ne $previousUntil) -and ($previousUntil -le (Get-Date))) { $failCount = 0 }
    }

    $openUntil = ""
    if ($Status -eq "OK") {
        $failCount = 0
    } else {
        $failCount = $failCount + 1
        if ($failCount -ge $FailThreshold) {
            $openUntil = Format-RouterTimestamp ((Get-Date).AddMinutes($CooldownMinutes))
        }
    }

    $record = [pscustomobject]@{
        model      = $Model
        status     = $Status
        checked_at = Format-RouterTimestamp (Get-Date)
        fail_count = $failCount
        open_until = $openUntil
    }
    $state[$Model] = $record
    [void](Save-ModelHealthState -State $state -Root $Root)
    return $record
}

# ===========================================================================
# CLI probe (background job so a hung CLI becomes TIMEOUT, not a stuck router)
# ===========================================================================

function Invoke-CliProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [int]$TimeoutSec = 0,
        [string]$Cli
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:DefaultTimeoutSec }
    if ([string]::IsNullOrWhiteSpace($Cli)) { $Cli = Resolve-ModelCli }

    $job = Start-Job -ScriptBlock {
        param($cli, $model, $prompt)
        $errorFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & $cli run --model $model $prompt 2>$errorFile
            $exitCode = $LASTEXITCODE
            $stderr = ""
            if (Test-Path -LiteralPath $errorFile) { $stderr = [System.IO.File]::ReadAllText($errorFile) }
            [pscustomobject]@{
                stdout   = (@($stdout) -join "`n")
                stderr   = $stderr
                exitCode = $exitCode
                timedOut = $false
            }
        } catch {
            [pscustomobject]@{
                stdout   = ""
                stderr   = $_.Exception.Message
                exitCode = -1
                timedOut = $false
            }
        } finally {
            Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $Cli, $Model, $script:ProbePrompt

    $completed = Wait-Job -Job $job -Timeout $TimeoutSec
    if ($null -eq $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ stdout = ""; stderr = ""; exitCode = -1; timedOut = $true }
    }

    $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $probe = $null
    foreach ($item in @($received)) {
        if (($null -ne $item) -and ($null -ne $item.PSObject.Properties["exitCode"])) { $probe = $item }
    }
    if ($null -eq $probe) {
        return [pscustomobject]@{ stdout = (@($received) -join "`n"); stderr = ""; exitCode = 0; timedOut = $false }
    }
    return $probe
}

function Get-ProbeStatus {
    param([string]$Stdout, [string]$Stderr, [int]$ExitCode, [bool]$TimedOut)
    if ($TimedOut) { return "TIMEOUT" }
    $text = ([string]$Stdout + "`n" + [string]$Stderr)
    if ($text -match '(?i)free usage exceeded|rate limit|rate_limit|too many requests|quota exceeded|\b429\b') { return "RATE_LIMIT" }
    if ($text -match '(?i)no available channel|credit insufficient|insufficient credit|unknownerror') { return "DEAD" }
    if ($text -match '(?i)\bPONG\b') { return "OK" }
    return "DEAD"
}

function Test-ModelHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [int]$TimeoutSec = 0,
        [int]$FailThreshold = 0,
        [int]$CooldownMinutes = 0,
        [string]$Root,
        [string]$Cli
    )
    $probe = Invoke-CliProbe -Model $Model -TimeoutSec $TimeoutSec -Cli $Cli
    $status = Get-ProbeStatus -Stdout $probe.stdout -Stderr $probe.stderr -ExitCode ([int]$probe.exitCode) -TimedOut ([bool]$probe.timedOut)
    $record = Set-ModelHealthResult -Model $Model -Status $status -FailThreshold $FailThreshold -CooldownMinutes $CooldownMinutes -Root $Root

    return [pscustomobject]@{
        model      = $record.model
        status     = $record.status
        checked_at = $record.checked_at
        fail_count = $record.fail_count
        open_until = $record.open_until
        exit_code  = [int]$probe.exitCode
        timed_out  = [bool]$probe.timedOut
    }
}

function Format-ProbeLine {
    param($Result)
    $breaker = "closed"
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.open_until)) { $breaker = "OPEN until " + [string]$Result.open_until }
    return ("{0,-45} {1,-11} fails={2} breaker={3}" -f [string]$Result.model, [string]$Result.status, [int]$Result.fail_count, $breaker)
}

# ===========================================================================
# Routing
# ===========================================================================

# Runtime resolved config (`opencode debug config`) -> agent.<name>.model.
# Bounded by its own job timeout so a hung CLI cannot block the router.
function Get-RuntimeConfigModel {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [string]$Root,
        [int]$TimeoutSec = 0
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:RuntimeConfigTimeoutSec }
    $cli = Resolve-ModelCli
    $workingDir = Get-RouterRoot -Root $Root

    $job = Start-Job -ScriptBlock {
        param($cliPath, $cwd)
        Push-Location -LiteralPath $cwd
        try {
            $text = (& $cliPath debug config 2>$null | Out-String)
            $code = $LASTEXITCODE
        } catch {
            $text = ""
            $code = -1
        } finally {
            Pop-Location
        }
        [pscustomobject]@{ text = $text; exitCode = $code }
    } -ArgumentList $cli, $workingDir

    $completed = Wait-Job -Job $job -Timeout $TimeoutSec
    if ($null -eq $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return ""
    }
    $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $text = ""
    foreach ($item in @($received)) {
        if (($null -ne $item) -and ($null -ne $item.PSObject.Properties["text"])) { $text = [string]$item.text }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }

    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { return "" }
    if ($null -eq $json) { return "" }
    $agentMap = $json.agent
    if ($null -eq $agentMap) { return "" }
    $agentProperty = $agentMap.PSObject.Properties[$Agent]
    if ($null -eq $agentProperty) { return "" }
    $agentEntry = $agentProperty.Value
    if (($null -ne $agentEntry) -and ($null -ne $agentEntry.model)) { return [string]$agentEntry.model }
    return ""
}

# Source of truth for the configured model is .opencode\agents\<agent>.json
# (model-router SKILL: source -> sync-agents.ps1 -> opencode.json). The runtime
# config is the fallback for agents that only exist in the resolved config.
function Get-AgentConfiguredModel {
    param([Parameter(Mandatory = $true)][string]$Agent, [string]$Root)
    $agentFile = Get-AgentFilePath -Agent $Agent -Root $Root
    if (-not [string]::IsNullOrWhiteSpace($agentFile) -and (Test-Path -LiteralPath $agentFile -PathType Leaf)) {
        try {
            $raw = [System.IO.File]::ReadAllText($agentFile, [System.Text.Encoding]::UTF8)
            $json = $raw | ConvertFrom-Json
            if (($null -ne $json.model) -and ([string]$json.model).Trim().Length -gt 0) { return [string]$json.model }
        } catch {
            Write-Warning "Cannot parse agent file ${agentFile}: $($_.Exception.Message)"
        }
    }
    return (Get-RuntimeConfigModel -Agent $Agent -Root $Root)
}

# Configured model first, then the SKILL ladder (duplicates removed).
function Get-FallbackLadder {
    param([Parameter(Mandatory = $true)][string]$Model)
    $ladder = New-Object System.Collections.ArrayList
    [void]$ladder.Add($Model)
    foreach ($candidate in $script:FallbackLadder) {
        if (-not $ladder.Contains($candidate)) { [void]$ladder.Add($candidate) }
    }
    return $ladder.ToArray()
}

function Get-ModelRoute {
    param([Parameter(Mandatory = $true)][string]$Agent, [string]$Root)
    $configured = Get-AgentConfiguredModel -Agent $Agent -Root $Root
    if ([string]::IsNullOrWhiteSpace($configured)) {
        return [pscustomobject]@{
            agent      = $Agent
            configured = ""
            model      = ""
            changed    = $false
            reason     = "agent-model-unknown"
        }
    }

    $ladder = Get-FallbackLadder -Model $configured
    $chosen = ""
    $reason = "configured-healthy"
    foreach ($candidate in $ladder) {
        if (-not (Test-ModelOpen -Model $candidate -Root $Root)) {
            $chosen = $candidate
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($chosen)) {
        $chosen = [string]$ladder[$ladder.Count - 1]
        $reason = "all-candidates-open"
    } elseif ($chosen -ne $configured) {
        $reason = "configured-open-fallback"
    }

    return [pscustomobject]@{
        agent      = $Agent
        configured = $configured
        model      = $chosen
        changed    = ($chosen -ne $configured)
        reason     = $reason
    }
}

# Write the routed model into .opencode\agents\<agent>.json (first "model" key
# only, indentation preserved) and sync the runtime config afterwards.
function Set-AgentModel {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Root
    )
    $agentFile = Get-AgentFilePath -Agent $Agent -Root $Root
    if ([string]::IsNullOrWhiteSpace($agentFile) -or -not (Test-Path -LiteralPath $agentFile -PathType Leaf)) {
        return [pscustomobject]@{ ok = $false; file = $agentFile; backup = ""; synced = $false; changed = $false; error = "agent file not found: $agentFile" }
    }

    $raw = [System.IO.File]::ReadAllText($agentFile, [System.Text.Encoding]::UTF8)
    $pattern = '(?m)^(\s*"model"\s*:\s*)"([^"]*)"'
    $match = [regex]::Match($raw, $pattern)
    if (-not $match.Success) {
        return [pscustomobject]@{ ok = $false; file = $agentFile; backup = ""; synced = $false; changed = $false; error = "no top-level model field in $agentFile" }
    }
    if ($match.Groups[2].Value -eq $Model) {
        return [pscustomobject]@{ ok = $true; file = $agentFile; backup = ""; synced = $false; changed = $false; error = "" }
    }

    $backup = $agentFile + ".bak." + (Get-Date -Format "yyyyMMdd-HHmmss")
    try {
        Copy-Item -LiteralPath $agentFile -Destination $backup -Force
    } catch {
        return [pscustomobject]@{ ok = $false; file = $agentFile; backup = ""; synced = $false; changed = $false; error = "backup failed: $($_.Exception.Message)" }
    }

    $targetModel = $Model
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        return $m.Groups[1].Value + '"' + $targetModel + '"'
    }
    try {
        $updated = [regex]::Replace($raw, $pattern, $evaluator)
        [System.IO.File]::WriteAllText($agentFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Copy-Item -LiteralPath $backup -Destination $agentFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ok = $false; file = $agentFile; backup = $backup; synced = $false; changed = $false; error = "write failed: $($_.Exception.Message)" }
    }

    $syncScript = Join-Path (Get-RouterRoot -Root $Root) ".agents\scripts\sync-agents.ps1"
    $synced = $false
    if (Test-Path -LiteralPath $syncScript -PathType Leaf) {
        & $syncScript
        $syncExit = $LASTEXITCODE
        if ($syncExit -ne 0) {
            Copy-Item -LiteralPath $backup -Destination $agentFile -Force
            return [pscustomobject]@{ ok = $false; file = $agentFile; backup = $backup; synced = $false; changed = $false; error = "sync-agents.ps1 exited $syncExit - agent file rolled back" }
        }
        $synced = $true
    } else {
        Write-Warning "sync-agents.ps1 not found under $(Get-RouterRoot -Root $Root) - agent file updated, opencode.json NOT synced"
    }

    return [pscustomobject]@{ ok = $true; file = $agentFile; backup = $backup; synced = $synced; changed = $true; error = "" }
}

# ===========================================================================
# Status table
# ===========================================================================

function Show-ModelStatus {
    param([string]$Root)
    $state = Read-ModelHealthState -Root $Root
    $path = Get-ModelHealthPath -Root $Root
    Write-Host ""
    Write-Host "MODEL HEALTH" -ForegroundColor Cyan
    Write-Host ("state : " + $path)
    if ($state.Count -eq 0) {
        Write-Host "no records yet - run -Probe to populate the state" -ForegroundColor Yellow
        return
    }
    $now = Get-Date
    $rows = @()
    foreach ($key in @($state.Keys | Sort-Object)) {
        $entry = $state[$key]
        $until = ConvertTo-RouterDate -Text ([string]$entry.open_until)
        $breaker = "closed"
        $openUntilText = "-"
        if (($null -ne $until) -and ($until -gt $now)) {
            $breaker = "OPEN"
            $openUntilText = $until.ToString("HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $rows += [pscustomobject]@{
            MODEL      = [string]$entry.model
            STATUS     = [string]$entry.status
            BREAKER    = $breaker
            FAILS      = [int]$entry.fail_count
            CHECKED_AT = [string]$entry.checked_at
            OPEN_UNTIL = $openUntilText
        }
    }
    $rows | Format-Table -AutoSize
}

# ===========================================================================
# Command line (parsed from $args only when invoked directly)
# ===========================================================================

function Show-ModelRouterUsage {
    Write-Host ""
    Write-Host "model-router.ps1 - model health, circuit breaker and fallback routing" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -Status                        print the health/breaker table"
    Write-Host "  -Probe                         probe the SKILL candidate set and refresh state"
    Write-Host "  -Route -Agent <name>       resolve the model for one agent (read-only)"
    Write-Host "  -Route -Agent <name> -Apply  write the routed model + sync-agents.ps1"
    Write-Host "  -Models a,b                candidate override for -Probe"
    Write-Host "  -FailThreshold <n>         failures before the breaker opens (default 2)"
    Write-Host "  -CooldownMinutes <n>       how long the breaker stays open (default 15)"
    Write-Host "  -TimeoutSec <n>            per-probe timeout (default 60)"
    Write-Host ""
}

function Parse-ModelRouterArguments {
    param([object[]]$Arguments)
    $options = @{
        Help            = $false
        Probe           = $false
        Status          = $false
        Route           = $false
        Apply           = $false
        Agent           = ""
        Root            = ""
        Models          = @()
        FailThreshold   = $script:DefaultFailThreshold
        CooldownMinutes = $script:DefaultCooldownMinutes
        TimeoutSec      = $script:DefaultTimeoutSec
    }
    if ($null -eq $Arguments) { $Arguments = @() }

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $name = $token
        $inlineValue = $null
        if ($token -match '^-([A-Za-z]+):(.*)$') {
            $name = "-" + $Matches[1]
            $inlineValue = $Matches[2]
        }

        if ($name -eq "-Status") { $options.Status = $true; $index++ }
        elseif ($name -eq "-Probe") { $options.Probe = $true; $index++ }
        elseif ($name -eq "-Route") { $options.Route = $true; $index++ }
        elseif ($name -eq "-Apply") { $options.Apply = $true; $index++ }
        elseif ($name -eq "-Help") { $options.Help = $true; $index++ }
        elseif (@("-Agent", "-Root", "-Models", "-FailThreshold", "-CooldownMinutes", "-TimeoutSec") -contains $name) {
            $value = $inlineValue
            if ($null -eq $value) {
                if (($index + 1) -ge $Arguments.Count) { throw "Missing value for $name" }
                $value = [string]$Arguments[$index + 1]
                $index = $index + 2
            } else {
                $index++
            }
            if ($name -eq "-Agent") { $options.Agent = $value }
            elseif ($name -eq "-Root") { $options.Root = $value }
            elseif ($name -eq "-Models") { $options.Models = @($value -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
            elseif ($name -eq "-FailThreshold") { $options.FailThreshold = [int]$value }
            elseif ($name -eq "-CooldownMinutes") { $options.CooldownMinutes = [int]$value }
            elseif ($name -eq "-TimeoutSec") { $options.TimeoutSec = [int]$value }
        }
        else {
            throw "Unknown argument '$token'. Usage: -Status | -Probe | -Route -Agent <name> [-Apply]"
        }
    }
    return $options
}

function Invoke-ModelRouterCommandLine {
    param([object[]]$Arguments)

    $options = $null
    try {
        $options = Parse-ModelRouterArguments -Arguments $Arguments
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-ModelRouterUsage
        exit 1
    }

    if ($options.Help -or ((-not $options.Probe) -and (-not $options.Status) -and (-not $options.Route))) {
        Show-ModelRouterUsage
        exit 0
    }

    $root = $options.Root

    if ($options.Status) {
        Show-ModelStatus -Root $root
    }

    if ($options.Probe) {
        $candidates = $script:ProbeCandidates
        if ($options.Models.Count -gt 0) { $candidates = $options.Models }
        Write-Host ""
        Write-Host ("Probing " + $candidates.Count + " candidate(s), timeout " + $options.TimeoutSec + "s each") -ForegroundColor Cyan
        foreach ($model in $candidates) {
            $result = Test-ModelHealth -Model $model -TimeoutSec $options.TimeoutSec -FailThreshold $options.FailThreshold -CooldownMinutes $options.CooldownMinutes -Root $root
            Write-Host ("  " + (Format-ProbeLine -Result $result))
        }
    }

    if ($options.Route) {
        if ([string]::IsNullOrWhiteSpace($options.Agent)) {
            Write-Host "-Route requires -Agent <name>" -ForegroundColor Red
            exit 1
        }
        $route = Get-ModelRoute -Agent $options.Agent -Root $root
        Write-Host ""
        Write-Host ("AGENT      : " + $route.agent)
        Write-Host ("CONFIGURED : " + $route.configured)
        Write-Host ("ROUTE      : " + $route.model)
        Write-Host ("REASON     : " + $route.reason)

        if (-not $options.Apply) {
            Write-Host "APPLY      : skipped (pass -Apply to write into .opencode\agents and sync)"
        } elseif (-not $route.changed) {
            Write-Host "APPLY      : not needed - configured model is healthy"
        } else {
            $applied = Set-AgentModel -Agent $route.agent -Model $route.model -Root $root
            if ($applied.ok) {
                Write-Host ("APPLY      : " + $route.agent + " -> " + $route.model + " (" + $applied.file + ", backup " + $applied.backup + ", synced=" + $applied.synced + ")")
            } else {
                Write-Host ("APPLY      : FAILED - " + $applied.error) -ForegroundColor Red
                exit 1
            }
        }
    }

    exit 0
}

# Only a direct invocation (.\model-router.ps1 ...) runs the CLI; dot-sourcing
# (tests) merely loads the functions above.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ModelRouterCommandLine -Arguments $args
}
