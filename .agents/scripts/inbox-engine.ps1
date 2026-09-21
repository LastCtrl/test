# inbox-engine.ps1 - shared inbox processing engine for agent-hq (P1-3).
#
# DOT-SOURCE ONLY. It defines functions and prepares state in the caller's script
# scope; it never calls exit, never starts a background process and never emits
# output on its own:
#
#   . "$PSScriptRoot\inbox-engine.ps1"
#
# Why it exists: the retry policy (2 attempts, success = exit 0 + success marker
# + no error marker), the claim/lease handling and the evidence format must exist
# exactly ONCE. Two thin runners use this engine:
#
#   inbox-poller.ps1     - serial, one global mutex (legacy scheduled task)
#   agent-hq-daemon.ps1  - bounded run + Start-Job worker pool (ThrottleLimit)
#
# What it prepares in the caller's scope
#   $Base $Memory $Inbox $Outbox $Archive $DeadLetter $Traces $TasksDir $ClaimsDir
#   $LogPath                 - <Traces>\poller.log (override after dot-sourcing)
#   $Utf8NoBom $maxResponseLength
#   $SuccessMarker $ErrorMarker
#   $JobTimeoutSeconds       - env AGENT_HQ_JOB_TIMEOUT (positive int), else 900
#   $ClaimLeaseSeconds       - 2 x JobTimeout + 300 (RISK-001b)
#   $OpencodeCmd             - resolved CLI (env AGENT_HQ_OPENCODE, else the npm shim,
#                              else "opencode" from PATH)
# It also creates the .memory directories and dot-sources the helpers
# redact.ps1 / evidence-writer.ps1 / task-state.ps1, each with a logged fallback.
#
# Variant B (vault-only provider keys): in production the workers are started through
# run-with-secrets.ps1, so OPENCODE_API_KEY / AIHUBMIX_API_KEY / OPENROUTER_API_KEY /
# GROQ_API_KEY / TOKENROUTER_API_KEY live in the child environment for that run only
# and are never read from HKCU\Environment. See Get-OpencodeLaunchPlan.
#
# Pure PowerShell 5.1. No secrets are ever written to the bus or to the log.

$script:EngineScriptRoot = $PSScriptRoot

# --- Paths (env AGENT_HQ_ROOT wins: used by tests and isolated roots) ---------
$script:Base = if ($env:AGENT_HQ_ROOT) {
    $env:AGENT_HQ_ROOT
} elseif ($script:EngineScriptRoot) {
    Split-Path (Split-Path $script:EngineScriptRoot -Parent) -Parent
} else {
    (Get-Location).Path
}
$script:Memory = Join-Path $script:Base ".memory"
$script:Inbox = Join-Path $script:Memory "inbox"
$script:Outbox = Join-Path $script:Memory "outbox"
$script:Archive = Join-Path $script:Memory "archive"
$script:DeadLetter = Join-Path $script:Memory "dead-letter"
$script:Traces = Join-Path $script:Memory "traces"
$script:TasksDir = Join-Path $script:Base ".agents\tasks"
$script:ClaimsDir = Join-Path $script:Memory "claims"

# --- Constants (DRY: magic numbers & encoding) -------------------------------
$script:Utf8NoBom = [System.Text.Encoding]::GetEncoding(65001)
$script:maxResponseLength = 4000

# log file name is fixed for the poller; a runner may re-point $LogPath right
# after dot-sourcing (agent-hq-daemon.ps1 writes daemon.log).
$script:LogPath = Join-Path $script:Traces "poller.log"

