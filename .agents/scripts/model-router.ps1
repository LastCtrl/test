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

    P3 - capability passport. Get-RouteDecision replaces the bare ladder walk: it
    loads the passport through capability-passport.ps1 (lazily, a missing or
    broken passport only degrades the decision) and rejects candidates that are
    OPEN (breaker), that do not cover -TaskType (capability-mismatch) or that
    cost more than -MaxCostTier. The decision keeps a machine code in reason, the
    explanation in reason_text and the per-candidate codes, cost tier, grades and
    measured latency in candidates. Speed and reliability rank candidates only
    with -Optimize; otherwise a viable configured model always wins, so default
    routing stays stable. Get-ModelRoute is a thin wrapper keeping the pre-P3
    fields and reason codes for the regression tests.

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

# Passport scoring weights (documented so a reason string can be reproduced).
$script:RouterPassportModuleFile = "capability-passport.ps1"
$script:RouterCostTierRank = @{ "free" = 0; "medium" = 1; "paid" = 2; "unknown" = 2 }
$script:RouterSpeedReferenceMs = 600000.0
$script:RouterWeights = @{ reliability = 0.5; speed = 0.2; cost = 0.3 }

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

# BUG-024: every router process (CLI invocations, probes, later the daemon)
# shares .memory\model-health.json, so the read-modify-write in
# Set-ModelHealthResult has to be serialized. The lock is an exclusive handle
# (FileShare::None) on "<state>.lock": a second opener gets a sharing violation
# and retries until -LockTimeoutMs. When the lock cannot be taken the action
# still runs (fail-open + warning): losing one probe result is preferable to
# hanging the router or the daemon.
function Get-ModelHealthLockPath {
    param([string]$Root)
    return ((Get-ModelHealthPath -Root $Root) + ".lock")
}

