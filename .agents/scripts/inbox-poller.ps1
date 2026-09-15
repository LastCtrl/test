# Inbox Poller for agent-hq — auto-launches inbox workers
# Monitors .memory\inbox\{agent}\*.json and processes messages via opencode

param(
    [switch]$Once,
    [int]$IntervalSeconds = 30,
    [switch]$DryRun
)

$Base = "D:\Тест\agent-hq"
$Memory = Join-Path $Base ".memory"
$Inbox = Join-Path $Memory "inbox"
$Outbox = Join-Path $Memory "outbox"
$Archive = Join-Path $Memory "archive"
$DeadLetter = Join-Path $Memory "dead-letter"
$Traces = Join-Path $Memory "traces"
$TasksDir = Join-Path $Base ".agents\tasks"

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

# Global mutex to prevent concurrent execution
$mutexName = "agent-hq-poller-mutex"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$bCreated = $mutex.WaitOne(0)
if (-not $bCreated) {
    Write-Log "❌ Another instance is already running. Exit 1."
    exit 1
}

# Guard: check opencode in PATH
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
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
        [string]$filePath
    )
    $dlFinishedAt = Format-DateTime
    $dlMsg = @{
        id = $messageId
        from = $from
        to = $targetAgent
        type = "failed"
        priority = $priority
        payload = $payload
        status = "failed"
        startedAt = $startedAt
        finishedAt = $dlFinishedAt
        response = $response
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
        [string]$fullFileName
    )
    # Truncate overly long responses
    if ($response.Length -gt $maxResponseLength) {
        $response = $response.Substring(0, $maxResponseLength)
    }

    $outboxMsg = @{
        id = $messageId
        from = $from
        to = $targetAgent
        type = "result"
        priority = $priority
        payload = $payload
        status = "done"
        startedAt = $startedAt
        finishedAt = Format-DateTime
        response = $response
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

# Run opencode in a background job, capturing stdout/stderr separately and the REAL exit code.
# Returns: [PSCustomObject]@{ stdout; stderr; exitCode }  (never a bare string)
function Invoke-OpencodeAttempt {
    param([string]$targetAgent, [string]$taskPrompt)

    $job = Start-Job -ScriptBlock {
        param($agent, $taskPrompt)
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $stdout = & opencode run --agent $agent $taskPrompt 2>$errFile
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
        if ($null -eq $res) {
            return [PSCustomObject]@{ stdout = ""; stderr = "Job produced no result object"; exitCode = 1 }
        }
        return $res
    }

    Stop-Job -Job $job -Force
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Log "⏱️ TIMEOUT $($script:JobTimeoutSeconds)s: agent '$targetAgent' hung — job killed"
    return [PSCustomObject]@{
        stdout   = "TIMEOUT: agent '$targetAgent' did not respond in $($script:JobTimeoutSeconds) seconds"
        stderr   = ""
        exitCode = 124
    }
}

# Success ONLY when: exit code == 0 AND stdout has the explicit success marker AND stderr has no error markers.
# A non-empty error text (stderr) or unmatched stdout is NOT success.
function Test-OpencodeSuccess {
    param($attempt)
    if ($null -eq $attempt) { return $false }
    if ($attempt.exitCode -ne 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return $false }
    if ($attempt.stderr -match $script:ErrorMarker) { return $false }
    if ($attempt.stdout -notmatch $script:SuccessMarker) { return $false }
    return $true
}

function Get-AttemptFailureReason {
    param($attempt)
    if ($null -eq $attempt) { return "no result object" }
    if ($attempt.exitCode -ne 0) { return "exit code $($attempt.exitCode)" }
    if ([string]::IsNullOrWhiteSpace($attempt.stdout)) { return "empty stdout" }
    if ($attempt.stderr -match $script:ErrorMarker) { return "stderr error: '$($matches[0])'" }
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
    Write-Log "🚀 Calling opencode run for agent: $targetAgent (timeout: $($script:JobTimeoutSeconds)s)"
    $attempt1 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt

    if (Test-OpencodeSuccess $attempt1) {
        # Success — write to outbox and archive
        Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
            -priority $priority -payload $payload -startedAt $startedAt `
            -response $attempt1.stdout -filePath $filePath -fullFileName $fullFileName
    } else {
        # Failed — 1 retry (also with timeout)
        Write-Log "❌ First attempt failed ($(Get-AttemptFailureReason $attempt1)), retrying..."
        $attempt2 = Invoke-OpencodeAttempt -targetAgent $targetAgent -taskPrompt $prompt

        if (Test-OpencodeSuccess $attempt2) {
            Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
                -priority $priority -payload $payload -startedAt $startedAt `
                -response $attempt2.stdout -filePath $filePath -fullFileName $fullFileName
        } else {
            # Failed after retry → dead-letter with full stdout+stderr and reasons
            Write-Log "❌ Failed after 2 attempts — dead-letter: $messageId"
            $dlResponse = @(
                (Format-AttemptReport -reason "First attempt failed: $(Get-AttemptFailureReason $attempt1)" -attempt $attempt1),
                "",
                (Format-AttemptReport -reason "Retry failed: $(Get-AttemptFailureReason $attempt2)" -attempt $attempt2)
            ) -join "`n"
            Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
                -priority $priority -payload $payload -startedAt $startedAt `
                -response $dlResponse -filePath $filePath
        }
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