# Ensure required directories exist
@($script:Inbox, $script:Outbox, $script:Archive, $script:DeadLetter, $script:Traces, $script:TasksDir, $script:ClaimsDir) | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# --- Dry-run flag: the poller passes -DryRun, the daemon may too. A worker job
# that dot-sources this engine has no such variable, so default it to $false.
if ($null -eq (Get-Variable -Name DryRun -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DryRun = $false
}

# Logging function: Write-Host with timestamp + append to $LogPath
function Write-Log {
    param($msg)
    try {
        $date = Get-Date -Format "HH:mm:ss"
        $logLine = "$date $msg"
        Write-Host $logLine
        $logPath = if ($script:LogPath) { $script:LogPath } else { Join-Path $script:Traces "poller.log" }
        [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $script:Utf8NoBom)
    } catch {
        # Fallback: if file logging fails, at least Write-Host already worked above
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [LOG-ERROR] Failed to write log: $($_.Exception.Message)"
    }
}

# --- Secret redaction (P0-D): dot-source the helper that masks credentials before
# ANY agent output or message payload is persisted to outbox/dead-letter.
# A missing helper degrades to a logged no-op instead of crashing the runner.
$redactHelperPath = Join-Path $PSScriptRoot "redact.ps1"
if (Test-Path -LiteralPath $redactHelperPath) {
    . $redactHelperPath
} else {
    Write-Log "⚠️ redact.ps1 not found at $redactHelperPath — secret redaction DISABLED"
    function Redact-Secrets { param([string]$Text) return $Text }
}

# --- Machine-generated evidence (P0-C): dot-source the runtime evidence writer.
# The engine (not the model under test) records exit codes/hashes/timing here.
$script:EvidenceAvailable = $false
$evidenceWriterPath = Join-Path $PSScriptRoot "evidence-writer.ps1"
if (Test-Path -LiteralPath $evidenceWriterPath) {
    . $evidenceWriterPath
    $script:EvidenceAvailable = $true
} else {
    Write-Log "⚠️ evidence-writer.ps1 not found at $evidenceWriterPath — evidence records disabled"
}

# --- Task claims (P1-1): dot-source the file-atomic claim/lease helper. It lets
# concurrent workers (poller and/or daemon pool) skip messages another worker
# already owns — the deduplication that replaces a global mutex. A missing helper
# degrades to no-op stubs instead of crashing the runner.
$taskStateHelperPath = Join-Path $PSScriptRoot "task-state.ps1"
if (Test-Path -LiteralPath $taskStateHelperPath) {
    . $taskStateHelperPath
} else {
    Write-Log "⚠️ task-state.ps1 not found at $taskStateHelperPath — task claims DISABLED"
    function Claim-Task {
        param([AllowEmptyString()][string]$TaskId, [string]$Agent = "", [int]$LeaseSeconds = 900, [int]$Attempt = 0, [string]$StateDir)
        return $true
    }
    function Release-Task {
        param([AllowEmptyString()][string]$TaskId, [string]$Agent = "", [string]$StateDir)
        return $true
    }
    function Update-Heartbeat {
        param([AllowEmptyString()][string]$TaskId, [string]$StateDir)
        return $false
    }
    function Revoke-StaleClaims {
        param([int]$TtlSeconds = 900, [string]$StateDir)
        return @()
    }
}

# --- CLI resolution + variant B (vault-only provider keys) -------------------
# Provider keys must never live in HKCU\Environment. In production the CLI is
# launched through run-with-secrets.ps1: the wrapper decrypts the keys from the
# DPAPI vault and puts them into the environment of the CHILD process only.
#
#   $env:AGENT_HQ_OPENCODE       CLI path override (tests / fake CLI). BYPASSES the
#                                vault wrapper on purpose: fixtures must run without
#                                reading the real vault.
#   $env:AGENT_HQ_OPENCODE_PATH  CLI file path that STILL goes through the wrapper
#                                (test hook used to exercise the vault path).
#   $env:AGENT_HQ_NO_VAULT       kill switch: never use the wrapper (debug/incident).
$script:VaultSecretNames = @('opencode-api-key', 'aihubmix-api-key', 'openrouter-api-key', 'groq-api-key', 'tokenrouter-api-key')
$script:SecretWrapperPath = Join-Path $PSScriptRoot 'run-with-secrets.ps1'
$script:VaultDir = if ($env:AGENT_HQ_SECRETS) {
    $env:AGENT_HQ_SECRETS
} elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE '.agent-secrets'
} else {
    ''
}

# Resolve the CLI file to invoke. Order: explicit override -> test path hook ->
# npm shim (a real FILE, required by run-with-secrets -FilePath) -> PATH lookup.
function Resolve-OpencodeCli {
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_OPENCODE)) { return $env:AGENT_HQ_OPENCODE }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_OPENCODE_PATH)) { return $env:AGENT_HQ_OPENCODE_PATH }
    if ($env:APPDATA) {
        $shim = Join-Path $env:APPDATA 'npm\opencode.ps1'
        if (Test-Path -LiteralPath $shim -PathType Leaf) { return $shim }
    }
    $cmd = Get-Command opencode -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    return 'opencode'
}

# Provider secrets that ACTUALLY exist in the vault. A single missing key must not
# abort every launch (the wrapper exits 2 when a requested secret is absent).
function Get-VaultSecretNames {
    $names = @()
    if (-not $script:VaultDir) { return @() }
    if (-not (Test-Path -LiteralPath $script:VaultDir -PathType Container)) { return @() }
    foreach ($n in $script:VaultSecretNames) {
        if (Test-Path -LiteralPath (Join-Path $script:VaultDir ('secret.' + $n + '.enc')) -PathType Leaf) {
            $names += $n
        }
    }
    return @($names)
}

