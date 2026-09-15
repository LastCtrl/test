# Inbox Poller for agent-hq — auto-launches inbox workers
# Monitors .memory\inbox\{agent}\*.json and processes messages via opencode

param(
    [switch]$Once,
    [int]$IntervalSeconds = 30,
    [switch]$DryRun
)

$Base = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$Memory = Join-Path $Base ".memory"
$Inbox = Join-Path $Memory "inbox"
$Outbox = Join-Path $Memory "outbox"
$Archive = Join-Path $Memory "archive"
$DeadLetter = Join-Path $Memory "dead-letter"
$Traces = Join-Path $Memory "traces"
$TasksDir = Join-Path $Base ".agents\tasks"
$ClaimsDir = Join-Path $Memory "claims"

# --- Global constants (DRY: magic numbers & encoding) ---
$script:Utf8NoBom = [System.Text.Encoding]::GetEncoding(65001)
$maxResponseLength = 4000

# Ensure required directories exist
@($Inbox, $Outbox, $Archive, $DeadLetter, $Traces, $TasksDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# Logging function: Write-Host with timestamp + append to .memory\traces\poller.log
function Write-Log {
    param($msg)
    try {
        $date = Get-Date -Format "HH:mm:ss"
        $logLine = "$date $msg"
        Write-Host $logLine
        $logPath = Join-Path $Traces "poller.log"
        [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $script:Utf8NoBom)
    } catch {
        # Fallback: if file logging fails, at least Write-Host already worked above
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [LOG-ERROR] Failed to write log: $($_.Exception.Message)"
    }
}

# --- Secret redaction (P0-D): dot-source the helper that masks credentials before
# ANY agent output or message payload is persisted to outbox/dead-letter.
# A missing helper degrades to a logged no-op instead of crashing the poller.
$redactHelperPath = Join-Path $PSScriptRoot "redact.ps1"
if (Test-Path -LiteralPath $redactHelperPath) {
    . $redactHelperPath
} else {
    Write-Log "⚠️ redact.ps1 not found at $redactHelperPath — secret redaction DISABLED"
    function Redact-Secrets { param([string]$Text) return $Text }
}

# --- Machine-generated evidence (P0-C): dot-source the runtime evidence writer.
# The poller (not the model under test) records exit codes/hashes/timing here.
$script:EvidenceAvailable = $false
$evidenceWriterPath = Join-Path $PSScriptRoot "evidence-writer.ps1"
if (Test-Path -LiteralPath $evidenceWriterPath) {
    . $evidenceWriterPath
    $script:EvidenceAvailable = $true
} else {
    Write-Log "⚠️ evidence-writer.ps1 not found at $evidenceWriterPath — evidence records disabled"
}

# --- Task claims (P1-1): dot-source the file-atomic claim/lease helper. It lets
# concurrent poller instances skip messages another instance already owns. A
# missing helper degrades to no-op stubs instead of crashing the poller.
$taskStateHelperPath = Join-Path $PSScriptRoot "task-state.ps1"
if (Test-Path -LiteralPath $taskStateHelperPath) {
    . $taskStateHelperPath
} else {
    Write-Log "⚠️ task-state.ps1 not found at $taskStateHelperPath — task claims DISABLED"
    function Claim-Task {
        param([AllowEmptyString()][string]$TaskId, [string]$Agent = "", [int]$LeaseSeconds = 900, [string]$StateDir)
        return $true
    }
    function Release-Task {
        param([AllowEmptyString()][string]$TaskId, [string]$StateDir)
        return $true
    }
}

# Global mutex to prevent concurrent execution
$mutexName = "agent-hq-poller-mutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$bCreated = $mutex.WaitOne(0)
if (-not $bCreated) {
    Write-Log "❌ Another instance is already running. Exit 1."
    exit 1
}

# Resolve the CLI to invoke: env override (used by tests) or plain `opencode` from PATH.
$script:OpencodeCmd = if ($env:AGENT_HQ_OPENCODE) { $env:AGENT_HQ_OPENCODE } else { "opencode" }

# Guard: check the RESOLVED command is available
if ($env:AGENT_HQ_OPENCODE) {
    if (-not (Test-Path -LiteralPath $script:OpencodeCmd)) {
        Write-Log "❌ AGENT_HQ_OPENCODE is set but path not found: $script:OpencodeCmd. Exit 1."
        exit 1
    }
} elseif (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Log "❌ opencode not found in PATH. Install opencode or add to PATH. Exit 1."
    exit 1
}

# Syntax check using PSParser
$scriptPath = $MyInvocation.MyCommand.Definition
try {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $scriptPath), [ref]$null) | Out-Null
    Write-Log "✅ Syntax check passed (PSParser)"
} catch {
    Write-Log "❌ Syntax check failed (PSParser). Exit 1."
    exit 1
}

