# agent-hq-daemon.ps1 — единая точка входа обработки inbox (P1-3).
#
# Чем отличается от inbox-poller.ps1:
#   * ОДИН проход сканирует inbox ВСЕХ агентов;
#   * сообщения обрабатываются bounded worker pool (Start-Job + -ThrottleLimit),
#     глобальный mutex-бутылочное горлышко убран — от дублей защищает
#     файлово-атомарный claim/lease (task-state.ps1) внутри общего engine;
#   * прогон ВСЕГДА ограничен по времени: -MaxDurationSeconds (default 240).
#     Постоянного скрытого фона нет (AGENTS.md §10/§4) — это короткий прогон,
#     который можно ставить в планировщик вместо legacy inbox-poller -Once.
#
# РЕЖИМЫ (все завершаются сами):
#   -Once           : один проход (scan -> обработать всё найденное -> выход)
#   -Drain          : проходы, пока scan не вернёт 0 сообщений (или не истёк лимит)
#   (без флагов)    : то же, но на пустом проходе пауза -PollIntervalSeconds,
#                     всё равно ограничено -MaxDurationSeconds
#
# Exit code (0 = чисто):
#   0 — без инфраструктурных ошибок (engine/CLI/worker job) и без dead-letter;
#   1 — инфраструктурная ошибка ИЛИ хотя бы одно сообщение ушло в dead-letter.
# Сообщения, не обработанные из-за лимита времени, остаются в inbox для
# следующего прогона: это НЕ ошибка (счётчик stopped в отчёте).
#
# Отчёт прогона: .memory\traces\daemon-last-run.json (машинночитаемые счётчики)
# Лог: .memory\traces\daemon.log
#
# Тестируемость (как у poller): $env:AGENT_HQ_ROOT — изолированный корень,
# $env:AGENT_HQ_OPENCODE — путь к CLI (фикстура в тестах),
# $env:AGENT_HQ_JOB_TIMEOUT — таймаут одной попытки агента.

param(
    [switch]$Once,
    [switch]$Drain,
    [int]$ThrottleLimit = 4,
    [int]$MaxDurationSeconds = 240,
    [int]$PollIntervalSeconds = 15,
    [switch]$DryRun
)

$script:DaemonScriptPath = $MyInvocation.MyCommand.Definition
$script:DaemonStartedAt = Get-Date

# --- Run counters (single source for the report + exit code) ------------------
$script:ExitCode = 1
$script:Passes = 0
$script:Dispatched = 0
$script:Processed = 0
$script:DeadLettered = 0
$script:Skipped = 0
$script:Stopped = 0
$script:WorkerErrors = 0
$script:FatalErrors = 0
$script:EnginePath = ""

# --- Shared engine (single source of the retry policy / claim / evidence) -----
$enginePath = Join-Path $PSScriptRoot "inbox-engine.ps1"
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    Write-Host "❌ inbox-engine.ps1 not found at $enginePath. Exit 1."
    exit 1
}
. $enginePath
$script:EnginePath = $enginePath

# Daemon writes its own log; worker jobs receive the same path so a pool run
# reads as one trace (the poller keeps .memory\traces\poller.log).
$script:LogPath = Join-Path $Traces "daemon.log"

# Defensive bounds: a bad argument must never turn a bounded run into an eternal one.
if ($ThrottleLimit -lt 1) { $ThrottleLimit = 1 }
if ($MaxDurationSeconds -lt 1) { $MaxDurationSeconds = 1 }
if ($PollIntervalSeconds -lt 1) { $PollIntervalSeconds = 1 }

function Get-DaemonMode {
    if ($Once) { return "once" }
    if ($Drain) { return "drain" }
    return "interval"
}

# --- Worker pool -------------------------------------------------------------

# One worker = one message in its own process. It re-uses the SAME engine, so the
# retry policy, the claim/lease and the evidence format are identical to the
# serial poller; the atomic claim is what makes parallel workers safe.
function Start-InboxWorkerJob {
    param([string]$FilePath, [string]$AgentName)

    return Start-Job -ScriptBlock {
        param($engine, $messagePath, $agent, $logPath)
        . $engine
        if ($logPath) { $script:LogPath = $logPath }
        return (Process-InboxFile -filePath $messagePath -agentName $agent)
    } -ArgumentList $script:EnginePath, $FilePath, $AgentName, $script:LogPath
}