# How the CLI must be launched for one attempt:
#   Cli     - path/name handed to the launcher
#   UseVault- $true => run through run-with-secrets.ps1 with Secrets injected
#   Wrapper - absolute path of the wrapper ('' when unused)
#   Secrets - vault secret names (empty when unused)
function Get-OpencodeLaunchPlan {
    $plan = [pscustomobject]@{
        Cli       = (Resolve-OpencodeCli)
        UseVault  = $false
        Wrapper   = ''
        Secrets   = @()
    }
    # Test/override path: raw CLI, vault wrapper intentionally bypassed.
    if ($env:AGENT_HQ_OPENCODE) { return $plan }
    if ($env:AGENT_HQ_NO_VAULT) {
        Write-Log "⚠️ AGENT_HQ_NO_VAULT is set — provider keys are NOT injected from the vault"
        return $plan
    }
    if (-not (Test-Path -LiteralPath $script:SecretWrapperPath -PathType Leaf)) {
        Write-Log "⚠️ run-with-secrets.ps1 not found at $($script:SecretWrapperPath) — launching CLI without vault keys"
        return $plan
    }
    $secrets = @(Get-VaultSecretNames)
    if ($secrets.Count -eq 0) {
        Write-Log "⚠️ no provider keys in vault '$($script:VaultDir)' — launching CLI without vault keys"
        return $plan
    }
    $plan.UseVault = $true
    $plan.Wrapper = $script:SecretWrapperPath
    $plan.Secrets = $secrets
    return $plan
}

# Resolved CLI for logging/evidence (informational; the launch plan is authoritative).
$script:OpencodeCmd = Resolve-OpencodeCli

# Guard: is the RESOLVED opencode command available? Returns $true/$false — the
# runner decides what exit code a missing CLI means.
function Test-OpencodeAvailable {
    if ($env:AGENT_HQ_OPENCODE) {
        if (-not (Test-Path -LiteralPath $env:AGENT_HQ_OPENCODE)) {
            Write-Log "❌ AGENT_HQ_OPENCODE is set but path not found: $env:AGENT_HQ_OPENCODE"
            return $false
        }
        return $true
    }
    if ($env:AGENT_HQ_OPENCODE_PATH) {
        if (-not (Test-Path -LiteralPath $env:AGENT_HQ_OPENCODE_PATH -PathType Leaf)) {
            Write-Log "❌ AGENT_HQ_OPENCODE_PATH is set but file not found: $env:AGENT_HQ_OPENCODE_PATH"
            return $false
        }
        return $true
    }
    $resolved = Resolve-OpencodeCli
    if ($resolved -ne 'opencode' -and (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $true }
    if (Get-Command opencode -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) { return $true }
    Write-Log "❌ opencode not found in PATH. Install opencode or add to PATH."
    return $false
}

# PSParser syntax self-check for a script file. Returns $true/$false.
function Test-ScriptSyntax {
    param([string]$Path)
    try {
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Path), [ref]$errors)
        if ($null -ne $errors -and $errors.Count -gt 0) {
            Write-Log "❌ Syntax check failed (PSParser): $($errors.Count) error(s) in $Path"
            return $false
        }
        return $true
    } catch {
        Write-Log "❌ Syntax check failed (PSParser): $($_.Exception.Message)"
        return $false
    }
}

# --- Result definition (DRY). Structured bus tasks: exit 0 + success marker +
# clean output. Interactive Telegram tasks (source=run/reply or from=telegram):
# exit 0 + non-empty stdout, marker optional because the answer is the result.
# Benign opencode warnings are stripped before the error marker is matched.
$script:SuccessMarker = '(?i)STATUS:\s*(resolved|done|completed)'
$script:ErrorMarker = '(?i)(permission denied|auto-rejecting|rejected permission|Error:|command not found|not recognized|no such file|cannot find path)'
$script:BenignOutputPatterns = @(
    '(?i)agent\s+"[^"]*"\s+not found\.\s*Falling back to default agent'
)
$script:TelegramFrom = 'telegram'
$script:JobTimeoutSeconds = 900
if ($env:AGENT_HQ_JOB_TIMEOUT) {
    $envTimeout = 0
    if ([int]::TryParse($env:AGENT_HQ_JOB_TIMEOUT, [ref]$envTimeout) -and $envTimeout -gt 0) {
        $script:JobTimeoutSeconds = $envTimeout
    } else {
        Write-Log "⚠️ Ignoring invalid AGENT_HQ_JOB_TIMEOUT='$env:AGENT_HQ_JOB_TIMEOUT' (expected positive integer seconds)"
    }
}

# RISK-001b: a lease must outlive the worst case (two attempts of
# JobTimeoutSeconds plus overhead); otherwise a long run loses its claim while
# still working. Update-Heartbeat refreshes it during a run as the second belt.
$script:ClaimLeaseSeconds = ([int]$script:JobTimeoutSeconds * 2) + 300

# Guard: empty payload → immediately dead-letter
function Check-Payload {
    param($msg)
    if (-not $msg.payload -or $msg.payload -eq "" -or $msg.payload -eq $null) {
        return $true
    }
    return $false
}

# Format date helper: yyyy-MM-ddTHH:mm:ss
function Format-DateTime {
    return ("{0:yyyy-MM-ddTHH:mm:ss}" -f (Get-Date))
}

