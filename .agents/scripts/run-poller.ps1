# Runner for inbox poller - avoids path issues
# NOTE: this runner only SCANS the inbox and reports the real counts; it does not
# process messages. It must never report "0 messages processed" when messages exist.
param([switch]$DryRun)

$Base = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$Memory = Join-Path $Base '.memory'
$Inbox = Join-Path $Memory 'inbox'
$logPath = Join-Path (Join-Path $Memory 'traces') 'poller.log'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:LogFailed = $false

# Ensure log directory + log file exist (fail loudly instead of continuing blind)
$tracesDir = Split-Path -Path $logPath -Parent
if (-not (Test-Path -LiteralPath $tracesDir -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $tracesDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "❌ FAILED: cannot create log directory '$tracesDir': $($_.Exception.Message)"
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    try {
        [System.IO.File]::WriteAllText($logPath, '', $utf8NoBom)
    } catch {
        Write-Host "❌ FAILED: cannot create log file '$logPath': $($_.Exception.Message)"
        exit 1
    }
}

function Write-Log {
    param($msg)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $logLine = "$ts $msg"
    Write-Host $logLine
    try {
        [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $utf8NoBom)
    } catch {
        $script:LogFailed = $true
        Write-Host "❌ FAILED: cannot append to log '$logPath': $($_.Exception.Message)"
    }
}

if ($DryRun) {
    Write-Log '🔍 Dry run mode — scan only, no processing'
} else {
    Write-Log '🔍 Scan mode — this runner counts inbox messages, it does not process them'
}

if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) {
    Write-Log "❌ Inbox directory not found: $Inbox"
    exit 1
}

$agentDirs = @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
$foundMessages = 0

foreach ($agentDir in $agentDirs) {
    $agentName = $agentDir.Name
    $jsonFiles = @(Get-ChildItem -LiteralPath $agentDir.FullName -Filter '*.json' -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    foreach ($jsonFile in $jsonFiles) {
        $foundMessages++
        Write-Log ('📄 Inbox file: ' + $jsonFile.Name + ' for agent: ' + $agentName)
    }
}

if ($foundMessages -eq 0) {
    Write-Log 'ℹ️ No messages in inbox — 0 messages found'
} else {
    Write-Log "📨 Found $foundMessages message(s) in $($agentDirs.Count) agent inbox(es) — not processed by this runner"
}

Write-Log "--- Runner complete: scanned $($agentDirs.Count) inbox(es), found $foundMessages message(s) ---"

if ($script:LogFailed) { exit 1 } else { exit 0 }