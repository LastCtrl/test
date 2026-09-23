# Inbox Poller for agent-hq — auto-launches inbox workers
# Monitors .memory\inbox\{agent}\*.json and processes messages via opencode
#
# P1-3: the processing engine (retry policy, claim/lease, heartbeat, evidence) now
# lives in .agents\scripts\inbox-engine.ps1 and is shared with agent-hq-daemon.ps1.
# This runner stays the serial, single-mutex entry point used by the legacy
# scheduled task; the bounded parallel worker pool lives in agent-hq-daemon.ps1.

param(
    [switch]$Once,
    [int]$IntervalSeconds = 30,
    [switch]$DryRun
)

# --- Shared engine: paths ($Inbox/$Outbox/...), constants and every processing
# function (Process-Inbox, Process-InboxFile, Invoke-StaleClaimSweep, ...).
# The per-cycle stale-claim sweep (Invoke-StaleClaimSweep -> Revoke-StaleClaims
# of task-state.ps1) runs inside Process-Inbox before any "Already claimed" skip,
# so a crashed worker never blocks a message forever.
$enginePath = Join-Path $PSScriptRoot "inbox-engine.ps1"
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    Write-Host "❌ inbox-engine.ps1 not found at $enginePath. Exit 1."
    exit 1
}
. $enginePath

# Global mutex to prevent concurrent execution
$mutexName = "agent-hq-poller-mutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$bCreated = $mutex.WaitOne(0)
if (-not $bCreated) {
    Write-Log "❌ Another instance is already running. Exit 1."
    exit 1
}

# Guard: the RESOLVED opencode command must be available (env override or PATH)
if (-not (Test-OpencodeAvailable)) {
    Write-Log "Exit 1."
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 1
}

# Syntax check using PSParser
$scriptPath = $MyInvocation.MyCommand.Definition
if (-not (Test-ScriptSyntax -Path $scriptPath)) {
    Write-Log "Exit 1."
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 1
}
Write-Log "✅ Syntax check passed (PSParser)"

# --- DRY: Save TZ copy BEFORE the main loop (was dead code after infinite loop) ---
$tzCopyPath = (Join-Path $TasksDir "task-inbox-poller.txt")
if (-not (Test-Path $tzCopyPath)) {
    Write-Log "📄 Saving TZ copy to: $tzCopyPath"
    try {
        $scriptContent = Get-Content -Path $scriptPath -Encoding UTF8 -ErrorAction Stop
        [System.IO.File]::WriteAllText($tzCopyPath, ($scriptContent -join "`n"), $script:Utf8NoBom)
        Write-Log "✅ TZ copy saved successfully"
    } catch {
        Write-Log "⚠️ Failed to save TZ copy: $($_.Exception.Message)"
    }
}

# Dry run mode — show plan, nothing executes
if ($DryRun) {
    Write-Log "🔍 Dry run mode — showing plan only"

    $foundMessages = $false
    foreach ($item in @(Get-PendingInboxItems)) {
        $foundMessages = $true
        Write-Log "📄 Inbox file: $($item.MessageId).json for agent: $($item.Agent)"
    }

    if (-not $foundMessages) {
        Write-Log "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
        Write-Host "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
    }

    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 0
}

# Main execution with Mutex try/finally for safe release
try {
    if ($Once) {
        Process-Inbox
    } else {
        # Interval loop — process repeatedly
        while ($true) {
            Process-Inbox
            Write-Log "⏳ Sleeping for $IntervalSeconds seconds before next poll"
            $null = Start-Sleep -Seconds $IntervalSeconds
        }
    }
} finally {
    # Always release mutex
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