# --- DRY: Dead-letter creation extracted from two copy-pasted blocks ---
function Send-DeadLetter {
    param(
        [string]$messageId,
        [string]$from,
        [string]$targetAgent,
        [string]$priority,
        [string]$payload,
        [string]$startedAt,
        [string]$response,
        [string]$filePath,
        [string]$evidence = ""
    )
    $dlFinishedAt = Format-DateTime
    # P0-D: never persist plaintext credentials into the dead-letter bus.
    $dlMsg = @{
        id = $messageId
        from = $from
        to = $targetAgent
        type = "failed"
        priority = $priority
        payload = (Redact-Secrets $payload)
        status = "failed"
        startedAt = $startedAt
        finishedAt = $dlFinishedAt
        response = (Redact-Secrets $response)
        evidence = $evidence
    }
    $jsonDL = $dlMsg | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $DeadLetter "$($messageId).json"), $jsonDL, $script:Utf8NoBom)

    # Remove original inbox file
    try {
        Remove-Item $filePath -Force
    } catch {
        Write-Log "⚠️ Failed to remove inbox file during dead-letter: $($_.Exception.Message)"
    }
    Write-Log "📂 Moved to dead-letter: $messageId"
}

# --- DRY: Success handler extracted from two copy-pasted blocks ---
function Complete-InboxFile {
    param(
        [string]$messageId,
        [string]$from,
        [string]$targetAgent,
        [string]$priority,
        [string]$payload,
        [string]$startedAt,
        [string]$response,
        [string]$filePath,
        [string]$fullFileName,
        [string]$evidence = ""
    )
    # P0-D: redact BEFORE truncation so a credential cut at the boundary cannot
    # survive as a partial token that no longer matches a full-length pattern.
    $safeResponse = Redact-Secrets $response
    if ($safeResponse.Length -gt $maxResponseLength) {
        $safeResponse = $safeResponse.Substring(0, $maxResponseLength)
    }

    $outboxMsg = @{
        id = $messageId
        from = $from
        to = $targetAgent
        type = "result"
        priority = $priority
        payload = (Redact-Secrets $payload)
        status = "done"
        startedAt = $startedAt
        finishedAt = Format-DateTime
        response = $safeResponse
        evidence = $evidence
    }

    $jsonOut = $outboxMsg | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $Outbox "$($messageId).json"), $jsonOut, $script:Utf8NoBom)

    # Move original inbox file to archive: {agent}-{original_name}
    $archiveName = "$($targetAgent)-$($fullFileName)"
    $archivePath = Join-Path $Archive $archiveName
    try {
        Move-Item $filePath $archivePath -Force
    } catch {
        Write-Log "⚠️ Failed to move to archive: $archiveName — $($_.Exception.Message)"
    }
    Write-Log "✅ Done: $messageId -> archived by $targetAgent"
}

# Attach wall-clock timing to an attempt object (ISO 8601 boundaries + duration).
function Add-AttemptTiming {
    param($attempt, [datetime]$startedAt, [datetime]$finishedAt)
    if ($null -eq $attempt) {
        $attempt = [PSCustomObject]@{ stdout = ""; stderr = ""; exitCode = 1 }
    }
    if ($attempt -is [array]) { $attempt = $attempt[-1] }
    $attempt | Add-Member -NotePropertyName startedAt -NotePropertyValue $startedAt.ToString("o") -Force
    $attempt | Add-Member -NotePropertyName finishedAt -NotePropertyValue $finishedAt.ToString("o") -Force
    $attempt | Add-Member -NotePropertyName durationMs -NotePropertyValue ([int]($finishedAt - $startedAt).TotalMilliseconds) -Force
    return $attempt
}

