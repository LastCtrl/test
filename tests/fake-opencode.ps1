# fake-opencode.ps1 - deterministic stand-in for `opencode run ...` used by pipeline tests.
# The behaviour is selected by the FAKE_OPENCODE_MODE environment variable; every CLI
# argument (e.g. `run --agent <name> <prompt>`) is accepted and ignored on purpose.
#
# Supported modes:
#   success      -> stdout "TASK done.\nSTATUS: resolved", exit 0
#   exit1        -> stdout "boom", exit 1
#   timeout      -> sleeps, exit 0 (lets the poller hit its job timeout)
#   empty        -> no stdout, exit 0
#   stderr-only  -> stderr only, no stdout, exit 0
#   nomarker     -> stdout without a success marker, exit 0
#   errormarker  -> stdout with an error marker, exit 0
#   leak         -> stdout with fake secrets but no success marker, exit 0 (must be redacted in dead-letter)
#   slow         -> sleeps FAKE_OPENCODE_DELAY_MS (default 1500) then success, exit 0.
#                   When FAKE_OPENCODE_TRACK_DIR is set, every invocation drops one
#                   JSON record (agent, startedAt, finishedAt, delayMs, pid) there,
#                   so a test can measure how many runs actually overlapped.
#   envprobe     -> prints AGENT_HQ_TASK_ID / AGENT_HQ_ATTEMPT_ID as seen in the
#                   worker environment, then success, exit 0. When
#                   FAKE_OPENCODE_ENV_TRACK_DIR is set, one "<task>|<attempt>" file
#                   per invocation is written there (P1-4/BUG-022 correlation probe).

$mode = $env:FAKE_OPENCODE_MODE

switch ($mode) {
    "success" {
        Write-Output "TASK done.`nSTATUS: resolved"
        exit 0
    }
    "exit1" {
        Write-Output "boom"
        exit 1
    }
    "timeout" {
        Start-Sleep -Seconds 600
        exit 0
    }
    "empty" {
        exit 0
    }
    "stderr-only" {
        [Console]::Error.WriteLine("stderr-only: nothing on stdout")
        exit 0
    }
    "nomarker" {
        Write-Output "everything fine, but no status marker"
        exit 0
    }
    "errormarker" {
        Write-Output "STATUS: resolved`nError: something broke"
        exit 0
    }
    "leak" {
        # No success marker on purpose -> the poller must route this to dead-letter.
        # The poller must redact both values before persisting the response.
        # Values are concatenated at runtime so this fixture contains no literal
        # secret-like string (the repo secret scanner must not block its own tests).
        $fakeToken = "dummy" + "_token_" + "ABCDEFGHIJKLMNOP"
        $fakeSk    = "s" + "k-" + "ABCDEFGHIJKLMNOPQRSTUVWX"
        Write-Output ("token=" + $fakeToken)
        Write-Output $fakeSk
        exit 0
    }
    "slow" {
        # Concurrency probe for the daemon worker pool: the run takes a known time,
        # then reports its own start/finish window in a per-invocation file (one file
        # per run => concurrent runs never contend for the same file).
        $delayMs = 1500
        $parsedDelay = 0
        if ($env:FAKE_OPENCODE_DELAY_MS) {
            if ([int]::TryParse($env:FAKE_OPENCODE_DELAY_MS, [ref]$parsedDelay) -and $parsedDelay -gt 0) {
                $delayMs = $parsedDelay
            }
        }

        $agentName = ""
        for ($i = 0; $i -lt ($args.Count - 1); $i++) {
            if ($args[$i] -eq "--agent") { $agentName = [string]$args[$i + 1] }
        }

        $startedAt = Get-Date
        Start-Sleep -Milliseconds $delayMs
        Write-Output "TASK done.`nSTATUS: resolved"

        if ($env:FAKE_OPENCODE_TRACK_DIR) {
            try {
                if (-not (Test-Path -LiteralPath $env:FAKE_OPENCODE_TRACK_DIR -PathType Container)) {
                    New-Item -ItemType Directory -Path $env:FAKE_OPENCODE_TRACK_DIR -Force | Out-Null
                }
                $record = [ordered]@{
                    agent      = $agentName
                    startedAt  = $startedAt.ToString("o")
                    finishedAt = (Get-Date).ToString("o")
                    delayMs    = $delayMs
                    pid        = $PID
                }
                $recordFile = Join-Path $env:FAKE_OPENCODE_TRACK_DIR ([guid]::NewGuid().ToString("N") + ".json")
                [System.IO.File]::WriteAllText($recordFile, ($record | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
            } catch {
                # A probe failure must never break the fixture itself.
            }
        }
        exit 0
    }
    "envprobe" {
        # P1-4/BUG-022 probe: report the correlation env the inbox engine exported
        # to this worker. The values are echoed on stdout (the poller stores it in
        # the outbox response) and appended to FAKE_OPENCODE_ENV_TRACK_DIR, so a
        # test can assert the task/attempt/agent ids really reached the child.
        $taskId = if ($env:AGENT_HQ_TASK_ID) { $env:AGENT_HQ_TASK_ID } else { "<unset>" }
        $attemptId = if ($env:AGENT_HQ_ATTEMPT_ID) { $env:AGENT_HQ_ATTEMPT_ID } else { "<unset>" }
        $agentName = if ($env:AGENT_HQ_AGENT) { $env:AGENT_HQ_AGENT } else { "<unset>" }
        Write-Output ("AGENT_HQ_TASK_ID=" + $taskId)
        Write-Output ("AGENT_HQ_ATTEMPT_ID=" + $attemptId)
        Write-Output ("AGENT_HQ_AGENT=" + $agentName)
        if ($env:FAKE_OPENCODE_ENV_TRACK_DIR) {
            try {
                if (-not (Test-Path -LiteralPath $env:FAKE_OPENCODE_ENV_TRACK_DIR -PathType Container)) {
                    New-Item -ItemType Directory -Path $env:FAKE_OPENCODE_ENV_TRACK_DIR -Force | Out-Null
                }
                $probeFile = Join-Path $env:FAKE_OPENCODE_ENV_TRACK_DIR ([guid]::NewGuid().ToString("N") + ".txt")
                [System.IO.File]::WriteAllText($probeFile, ($taskId + "|" + $attemptId + "|" + $agentName), (New-Object System.Text.UTF8Encoding($false)))
            } catch {
                # A probe failure must never break the fixture itself.
            }
        }
        Write-Output "STATUS: resolved"
        exit 0
    }
    default {
        Write-Output "fake-opencode: unknown or missing FAKE_OPENCODE_MODE ('$mode')"
        exit 2
    }
}
