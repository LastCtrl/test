# Runner for inbox poller - avoids path issues
param([switch]$DryRun)

$Base = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$Memory = Join-Path $Base '.memory'
$Inbox = Join-Path $Memory 'inbox'
$Traces = Join-Path $Memory 'traces'
$logPath = Join-Path $Memory 'traces' 'poller.log'
$utf8NoBom = [System.Text.Encoding]::GetEncoding(65001)

# Ensure log file exists
if (-not (Test-Path $logPath)) {
    [System.IO.File]::WriteAllText($logPath, '', $utf8NoBom)
}

function Write-Log {
    param($msg)
    $ts = (Get-Date).HH:mm:ss
    $logLine = "$ts $msg"
    Write-Host $logLine
    [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $utf8NoBom)
}

Write-Log '🔍 Dry run mode — showing plan only'
$agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne '.gitkeep' }
$foundMessages = $false

foreach ($agentDir in $agentDirs) {
    $agentName = $agentDir.Name
    $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName '*.json') -Force | Where-Object { $_.Name -ne '.gitkeep' }
    foreach ($jsonFile in $jsonFiles) {
        $foundMessages = $true
        Write-Log '📄 Inbox file: ' + $jsonFile.Name + ' for agent: ' + $agentName
    }
}

if (-not $foundMessages) {
    Write-Log 'ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)'
    Write-Host 'ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)'
}

Write-Host '--- Dry Run Complete: 0 messages processed ---'