# Run opencode in a background job, capturing stdout/stderr separately and the REAL exit code.
# Returns: [PSCustomObject]@{ stdout; stderr; exitCode; startedAt; finishedAt; durationMs }  (never a bare string)
function Invoke-OpencodeAttempt {
    param([string]$targetAgent, [string]$taskPrompt, [string]$TaskId = "", [string]$AttemptId = "", $Launch = $null)

    $startedAt = Get-Date

    # Variant B: decide here (per attempt) whether the provider keys come from the
    # DPAPI vault via run-with-secrets.ps1. $env:AGENT_HQ_OPENCODE (test override)
    # always wins and is launched raw.
    if ($null -eq $Launch) { $Launch = Get-OpencodeLaunchPlan }
    $cliPath = [string]$Launch.Cli
    $useVault = [bool]$Launch.UseVault
    $wrapperPath = [string]$Launch.Wrapper
    # Start-Job flattens array arguments, so the secret-name list travels as CSV.
    $secretsCsv = (@($Launch.Secrets) -join ',')

    $job = Start-Job -ScriptBlock {
        param($agent, $taskPrompt, $correlationTaskId, $correlationAttemptId, $cliPath, $wrapperPath, $useVault, $secretsCsv)
        # P1-4/BUG-022: export the correlation ids into the worker environment so
        # the tracer/scoring plugins of the spawned CLI can join traces with the
        # engine's machine evidence. Start-Job runs in a child process that
        # inherits the parent env, so setting $env: here (before the CLI starts)
        # is what the CLI and its plugins will actually read. When the engine has
        # no id, an inherited value is cleared instead of leaking a stale one.
        if ($correlationTaskId) {
            $env:AGENT_HQ_TASK_ID = $correlationTaskId
        } else {
            Remove-Item Env:\AGENT_HQ_TASK_ID -ErrorAction SilentlyContinue
        }
        if ($correlationAttemptId) {
            $env:AGENT_HQ_ATTEMPT_ID = $correlationAttemptId
        } else {
            Remove-Item Env:\AGENT_HQ_ATTEMPT_ID -ErrorAction SilentlyContinue
        }
        # P3-3 gap: the fleet agent name is exported too. Every agent in
        # .opencode\agents is mode=subagent and `opencode run --agent <subagent>`
        # falls back to the default primary agent, so the runtime cannot report
        # the fleet agent (observed 2026-09-17 on opencode 1.18.31: --agent
        # qa-engineer -> session agent "build"). The launcher knows the name.
        if ($agent) {
            $env:AGENT_HQ_AGENT = $agent
        } else {
            Remove-Item Env:\AGENT_HQ_AGENT -ErrorAction SilentlyContinue
        }
        $cliArgs = @('run', '--agent', $agent, $taskPrompt)
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            if ($useVault -and $wrapperPath) {
                # Variant B: keys are decrypted into THIS process' environment for the
                # duration of the call only and restored by the wrapper's finally.
                $secretNames = @($secretsCsv -split ',' | Where-Object { $_ })
                $stdout = & $wrapperPath -Secret $secretNames -FilePath $cliPath -Args $cliArgs 2>$errFile
            } else {
                $stdout = & $cliPath @cliArgs 2>$errFile
            }
            $exitCode = $LASTEXITCODE
            $stderr = ""
            if (Test-Path $errFile) {
                $stderr = [System.IO.File]::ReadAllText($errFile)
            }
            [PSCustomObject]@{
                stdout   = (@($stdout) -join "`n")
                stderr   = $stderr
                exitCode = $exitCode
            }
        } finally {
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $targetAgent, $taskPrompt, $TaskId, $AttemptId, $cliPath, $wrapperPath, $useVault, $secretsCsv

    # Heartbeat the lease while we wait: a single attempt may run almost
    # $script:JobTimeoutSeconds, so without this the claim could expire
    # mid-processing (RISK-001b). Wait in slices and refresh between them.
    $completed = $null
    $deadline = (Get-Date).AddSeconds($script:JobTimeoutSeconds)
    while ($true) {
        $remaining = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($remaining -le 0) { break }
        $slice = [Math]::Min(30, $remaining)
        $completed = Wait-Job -Job $job -Timeout $slice
        if ($completed) { break }
        if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
            $null = Update-Heartbeat -TaskId $TaskId -StateDir $ClaimsDir
        }
    }

    if ($completed) {
        $res = Receive-Job -Job $job
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $finishedAt = Get-Date
        if ($null -eq $res) {
            $res = [PSCustomObject]@{ stdout = ""; stderr = "Job produced no result object"; exitCode = 1 }
        }
        return (Add-AttemptTiming -attempt $res -startedAt $startedAt -finishedAt $finishedAt)
    }

    Stop-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $finishedAt = Get-Date
    Write-Log "⏱️ TIMEOUT $($script:JobTimeoutSeconds)s: agent '$targetAgent' hung — job killed"
    $timeoutResult = [PSCustomObject]@{
        stdout   = "TIMEOUT: agent '$targetAgent' did not respond in $($script:JobTimeoutSeconds) seconds"
        stderr   = ""
        exitCode = 124
    }
    return (Add-AttemptTiming -attempt $timeoutResult -startedAt $startedAt -finishedAt $finishedAt)
}

# Remove benign opencode warnings (e.g. the subagent fallback notice) so they
# cannot trip the error marker. Real errors are never in this list.
function Remove-BenignOutput {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $clean = $Text
    foreach ($pattern in $script:BenignOutputPatterns) {
        $clean = [regex]::Replace($clean, $pattern, '')
    }
    return $clean
}

# Success ONLY when: exit code == 0 AND stdout has the explicit success marker AND stderr has no error markers.
# A non-empty error text (stderr) or unmatched stdout is NOT success.
function Test-OpencodeSuccess {
    param($attempt, [switch]$RequireMarker)
    if ($null -eq $attempt) { return $false }
    if ($attempt.exitCode -ne 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return $false }
    # Error markers anywhere in the captured output (stdout or stderr) mean failure.
    $combined = Remove-BenignOutput "$($attempt.stdout)`n$($attempt.stderr)"
    if ($combined -match $script:ErrorMarker) { return $false }
    if ($RequireMarker -and $attempt.stdout -notmatch $script:SuccessMarker) { return $false }
    return $true
}