# --- DRY: Save TZ copy BEFORE the main loop (was dead code after infinite loop) ---
$tzCopyPath = (Join-Path $TasksDir "task-inbox-poller.txt")
if (-not (Test-Path $tzCopyPath)) {
    Write-Log "📄 Saving TZ copy to: $tzCopyPath"
    try {
        $scriptContent = Get-Content -Path $scriptPath -ErrorAction Stop
        [System.IO.File]::WriteAllText($tzCopyPath, ($scriptContent -join "`n"), $script:Utf8NoBom)
        Write-Log "✅ TZ copy saved successfully"
    } catch {
        Write-Log "⚠️ Failed to save TZ copy: $($_.Exception.Message)"
    }
}

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

# --- Result definition (DRY): success = real exit code 0 + explicit marker + clean stderr ---
$script:SuccessMarker = '(?i)STATUS:\s*(resolved|done|completed)'
$script:ErrorMarker = '(?i)(not found|permission denied|auto-rejecting|rejected permission|Error:)'
$script:JobTimeoutSeconds = 900
if ($env:AGENT_HQ_JOB_TIMEOUT) {
    $envTimeout = 0
    if ([int]::TryParse($env:AGENT_HQ_JOB_TIMEOUT, [ref]$envTimeout) -and $envTimeout -gt 0) {
        $script:JobTimeoutSeconds = $envTimeout
    } else {
        Write-Log "⚠️ Ignoring invalid AGENT_HQ_JOB_TIMEOUT='$env:AGENT_HQ_JOB_TIMEOUT' (expected positive integer seconds)"
    }
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
    param([string]$targetAgent, [string]$taskPrompt)

    $startedAt = Get-Date

    $job = Start-Job -ScriptBlock {
        param($agent, $taskPrompt)
        # Resolve the CLI inside the job: the Start-Job child process inherits env vars.
        $opencodeCmd = if ($env:AGENT_HQ_OPENCODE) { $env:AGENT_HQ_OPENCODE } else { "opencode" }
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & $opencodeCmd run --agent $agent $taskPrompt 2>$errFile
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
    } -ArgumentList $targetAgent, $taskPrompt

    $completed = Wait-Job -Job $job -Timeout $script:JobTimeoutSeconds
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

# Success ONLY when: exit code == 0 AND stdout has the explicit success marker AND stderr has no error markers.
# A non-empty error text (stderr) or unmatched stdout is NOT success.
function Test-OpencodeSuccess {
    param($attempt)
    if ($null -eq $attempt) { return $false }
    if ($attempt.exitCode -ne 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return $false }
    # Error markers anywhere in the captured output (stdout or stderr) mean failure.
    if (("$($attempt.stdout)`n$($attempt.stderr)") -match $script:ErrorMarker) { return $false }
    if ($attempt.stdout -notmatch $script:SuccessMarker) { return $false }
    return $true
}

function Get-AttemptFailureReason {
    param($attempt)
    if ($null -eq $attempt) { return "no result object" }
    if ($attempt.exitCode -ne 0) { return "exit code $($attempt.exitCode)" }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return "empty stdout" }
    if (("$($attempt.stdout)`n$($attempt.stderr)") -match $script:ErrorMarker) { return "error marker in output: '$($matches[0])'" }
    if ($attempt.stdout -notmatch $script:SuccessMarker) { return "missing success marker '$($script:SuccessMarker)'" }
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

# Build ONE machine evidence record from an attempt object. Called by the poller
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

# Process a single inbox file
function Process-InboxFile {
    param($filePath, $agentName)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $fullFileName = [System.IO.Path]::GetFileName($filePath)

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
        return
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

    $startedAt = Format-DateTime

    # P1-1: atomic claim. If another worker already owns this message id, skip it
    # instead of running the same task twice. The body below is intentionally left
    # at its original indentation to keep the diff small (PowerShell ignores it).
    if (-not (Claim-Task -TaskId $messageId -Agent $targetAgent -StateDir $ClaimsDir)) {
        Write-Log "Already claimed by another worker — skipping: $messageId"
        return
    }

    try {

    # Guard: empty payload → immediately dead-letter
    if (Check-Payload $msg) {
        Write-Log "💀 Empty payload — immediately dead-letter: $($messageId)"
        Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response "Empty payload — no task to process" -filePath $filePath
        return
    }

    # Generate prompt (FIX: hardcoded path replaced with Join-Path)
    $contextBufferPath = Join-Path $Base "CONTEXT-BUFFER.md"
    $prompt = "You received a task from agent-hq bus. Read the last 30 lines of $contextBufferPath (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. CRITICAL: end your final answer with a line containing exactly 'STATUS: resolved' (or 'STATUS: done' if completed) in stdout, otherwise the run is treated as failed. TASK: $payload"

    if ($DryRun) {
        Write-Log "🔍 Dry run: would process with agent '$targetAgent'"
        Write-Log "🔍 Dry run prompt: $prompt"
        return
    }

    # Call opencode run --agent <name> "<prompt>" with 15-min hard timeout
    # (prevents a hung agent from blocking the whole poller cycle forever)
    # Machine-generated evidence (P0-C): the command string is recorded by the runtime.
    $evidenceCommand = "$($script:OpencodeCmd) run --agent $targetAgent"

    Write-Log "🚀 Calling opencode run for agent: $targetAgent (timeout: $($script:JobTimeoutSeconds)s)"
    $attempt1 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt
    $success1 = Test-OpencodeSuccess $attempt1
    $reason1 = if ($success1) { "" } else { Get-AttemptFailureReason $attempt1 }
    $status1 = if ($success1) { "success" } else { "failed" }
    $evidencePath = Write-AttemptEvidence -attempt $attempt1 -taskId $messageId -attemptId "attempt-1" `
        -agent $targetAgent -command $evidenceCommand -status $status1 -reason $reason1
    Write-Log "🧾 Evidence ($messageId/attempt-1): status=$status1, exit=$($attempt1.exitCode)"

    if ($success1) {
        # Success — write to outbox and archive
        Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response $attempt1.stdout -filePath $filePath -fullFileName $fullFileName -evidence $evidencePath
    } else {
        # Failed — 1 retry (also with timeout)
        Write-Log "❌ First attempt failed ($reason1), retrying..."
        $attempt2 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt
        $success2 = Test-OpencodeSuccess $attempt2
        $reason2 = if ($success2) { "" } else { Get-AttemptFailureReason $attempt2 }
        $status2 = if ($success2) { "success" } else { "failed" }
        $evidencePath = Write-AttemptEvidence -attempt $attempt2 -taskId $messageId -attemptId "attempt-2" `
            -agent $targetAgent -command $evidenceCommand -status $status2 -reason $reason2
        Write-Log "🧾 Evidence ($messageId/attempt-2): status=$status2, exit=$($attempt2.exitCode)"

        if ($success2) {
            Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
                -priority $priority -payload $payload -startedAt $startedAt `
                -response $attempt2.stdout -filePath $filePath -fullFileName $fullFileName -evidence $evidencePath
        } else {
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
        }
    }
    } finally {
        # P1-1: release the claim on every terminal path (success, dead-letter,
        # dry-run) and even on an unexpected error — no permanent lock.
        $null = Release-Task -TaskId $messageId -StateDir $ClaimsDir
    }
}

# Main processing: scan .memory\inbox\{agent}\*.json
function Process-Inbox {
    $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }

    foreach ($agentDir in $agentDirs) {
        $agentName = $agentDir.Name
        $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }

        foreach ($jsonFile in $jsonFiles) {
            Process-InboxFile -filePath $jsonFile.FullName -agentName $agentName
        }
    }
}

# Dry run mode — show plan, nothing executes
if ($DryRun) {
    Write-Log "🔍 Dry run mode — showing plan only"

    $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }
    $foundMessages = $false

    foreach ($agentDir in $agentDirs) {
        $agentName = $agentDir.Name
        $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }

        foreach ($jsonFile in $jsonFiles) {
            $foundMessages = $true
            Write-Log "📄 Inbox file: $($jsonFile.Name) for agent: $agentName"
        }
    }

    if (-not $foundMessages) {
        Write-Log "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
        Write-Host "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
    }

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