# Collect every finished worker (optionally waiting for at least one), account its
# result and return the still-running entries.
function Receive-WorkerResults {
    param(
        [object[]]$Running,
        [switch]$WaitForAny,
        [int]$SliceSeconds = 5,
        [datetime]$Deadline = (Get-Date)
    )

    if ($Running.Count -eq 0) { return @() }

    if ($WaitForAny) {
        $jobList = @($Running | ForEach-Object { $_.Job })
        while ($true) {
            $any = Wait-Job -Job $jobList -Any -Timeout $SliceSeconds -ErrorAction SilentlyContinue
            if ($any) { break }
            if ((Get-Date) -ge $Deadline) { break }
        }
    }

    $remaining = @()
    foreach ($entry in $Running) {
        $job = $entry.Job
        $state = [string]$job.State
        if ($state -eq "Running" -or $state -eq "NotStarted" -or $state -eq "Blocked") {
            $remaining += $entry
            continue
        }

        $output = @()
        try { $output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) } catch { $output = @() }
        $result = $output | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Status'] } | Select-Object -Last 1

        if ($state -eq "Failed") {
            $reason = "unknown job failure"
            try { $reason = [string]$job.JobStateInfo.Reason.Message } catch { }
            Write-Log "❌ Worker job failed: $($entry.Item.MessageId) — $reason"
            $script:WorkerErrors++
        } elseif ($null -eq $result) {
            Write-Log "❌ Worker produced no status object: $($entry.Item.MessageId) (state $state)"
            $script:WorkerErrors++
        } else {
            switch ([string]$result.Status) {
                "done" {
                    $script:Processed++
                    Write-Log "✔️ Processed: $($result.MessageId) (agent $($result.Agent))"
                }
                "dead-letter" {
                    $script:DeadLettered++
                    Write-Log "💀 Dead-letter: $($result.MessageId) ($($result.Reason))"
                }
                "skipped" {
                    $script:Skipped++
                    Write-Log "⏭️ Skipped (claimed by another worker): $($result.MessageId)"
                }
                default {
                    Write-Log "ℹ️ Worker finished: $($result.MessageId) status=$($result.Status)"
                }
            }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    return @($remaining)
}

# A worker stopped by the duration bound cannot run its own finally{} block, so
# release its lease here instead of waiting for the stale TTL. Best-effort: the
# per-pass Invoke-StaleClaimSweep remains the safety net.
function Release-AbandonedClaim {
    param($Item)

    $taskId = [string]$Item.MessageId
    $agent = [string]$Item.Agent
    try {
        $json = Get-Content -LiteralPath $Item.FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($json.id) { $taskId = [string]$json.id }
        if ($json.to) { $agent = [string]$json.to }
    } catch {
        # Message already moved by the worker: fall back to file name / folder name.
    }

    $released = Release-Task -TaskId $taskId -Agent $agent -StateDir $ClaimsDir
    if ($released) {
        Write-Log "🔓 Released lease of stopped worker: $taskId"
    } else {
        Write-Log "⚠️ Lease of stopped worker not released: $taskId (will expire by stale TTL)"
    }
}

function Stop-RemainingWorkers {
    param([object[]]$Running)

    $stopped = 0
    foreach ($entry in $Running) {
        Write-Log "⏹️ Duration bound reached — stopping worker for $($entry.Item.MessageId)"
        Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        Release-AbandonedClaim -Item $entry.Item
        $stopped++
    }
    return $stopped
}

# Machine-readable run report (also the artifact the tests assert on).
function Write-DaemonReport {
    param([int]$ExitCode, [int]$Remaining)

    $report = [ordered]@{
        startedAt          = $script:DaemonStartedAt.ToString("o")
        finishedAt         = (Get-Date).ToString("o")
        mode               = (Get-DaemonMode)
        throttleLimit      = $ThrottleLimit
        maxDurationSeconds = $MaxDurationSeconds
        passes             = $script:Passes
        dispatched         = $script:Dispatched
        processed          = $script:Processed
        deadLettered       = $script:DeadLettered
        skipped            = $script:Skipped
        stopped            = $script:Stopped
        workerErrors       = $script:WorkerErrors
        fatalErrors        = $script:FatalErrors
        remaining          = $Remaining
        exitCode           = $ExitCode
    }
    $reportPath = Join-Path $Traces "daemon-last-run.json"
    try {
        [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
        Write-Log "🧾 Report: $reportPath (processed=$($script:Processed), dead-letter=$($script:DeadLettered), skipped=$($script:Skipped), stopped=$($script:Stopped), workerErrors=$($script:WorkerErrors))"
    } catch {
        Write-Log "⚠️ Failed to write daemon report: $($_.Exception.Message)"
    }
    return $report
}

# --- Bounded run -------------------------------------------------------------

function Invoke-DaemonRun {
    $deadline = (Get-Date).AddSeconds($MaxDurationSeconds)
    Write-Log "🚀 agent-hq-daemon start (mode=$(Get-DaemonMode), throttle=$ThrottleLimit, maxDuration=${MaxDurationSeconds}s, root=$Base)"

    if ($DryRun) {
        foreach ($item in @(Get-PendingInboxItems)) {
            Write-Log "🔍 Dry run: would process $($item.MessageId).json for agent $($item.Agent)"
        }
        $script:ExitCode = 0
        return
    }

    # Infrastructure pre-checks: without the CLI the whole run is pointless.
    if (-not (Test-OpencodeAvailable)) { $script:FatalErrors++ ; $script:ExitCode = 1 ; return }
    if (-not (Test-ScriptSyntax -Path $script:DaemonScriptPath)) { $script:FatalErrors++ ; $script:ExitCode = 1 ; return }

    while ($true) {
        if ((Get-Date) -ge $deadline) {
            Write-Log "⏰ Duration bound ($MaxDurationSeconds s) reached — finishing this run"
            break
        }

        # Stale sweep BEFORE any "Already claimed" skip (RISK-001): a crashed
        # worker's lease must never block a message forever.
        $null = Invoke-StaleClaimSweep -TtlSeconds 900

        $items = @(Get-PendingInboxItems)
        $script:Passes++

        if ($items.Count -eq 0) {
            Write-Log "ℹ️ Pass $($script:Passes): inbox is empty"
            if ($Once -or $Drain) { break }
            $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($left -le 0) { break }
            $pause = [Math]::Min($PollIntervalSeconds, $left)
            Write-Log "⏳ Sleeping $pause s before the next pass"
            Start-Sleep -Seconds $pause
            continue
        }

        Write-Log "📨 Pass $($script:Passes): $($items.Count) message(s) found, pool throttle=$ThrottleLimit"
        $running = @()

        foreach ($item in $items) {
            if ((Get-Date) -ge $deadline) { break }
            while ($running.Count -ge $ThrottleLimit) {
                $running = @(Receive-WorkerResults -Running $running -WaitForAny -Deadline $deadline)
                if ((Get-Date) -ge $deadline) { break }
            }
            if ((Get-Date) -ge $deadline) { break }

            $job = Start-InboxWorkerJob -FilePath $item.FilePath -AgentName $item.Agent
            $running += [PSCustomObject]@{ Job = $job; Item = $item }
            $script:Dispatched++
            Write-Log "🧵 Worker started ($($running.Count)/$ThrottleLimit): $($item.MessageId) -> $($item.Agent)"
        }

        # Drain the pool, but never past the deadline.
        while ($running.Count -gt 0 -and (Get-Date) -lt $deadline) {
            $running = @(Receive-WorkerResults -Running $running -WaitForAny -Deadline $deadline)
        }
        if ($running.Count -gt 0) {
            $script:Stopped += (Stop-RemainingWorkers -Running $running)
        }

        if ($Once) { break }
    }

    $remaining = @(Get-PendingInboxItems).Count
    $script:ExitCode = 0
    if ($script:FatalErrors -gt 0 -or $script:WorkerErrors -gt 0 -or $script:DeadLettered -gt 0) {
        $script:ExitCode = 1
    }
    $null = Write-DaemonReport -ExitCode $script:ExitCode -Remaining $remaining
    Write-Log "🏁 agent-hq-daemon done: exit=$($script:ExitCode), processed=$($script:Processed), dead-letter=$($script:DeadLettered), skipped=$($script:Skipped), stopped=$($script:Stopped), remaining=$remaining"
}

# --- Entry point: one daemon per machine session ------------------------------
$mutexName = "agent-hq-daemon-mutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Log "❌ Another daemon instance is already running. Exit 1."
    exit 1
}

try {
    Invoke-DaemonRun
} catch {
    Write-Log "❌ Daemon fatal error: $($_.Exception.Message)"
    $script:FatalErrors++
    $script:ExitCode = 1
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

exit $script:ExitCode