function Get-AttemptFailureReason {
    param($attempt, [switch]$RequireMarker)
    if ($null -eq $attempt) { return "no result object" }
    if ($attempt.exitCode -ne 0) { return "exit code $($attempt.exitCode)" }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return "empty stdout" }
    $combined = Remove-BenignOutput "$($attempt.stdout)`n$($attempt.stderr)"
    if ($combined -match $script:ErrorMarker) { return "error marker in output: '$($matches[0])'" }
    if ($RequireMarker -and $attempt.stdout -notmatch $script:SuccessMarker) { return "missing success marker '$($script:SuccessMarker)'" }
    return "unknown reason"
}

# Truncate long text for dead-letter payload (max 4000 chars + explicit omission note)
function Limit-Text {
    param([string]$text, [int]$max = $maxResponseLength)
    if ($null -eq $text) { return "" }
    if ($text.Length -gt $max) {
        $omitted = $text.Length - $max
        return $text.Substring(0, $max) + "`n…[truncated $omitted chars]"
    }
    return $text
}

# Full stdout+stderr+reason record for dead-letter (stdout/stderr each truncated to $maxResponseLength)
function Format-AttemptReport {
    param([string]$reason, $attempt)
    if ($null -eq $attempt) {
        return "REASON: $reason`nEXIT CODE: n/a"
    }
    return @(
        "REASON: $reason",
        "EXIT CODE: $($attempt.exitCode)",
        "--- STDOUT ---",
        (Limit-Text $attempt.stdout),
        "--- STDERR ---",
        (Limit-Text $attempt.stderr)
    ) -join "`n"
}

# Build ONE machine evidence record from an attempt object. Called by the engine
# runtime only — the agent under test never contributes to these fields.
function New-EvidenceRecord {
    param(
        $attempt,
        [string]$taskId,
        [string]$attemptId,
        [string]$agent,
        [string]$command,
        [string]$status,
        [string]$reason
    )
    $stdoutText = if ($null -ne $attempt) { [string]$attempt.stdout } else { "" }
    $stderrText = if ($null -ne $attempt) { [string]$attempt.stderr } else { "" }
    $exitCode = if ($null -ne $attempt -and $null -ne $attempt.exitCode) { [int]$attempt.exitCode } else { -1 }
    $startedAt = if ($null -ne $attempt -and $attempt.startedAt) { [string]$attempt.startedAt } else { "" }
    $finishedAt = if ($null -ne $attempt -and $attempt.finishedAt) { [string]$attempt.finishedAt } else { "" }
    $durationMs = if ($null -ne $attempt -and $null -ne $attempt.durationMs) { [int]$attempt.durationMs } else { 0 }
    # P0-D: reason is human-readable and may quote agent output; redact it.
    # The sha256 fields above stay computed over RAW stdout/stderr so that
    # tamper-evidence is preserved (never hash a redacted body).
    $reasonText = if ($null -ne $reason) { [string]$reason } else { "" }
    if (Get-Command Redact-Secrets -ErrorAction SilentlyContinue) {
        $reasonText = Redact-Secrets $reasonText
    }
    $git = Get-GitInfo

    return [ordered]@{
        task_id         = $taskId
        attempt_id      = $attemptId
        agent           = $agent
        command         = $command
        exit_code       = $exitCode
        stdout_sha256   = Get-TextSha256 $stdoutText
        stdout_length   = $stdoutText.Length
        stderr_sha256   = Get-TextSha256 $stderrText
        stderr_length   = $stderrText.Length
        started_at      = $startedAt
        finished_at     = $finishedAt
        duration_ms     = $durationMs
        status          = $status
        reason          = $reasonText
        git_head        = $git.git_head
        git_diff_sha256 = $git.git_diff_sha256
        host            = $env:COMPUTERNAME
        pid             = $PID
    }
}