function Invoke-ModelHealthLocked {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Root,
        [int]$LockTimeoutMs = 5000
    )
    $lockPath = Get-ModelHealthLockPath -Root $Root
    $lockDir = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $lockDir -PathType Container)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }

    $handle = $null
    $deadline = (Get-Date).AddMilliseconds($LockTimeoutMs)
    while ($null -eq $handle) {
        try {
            $handle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            # PowerShell wraps the .NET exception, so both levels are inspected:
            # only contention is worth retrying, anything else (ACL, AV) would
            # just spin until the deadline.
            $inner = $_.Exception.InnerException
            $isContention = ($_.Exception -is [System.IO.IOException]) -or (($null -ne $inner) -and ($inner -is [System.IO.IOException]))
            if ((-not $isContention) -or ((Get-Date) -ge $deadline)) {
                Write-Warning "model-health lock not acquired ($lockPath): $($_.Exception.Message) - continuing without an exclusive lock"
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }

    try {
        return & $Action
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
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

    # BUG-024: the state file is never truncated in place - a sibling temp file is
    # written first and then swapped in (ReplaceFile/MoveFileEx), so a concurrent
    # reader sees either the old or the new document, never a half-written one.
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tmpPath = Join-Path $dir ("." + (Split-Path -Leaf $path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = $path + ".bak." + [guid]::NewGuid().ToString("N")
    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        # A reader holding the destination open can make the swap fail transiently.
        $swapped = $false
        foreach ($attempt in 1..5) {
            try {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    [System.IO.File]::Replace($tmpPath, $path, $backupPath)
                } else {
                    [System.IO.File]::Move($tmpPath, $path)
                }
                $swapped = $true
                break
            } catch {
                if ($attempt -eq 5) {
                    Write-Warning "cannot swap in model-health state ${path}: $($_.Exception.Message)"
                } else {
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        if (-not $swapped) {
            # Last resort: keep the probe result instead of silently dropping it.
            try {
                [System.IO.File]::WriteAllText($path, $json, $encoding)
            } catch {
                Write-Warning "cannot write model-health state ${path}: $($_.Exception.Message)"
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
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
        [string]$Root,
        [int]$LockTimeoutMs = 5000
    )
    if ($FailThreshold -le 0) { $FailThreshold = $script:DefaultFailThreshold }
    if ($CooldownMinutes -le 0) { $CooldownMinutes = $script:DefaultCooldownMinutes }

    # BUG-024: read-modify-write runs under a cross-process lock; the state is
    # re-read inside the lock, so two concurrent probes merge instead of the
    # last writer dropping the other model's record (lost update -> fail-open).
    $record = Invoke-ModelHealthLocked -Root $Root -LockTimeoutMs $LockTimeoutMs -Action {
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

        $entry = [pscustomobject]@{
            model      = $Model
            status     = $Status
            checked_at = Format-RouterTimestamp (Get-Date)
            fail_count = $failCount
            open_until = $openUntil
        }
        $state[$Model] = $entry
        [void](Save-ModelHealthState -State $state -Root $Root)
        return $entry
    }
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
    return (Get-RouteDecision -Agent $Agent -Root $Root)
}

# ===========================================================================
# Passport-aware, explainable routing (P3)
# ===========================================================================

function Resolve-PassportModulePath {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidate = Join-Path $PSScriptRoot $script:RouterPassportModuleFile
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $fallback = Join-Path (Get-RouterRoot -Root $Root) (".agents\scripts\" + $script:RouterPassportModuleFile)
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return ""
}

$script:PassportLoaded = $false
$script:PassportLoadNote = ""

# The passport module is loaded here, in the script scope: dot-sourcing inside a
# function would define its functions in the function scope only, so they would
# be gone once that function returns. A missing or damaged module is not fatal -
# routing then falls back to health only and reports the note.
function Initialize-PassportModule {
    param([string]$Root)
    if (Get-Command Get-AgentPassport -ErrorAction SilentlyContinue) { return $true }
    if ([string]::IsNullOrWhiteSpace($script:PassportLoadNote)) {
        $script:PassportLoadNote = "capability-passport.ps1 is not loaded - routed on health only"
    }
    return $false
}

function Import-PassportModule {
    param([string]$Root)
    $script:PassportLoaded = $false
    if (Get-Command Get-AgentPassport -ErrorAction SilentlyContinue) {
        $script:PassportLoaded = $true
        return $true
    }
    return $false
}

function Get-PassportDataStatus {
    param([string]$Root)
    if (-not (Get-Command Read-PassportDocument -ErrorAction SilentlyContinue)) {
        return [ordered]@{ status = "module-missing"; note = "" }
    }
    $doc = Read-PassportDocument -Root $Root
    if ($doc.ok) { return [ordered]@{ status = "ok"; note = "" } }
    $status = "broken"
    if ([string]$doc.error -match "not found") { $status = "missing" }
    return [ordered]@{ status = $status; note = [string]$doc.error }
}

function Get-RouteCandidateMetrics {
    param($ModelPassport)
    $metrics = [ordered]@{
        cost_tier = "unknown"
        avg_grade = $null
        samples   = 0
        p50_ms    = $null
    }
    if ($null -eq $ModelPassport) { return $metrics }
    if ($null -ne $ModelPassport["cost_tier"]) {
        $tier = [string]$ModelPassport["cost_tier"]
        if (-not [string]::IsNullOrWhiteSpace($tier)) { $metrics.cost_tier = $tier }
    }
    $reliability = $ModelPassport["reliability"]
    if ($reliability -is [System.Collections.IDictionary]) {
        if ($null -ne $reliability["avg_grade"]) { $metrics.avg_grade = $reliability["avg_grade"] }
        if ($null -ne $reliability["samples"]) { $metrics.samples = [int]$reliability["samples"] }
    }
    $speed = $ModelPassport["speed"]
    if ($speed -is [System.Collections.IDictionary]) {
        if ($null -ne $speed["p50_ms"]) { $metrics.p50_ms = $speed["p50_ms"] }
    }
    return $metrics
}

function Get-CandidateRejections {
    param([string]$Model, [string]$TaskType, [string]$MaxCostTier, [bool]$PassportAvailable, [string]$Root)
    $reasons = New-Object System.Collections.ArrayList
    if (Test-ModelOpen -Model $Model -Root $Root) { [void]$reasons.Add("breaker-open") }

    $passport = $null
    if ($PassportAvailable) { $passport = Get-ModelPassport -Model $Model -Root $Root }

    if (($null -ne $passport) -and (-not [string]::IsNullOrWhiteSpace($TaskType))) {
        $declared = Get-PassportTaskTypes -Passport $passport
        if (@($declared).Count -gt 0) {
            $match = Test-CapabilityMatch -Declared $declared -Requested $TaskType
            if (-not $match.matched) { [void]$reasons.Add("capability-mismatch") }
        }
    }

    if ((-not [string]::IsNullOrWhiteSpace($MaxCostTier)) -and ($MaxCostTier -ne "any")) {
        $tier = "unknown"
        if (($null -ne $passport) -and ($null -ne $passport["cost_tier"])) {
            $candidateTier = [string]$passport["cost_tier"]
            if (-not [string]::IsNullOrWhiteSpace($candidateTier)) { $tier = $candidateTier }
        }
        $allowed = $script:RouterCostTierRank["unknown"]
        if ($script:RouterCostTierRank.ContainsKey($MaxCostTier)) { $allowed = $script:RouterCostTierRank[$MaxCostTier] }
        $rank = $script:RouterCostTierRank["unknown"]
        if ($script:RouterCostTierRank.ContainsKey($tier)) { $rank = $script:RouterCostTierRank[$tier] }
        if ($rank -gt $allowed) { [void]$reasons.Add("cost-tier-above-max") }
    }
    return $reasons.ToArray()
}

function Get-CandidateScore {
    param($Metrics)
    $reliabilityScore = 0.5
    if ([int]$Metrics.samples -gt 0) { $reliabilityScore = [double]$Metrics.avg_grade / 10.0 }
    $speedScore = 0.5
    if (($null -ne $Metrics.p50_ms) -and ([double]$Metrics.p50_ms -gt 0)) {
        $speedScore = 1.0 - ([double]$Metrics.p50_ms / $script:RouterSpeedReferenceMs)
        if ($speedScore -lt 0) { $speedScore = 0 }
        if ($speedScore -gt 1) { $speedScore = 1 }
    }
    $costScore = 0.2
    if ($Metrics.cost_tier -eq "free") { $costScore = 1.0 }
    elseif ($Metrics.cost_tier -eq "medium") { $costScore = 0.6 }
    $total = ($script:RouterWeights.reliability * $reliabilityScore) +
             ($script:RouterWeights.speed * $speedScore) +
             ($script:RouterWeights.cost * $costScore)
    return [ordered]@{
        score       = [math]::Round($total, 3)
        reliability = [math]::Round($reliabilityScore, 3)
        speed       = [math]::Round($speedScore, 3)
        cost        = [math]::Round($costScore, 3)
    }
}

function Format-RouteCandidateLine {
    param($Candidate)
    $state = "candidate"
    if ($Candidate.decision -eq "chosen") { $state = "CHOSEN   " }
    elseif ($Candidate.decision -eq "rejected") { $state = "rejected " }
    $metrics = "cost=" + $Candidate.cost_tier
    if ($null -ne $Candidate.avg_grade) { $metrics = $metrics + " grade=" + $Candidate.avg_grade + "/" + $Candidate.samples }
    else { $metrics = $metrics + " grade=-/0" }
    if ($null -ne $Candidate.p50_ms) { $metrics = $metrics + " p50=" + $Candidate.p50_ms + "ms" }
    if ($null -ne $Candidate.score) { $metrics = $metrics + " score=" + $Candidate.score }
    return ("  {0} {1,-45} {2,-26} {3}" -f $state, [string]$Candidate.model, [string]$Candidate.code, $metrics)
}

function Format-RouteReason {
    param($Decision)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("reason=" + $Decision.reason)
    if (-not [string]::IsNullOrWhiteSpace([string]$Decision.task_type)) {
        [void]$parts.Add("task_type=" + $Decision.task_type)
    }
    [void]$parts.Add("configured=" + $Decision.configured)
    [void]$parts.Add("chosen=" + $Decision.model)
    [void]$parts.Add("mode=" + $Decision.decision_mode)
    [void]$parts.Add("passport=" + $Decision.passport)
    foreach ($candidate in @($Decision.candidates)) {
        if ($candidate.decision -eq "rejected") {
            [void]$parts.Add("rejected " + $candidate.model + " [" + $candidate.code + "]")
        }
    }
    return ($parts -join "; ")
}

function Get-RouteDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [string]$TaskType = "",
        [string]$MaxCostTier = "any",
        [switch]$Optimize,
        [string]$Root
    )
    $passportAvailable = Initialize-PassportModule -Root $Root
    $passportData = Get-PassportDataStatus -Root $Root
    $passportNote = $script:PassportLoadNote
    if (-not [string]::IsNullOrWhiteSpace([string]$passportData.note)) {
        if ([string]::IsNullOrWhiteSpace($passportNote)) { $passportNote = [string]$passportData.note }
        else { $passportNote = $passportNote + " | " + [string]$passportData.note }
    }
    $passportState = [string]$passportData.status
    $configured = Get-AgentConfiguredModel -Agent $Agent -Root $Root
    if ([string]::IsNullOrWhiteSpace($configured)) {
        return [pscustomobject]@{
            agent         = $Agent
            task_type     = $TaskType
            configured    = ""
            model         = ""
            changed       = $false
            reason        = "agent-model-unknown"
            reason_text   = "agent-model-unknown: no model for $Agent in .opencode\agents or in the runtime config"
            decision_mode = "stable"
            passport      = $passportState
            passport_note = $passportNote
            policy        = $MaxCostTier
            candidates    = @()
        }
    }

    # Agent capability gate: a task the agent does not declare is not silently
    # routed - the caller gets the mismatch instead of a wrong specialist.
    if ($passportAvailable -and (-not [string]::IsNullOrWhiteSpace($TaskType))) {
        $agentPassport = Get-AgentPassport -Agent $Agent -Root $Root
        $agentTypes = Get-PassportTaskTypes -Passport $agentPassport
        if (@($agentTypes).Count -gt 0) {
            $agentMatch = Test-CapabilityMatch -Declared $agentTypes -Requested $TaskType
            if (-not $agentMatch.matched) {
                return [pscustomobject]@{
                    agent         = $Agent
                    task_type     = $TaskType
                    configured    = $configured
                    model         = ""
                    changed       = $false
                    reason        = "agent-capability-mismatch"
                    reason_text   = "agent-capability-mismatch: $Agent declares [" + (@($agentTypes) -join ",") + "], task type '$TaskType' resolves to [" + (@($agentMatch.requested) -join ",") + "] - pick an agent whose passport covers it"
                    decision_mode = "stable"
                    passport      = $passportState
                    passport_note = $passportNote
                    policy        = $MaxCostTier
                    candidates    = @()
                }
            }
        }
    }

    $ladder = Get-FallbackLadder -Model $configured
    $candidates = New-Object System.Collections.ArrayList
    $viable = New-Object System.Collections.ArrayList
    foreach ($candidate in $ladder) {
        $modelPassport = $null
        if ($passportAvailable) { $modelPassport = Get-ModelPassport -Model $candidate -Root $Root }
        $metrics = Get-RouteCandidateMetrics -ModelPassport $modelPassport
        $rejections = Get-CandidateRejections -Model $candidate -TaskType $TaskType -MaxCostTier $MaxCostTier -PassportAvailable $passportAvailable -Root $Root
        $code = "selected"
        if (@($rejections).Count -gt 0) { $code = (@($rejections) -join "+") }
        $entry = [pscustomobject]@{
            model     = $candidate
            decision  = $(if (@($rejections).Count -gt 0) { "rejected" } else { "candidate" })
            code      = $code
            cost_tier = $metrics.cost_tier
            avg_grade = $metrics.avg_grade
            samples   = $metrics.samples
            p50_ms    = $metrics.p50_ms
            score     = $null
        }
        [void]$candidates.Add($entry)
        if (@($rejections).Count -eq 0) { [void]$viable.Add($entry) }
    }

    $decisionMode = "stable"
    $chosen = $null
    if ($Optimize) {
        $decisionMode = "scored"
        $bestScore = -1.0
        foreach ($entry in @($viable)) {
            $score = Get-CandidateScore -Metrics $entry
            $entry.score = $score.score
            if ([double]$score.score -gt $bestScore) { $bestScore = [double]$score.score; $chosen = $entry }
        }
    } elseif (@($viable).Count -gt 0) {
        $chosen = $viable[0]
    }

    $reason = "configured-healthy"
    if ($null -eq $chosen) {
        $configuredEntry = $null
        foreach ($entry in @($candidates)) { if ($entry.model -eq $configured) { $configuredEntry = $entry } }
        $allBreaker = $true
        foreach ($entry in @($candidates)) {
            if ($entry.code -notmatch "breaker-open") { $allBreaker = $false }
        }
        $chosenModel = [string]$ladder[$ladder.Count - 1]
        foreach ($entry in @($candidates)) { if ($entry.model -eq $chosenModel) { $entry.decision = "chosen"; $entry.code = "forced-last-resort"; $chosen = $entry } }
        if ($null -eq $chosen) {
            $chosen = [pscustomobject]@{ model = $chosenModel; decision = "chosen"; code = "forced-last-resort"; cost_tier = "unknown"; avg_grade = $null; samples = 0; p50_ms = $null; score = $null }
        }
        if ($allBreaker) { $reason = "all-candidates-open" } else { $reason = "all-candidates-rejected" }
    } else {
        $chosen.decision = "chosen"
        if ($chosen.model -ne $configured) {
            $configuredEntry = $null
            foreach ($entry in @($candidates)) { if ($entry.model -eq $configured) { $configuredEntry = $entry } }
            $configuredCode = ""
            if ($null -ne $configuredEntry) { $configuredCode = [string]$configuredEntry.code }
            if ($decisionMode -eq "scored") { $reason = "scored-preferred" }
            elseif ($configuredCode -match "breaker-open") { $reason = "configured-open-fallback" }
            elseif ($configuredCode -match "capability-mismatch") { $reason = "capability-fallback" }
            elseif ($configuredCode -match "cost-tier-above-max") { $reason = "cost-tier-fallback" }
            else { $reason = "configured-open-fallback" }
        } elseif ($decisionMode -eq "scored") {
            $reason = "configured-healthy"
        }
    }

    $decision = [pscustomobject]@{
        agent         = $Agent
        task_type     = $TaskType
        configured    = $configured
        model         = [string]$chosen.model
        changed       = ([string]$chosen.model -ne $configured)
        reason        = $reason
        reason_text   = ""
        decision_mode = $decisionMode
        passport      = $passportState
        passport_note = $passportNote
        policy        = $MaxCostTier
        candidates    = @($candidates.ToArray())
    }
    $decision.reason_text = Format-RouteReason -Decision $decision
    return $decision
}

# Write the routed model into .opencode\agents\<agent>.json (first "model" key
# only - BUG-023 -, indentation preserved) and sync the runtime config afterwards.
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

    # BUG-023: replace the first match ONLY. The static
    # [regex]::Replace($text, $pattern, $evaluator) overload has no count
    # parameter (its 4th argument is RegexOptions, where 1 means IgnoreCase), so
    # the count-limited overload is taken from a regex instance instead; the rest
    # of the document stays byte-identical.
    $targetModel = $Model
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        return $m.Groups[1].Value + '"' + $targetModel + '"'
    }
    try {
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
        $updated = $regex.Replace($raw, $evaluator, 1)
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
    Write-Host "  -TaskType <t>              with -Route: capability check against the passport"
    Write-Host "  -MaxCostTier <tier>        with -Route: free | medium | paid | any (default any)"
    Write-Host "  -Optimize                  with -Route: rank viable candidates by passport score"
    Write-Host "  -Quiet                     with -Route: no candidate table, reason line only"
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
        Optimize        = $false
        Quiet           = $false
        Agent           = ""
        TaskType        = ""
        MaxCostTier     = "any"
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
        elseif ($name -eq "-Optimize") { $options.Optimize = $true; $index++ }
        elseif ($name -eq "-Quiet") { $options.Quiet = $true; $index++ }
        elseif ($name -eq "-Help") { $options.Help = $true; $index++ }
        elseif (@("-Agent", "-Root", "-Models", "-FailThreshold", "-CooldownMinutes", "-TimeoutSec", "-TaskType", "-MaxCostTier") -contains $name) {
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
            elseif ($name -eq "-TaskType") { $options.TaskType = $value }
            elseif ($name -eq "-MaxCostTier") { $options.MaxCostTier = $value }
            elseif ($name -eq "-FailThreshold") { $options.FailThreshold = [int]$value }
            elseif ($name -eq "-CooldownMinutes") { $options.CooldownMinutes = [int]$value }
            elseif ($name -eq "-TimeoutSec") { $options.TimeoutSec = [int]$value }
        }
        else {
            throw "Unknown argument '$token'. Usage: -Status | -Probe | -Route -Agent <name> [-Apply]"
        }    }
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

    # Honour the proxy mode: mode=on exports HTTP(S)_PROXY for the probed CLI,
    # mode=off removes them so probes go direct (default).
    if (Get-Command Initialize-ProxyEnvironment -ErrorAction SilentlyContinue) {
        [void](Initialize-ProxyEnvironment -Root $root)
    }

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
        $route = Get-RouteDecision -Agent $options.Agent -TaskType $options.TaskType -MaxCostTier $options.MaxCostTier -Optimize:($options.Optimize) -Root $root
        Write-Host ""
        Write-Host ("AGENT      : " + $route.agent)
        if (-not [string]::IsNullOrWhiteSpace([string]$route.task_type)) {
            Write-Host ("TASK TYPE  : " + $route.task_type)
        }
        Write-Host ("CONFIGURED : " + $route.configured)
        Write-Host ("ROUTE      : " + $route.model)
        Write-Host ("REASON     : " + $route.reason)
        Write-Host ("WHY        : " + $route.reason_text)
        Write-Host ("POLICY     : max_cost_tier=" + $route.policy + " mode=" + $route.decision_mode + " passport=" + $route.passport)
        if (-not [string]::IsNullOrWhiteSpace([string]$route.passport_note)) {
            Write-Host ("PASSPORT   : " + $route.passport_note) -ForegroundColor Yellow
        }
        if (-not $options.Quiet) {
            Write-Host "CANDIDATES :"
            foreach ($candidate in @($route.candidates)) {
                Write-Host (Format-RouteCandidateLine -Candidate $candidate)
            }
        }

        if (-not $options.Apply) {
            Write-Host "APPLY      : skipped (pass -Apply to write into .opencode\agents and sync)"
        } elseif ([string]::IsNullOrWhiteSpace([string]$route.model)) {
            Write-Host "APPLY      : refused - no viable model for this request" -ForegroundColor Red
            exit 1
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
# (tests) merely loads the functions above. The passport module is dot-sourced
# right here: at the top level, so its functions land in this script scope.
$script:PassportModulePath = Resolve-PassportModulePath -Root ""
if ([string]::IsNullOrWhiteSpace($script:PassportModulePath)) {
    $script:PassportLoadNote = "capability-passport.ps1 not found - routed on health only"
} else {
    try {
        . $script:PassportModulePath
    } catch {
        $script:PassportLoadNote = "capability-passport.ps1 failed to load - routed on health only"
    }
}
[void](Import-PassportModule -Root "")
$script:ProxyModePath = Join-Path $PSScriptRoot "proxy-mode.ps1"
if (Test-Path -LiteralPath $script:ProxyModePath -PathType Leaf) {
    try { . $script:ProxyModePath } catch { }
}
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ModelRouterCommandLine -Arguments $args
}