# Persist one attempt record and return its relative evidence path ("" on failure).
function Write-AttemptEvidence {
    param(
        $attempt,
        [string]$taskId,
        [string]$attemptId,
        [string]$agent,
        [string]$command,
        [string]$status,
        [string]$reason
    )
    $relative = ""
    if ($script:EvidenceAvailable) {
        try {
            $record = New-EvidenceRecord -attempt $attempt -taskId $taskId -attemptId $attemptId `
                -agent $agent -command $command -status $status -reason $reason
            $relative = Write-EvidenceRecord -TaskId $taskId -Record $record
        } catch {
            Write-Log "⚠️ Failed to write evidence record ($taskId/$attemptId): $($_.Exception.Message)"
            $relative = ""
        }
    }
    return $relative
}

# Process a single inbox file. Returns a status object so a pool runner can
# account for every message:
#   Status: "done" | "dead-letter" | "skipped" | "dry-run"
#   Reason: "empty-payload" | "parse-error" | "already-claimed" |
#           "failed-after-retry" | "" (the poller ignores the return value)
function Process-InboxFile {
    param($filePath, $agentName)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $fullFileName = [System.IO.Path]::GetFileName($filePath)
    $result = [PSCustomObject]@{ MessageId = $fileName; Agent = $agentName; Status = "unknown"; Reason = "" }

    try {
        $content = Get-Content $filePath -Encoding UTF8
        $msg = $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "❌ Failed to parse JSON: $($fileName)"
        # Move to dead-letter
        $dest = Join-Path $DeadLetter "$($fileName).json"
        try {
            Move-Item $filePath $dest -Force
        } catch {
            Write-Log "⚠️ Failed to move parse-error file to dead-letter: $($_.Exception.Message)"
        }
        Write-Log "⚠️ Moved to dead-letter due to parse error: $fileName"
        $result.Status = "dead-letter"
        $result.Reason = "parse-error"
        return $result
    }

    # Extract message fields with safe defaults (BUG-001: -or returns Boolean, not value)
    if ($msg.id) { $messageId = $msg.id } else { $messageId = $fileName }
    if ($msg.from) { $from = $msg.from } else { $from = "" }
    if ($msg.to) { $to = $msg.to } else { $to = "" }
    if ($msg.type) { $type = $msg.type } else { $type = "" }
    if ($msg.priority) { $priority = $msg.priority } else { $priority = "normal" }
    if ($msg.payload) { $payload = $msg.payload } else { $payload = "" }
    if ($msg.created) { $created = $msg.created } else { $created = Format-DateTime }

    # Determine target agent: field `to`, otherwise folder name
    if ($to -and $to -ne "") {
        $targetAgent = $to
    } else {
        $targetAgent = $agentName
    }

    $result.MessageId = $messageId
    $result.Agent = $targetAgent

    $startedAt = Format-DateTime

    # Interactive Telegram tasks (source=run/reply or from=telegram) are answered
    # by the agent's stdout itself, so the STATUS marker is optional for them.
    # Structured bus tasks keep the strict marker requirement.
    $requireMarker = -not (($msg.source -eq 'run') -or ($msg.source -eq 'reply') -or ($from -eq $script:TelegramFrom))
    if (-not $requireMarker) {
        Write-Log "ℹ️ Interactive task (source=$($msg.source), from=$from) — success = exit 0 + non-empty stdout"
    }

    # P1-1: atomic claim. If another worker already owns this message id, skip it
    # instead of running the same task twice (this is what lets the daemon run a
    # parallel pool without a global mutex).
    if (-not (Claim-Task -TaskId $messageId -Agent $targetAgent -LeaseSeconds $script:ClaimLeaseSeconds -StateDir $ClaimsDir)) {
        Write-Log "Already claimed by another worker — skipping: $messageId"
        $result.Status = "skipped"
        $result.Reason = "already-claimed"
        return $result
    }

    try {

    # Guard: empty payload → immediately dead-letter
    if (Check-Payload $msg) {
        Write-Log "💀 Empty payload — immediately dead-letter: $($messageId)"
        Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response "Empty payload — no task to process" -filePath $filePath
        $result.Status = "dead-letter"
        $result.Reason = "empty-payload"
        return $result
    }

    # Generate prompt (FIX: hardcoded path replaced with Join-Path)
    $contextBufferPath = Join-Path $Base "CONTEXT-BUFFER.md"
    $prompt = "You received a task from agent-hq bus. Read the last 30 lines of $contextBufferPath (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. CRITICAL: end your final answer with a line containing exactly 'STATUS: resolved' (or 'STATUS: done' if completed) in stdout, otherwise the run is treated as failed. TASK: $payload"

    if ($DryRun) {
        Write-Log "🔍 Dry run: would process with agent '$targetAgent'"
        Write-Log "🔍 Dry run prompt: $prompt"
        $result.Status = "dry-run"
        return $result
    }

    # Call opencode run --agent <name> "<prompt>" with a hard timeout
    # (prevents a hung agent from blocking the whole runner forever)
    # Machine-generated evidence (P0-C): the command string is recorded by the runtime.
    # Variant B: the plan says whether the keys come from the DPAPI vault (wrapper).
    $launchPlan = Get-OpencodeLaunchPlan
    $evidenceCommand = "$($launchPlan.Cli) run --agent $targetAgent"
    if ($launchPlan.UseVault) { $evidenceCommand += " [vault: run-with-secrets.ps1]" }

    Write-Log "🚀 Calling opencode run for agent: $targetAgent (timeout: $($script:JobTimeoutSeconds)s)"
    # Refresh the lease right before a possibly long run (RISK-001b).
    $null = Update-Heartbeat -TaskId $messageId -StateDir $ClaimsDir
    $attempt1 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt -TaskId $messageId -AttemptId "attempt-1" -Launch $launchPlan
    $success1 = Test-OpencodeSuccess $attempt1 -RequireMarker:$requireMarker
    $reason1 = if ($success1) { "" } else { Get-AttemptFailureReason $attempt1 -RequireMarker:$requireMarker }
    $status1 = if ($success1) { "success" } else { "failed" }
    $evidencePath = Write-AttemptEvidence -attempt $attempt1 -taskId $messageId -attemptId "attempt-1" `
        -agent $targetAgent -command $evidenceCommand -status $status1 -reason $reason1
    Write-Log "🧾 Evidence ($messageId/attempt-1): status=$status1, exit=$($attempt1.exitCode)"

    if ($success1) {
        # Success — write to outbox and archive
        Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response $attempt1.stdout -filePath $filePath -fullFileName $fullFileName -evidence $evidencePath
        $result.Status = "done"
        return $result
    }

    # Failed — 1 retry (also with timeout)
    Write-Log "❌ First attempt failed ($reason1), retrying..."
    # Heartbeat between attempts: attempt-1 may have consumed most of the lease.
    $null = Update-Heartbeat -TaskId $messageId -StateDir $ClaimsDir
    $attempt2 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt -TaskId $messageId -AttemptId "attempt-2" -Launch $launchPlan
    $success2 = Test-OpencodeSuccess $attempt2 -RequireMarker:$requireMarker
    $reason2 = if ($success2) { "" } else { Get-AttemptFailureReason $attempt2 -RequireMarker:$requireMarker }
    $status2 = if ($success2) { "success" } else { "failed" }
    $evidencePath = Write-AttemptEvidence -attempt $attempt2 -taskId $messageId -attemptId "attempt-2" `
        -agent $targetAgent -command $evidenceCommand -status $status2 -reason $reason2
    Write-Log "🧾 Evidence ($messageId/attempt-2): status=$status2, exit=$($attempt2.exitCode)"

    if ($success2) {
        Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response $attempt2.stdout -filePath $filePath -fullFileName $fullFileName -evidence $evidencePath
        $result.Status = "done"
        return $result
    }

    # Failed after retry → dead-letter with full stdout+stderr and reasons
    Write-Log "❌ Failed after 2 attempts — dead-letter: $messageId"
    $dlResponse = @(
        (Format-AttemptReport -reason "First attempt failed: $reason1" -attempt $attempt1),
        "",
        (Format-AttemptReport -reason "Retry failed: $reason2" -attempt $attempt2)
    ) -join "`n"
    Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
        -priority $priority -payload $payload -startedAt $startedAt `
        -response $dlResponse -filePath $filePath -evidence $evidencePath
    $result.Status = "dead-letter"
    $result.Reason = "failed-after-retry"
    return $result

    } finally {
        # P1-1: release the claim on every terminal path (success, dead-letter,
        # dry-run) and even on an unexpected error — no permanent lock.
        # RISK-001b: owner-guarded so a foreign (re-taken) lease is never deleted.
        $null = Release-Task -TaskId $messageId -Agent $targetAgent -StateDir $ClaimsDir
    }
}

# RISK-001: release leases whose heartbeat expired. Without a scheduled call a
# crashed worker keeps its claim forever, so the message is skipped as
# "Already claimed" until somebody runs a stale sweep by hand.
function Invoke-StaleClaimSweep {
    param([int]$TtlSeconds = 900)
    if (-not (Get-Command Revoke-StaleClaims -ErrorAction SilentlyContinue)) { return @() }
    try {
        $revoked = @(Revoke-StaleClaims -TtlSeconds $TtlSeconds -StateDir $ClaimsDir)
        foreach ($rc in $revoked) {
            Write-Log "♻️ Revoked stale claim: task '$($rc.task_id)' (age $($rc.age_seconds)s, owner '$($rc.agent)')"
        }
        return $revoked
    } catch {
        Write-Log "⚠️ Stale claim sweep failed: $($_.Exception.Message)"
        return @()
    }
}

# Scan the inbox of ALL agents in one pass and return a deterministic list:
#   [PSCustomObject]@{ FilePath; Agent; MessageId }  (MessageId = file base name)
function Get-PendingInboxItems {
    $items = @()
    if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) { return $items }

    $agentDirs = @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ".gitkeep" })
    foreach ($agentDir in $agentDirs) {
        $jsonFiles = @(Get-ChildItem -LiteralPath $agentDir.FullName -Filter "*.json" -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ".gitkeep" })
        foreach ($jsonFile in $jsonFiles) {
            $items += [PSCustomObject]@{
                FilePath  = $jsonFile.FullName
                Agent     = $agentDir.Name
                MessageId = $jsonFile.BaseName
            }
        }
    }
    return @($items | Sort-Object -Property FilePath)
}

# Serial processing: scan every agent inbox and process each message in order.
# The daemon does NOT use this — it keeps the same engine but runs a worker pool.
function Process-Inbox {
    # Schedule the sweep once per poll cycle, before any "Already claimed" skip.
    $null = Invoke-StaleClaimSweep -TtlSeconds 900

    foreach ($item in @(Get-PendingInboxItems)) {
        $null = Process-InboxFile -filePath $item.FilePath -agentName $item.Agent
    }
}
