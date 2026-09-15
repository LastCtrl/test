# session-recovery.ps1 — Автовосстановление сессий при lock conflict
# Запускается в фоне, мониторит .local/share/opencode/snapshot/ на ошибки

param(
    [int]$CheckIntervalSec = 10,
    [int]$MaxRetries = 3,
    [switch]$Daemon
)

$ErrorActionPreference = "Continue"

$RepoRoot = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$SnapshotsDir = Join-Path $env:LOCALAPPDATA "opencode\snapshot"
$LockFile = Join-Path $SnapshotsDir "recovery.lock"
$LogFile = Join-Path $SnapshotsDir "recovery.log"

# Ensure directories exist
if (-not (Test-Path $SnapshotsDir)) {
    New-Item -ItemType Directory -Path $SnapshotsDir -Force | Out-Null
}

function Write-Log {
    param($msg)
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$timestamp $msg" | Add-Content -Path $LogFile -Encoding UTF8
    Write-Host "$timestamp $msg" -ForegroundColor Cyan
}

function Test-LockConflict {
    # Проверяем недавние ошибки в трейсах
    $TracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
    $TracesPath = Join-Path $TracesDir "traces.jsonl"
    if (-not (Test-Path $TracesPath)) { return $false }

    $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-2)
    $lines = Get-Content $TracesPath -Tail 20 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -eq $obj) { continue }
            if ($obj.type -eq "error" -and $obj.ts) {
                $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
                if ($ts -ge $cutoff -and $obj.message -match "Busy|FileSystem\.writeFile|exclude") {
                    return $true
                }
            }
        } catch { continue }
    }
    return $false
}

function Get-FreeTeamLeadCopy {
    # Проверяем какие team-lead копии свободны (нет активной задачи в inbox)
    $Root = $RepoRoot
    $InboxDir = Join-Path $Root ".memory\inbox"
    $copies = @("team-lead", "team-lead-1", "team-lead-2", "team-lead-3")
    foreach ($copy in $copies) {
        $agentInbox = Join-Path $InboxDir $copy
        if (Test-Path $agentInbox) {
            $files = Get-ChildItem -Path $agentInbox -Filter "*.json" -File -ErrorAction SilentlyContinue
            if ($files.Count -eq 0) {
                return $copy
            }
        } else {
            return $copy
        }
    }
    return $null
}

function Delegate-To-Copy {
    param($copyName, $originalTask)

    Write-Log "DELEGATE: Переделегирование на $copyName"

    # Создаём задачу в inbox копии
    $InboxDir = Join-Path (Join-Path $RepoRoot ".memory\inbox") $copyName
    if (-not (Test-Path $InboxDir)) {
        New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null
    }

    $taskId = "recovery-$(Get-Random -Minimum 10000 -Maximum 99999)"
    $task = @{
        id = $taskId
        from = "session-recovery"
        to = $copyName
        type = "task"
        priority = "high"
        payload = $originalTask
        created = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        recovery = $true
        retry_count = 0
    } | ConvertTo-Json -Depth 4

    $taskPath = Join-Path $InboxDir "$taskId.json"
    [System.IO.File]::WriteAllText($taskPath, $task, (New-Object System.Text.UTF8Encoding($false)))

    Write-Log "DELEGATE: Задача $taskId создана в $copyName inbox"

    # Записываем в CONTEXT-BUFFER.md
    $bufferPath = Join-Path $RepoRoot "CONTEXT-BUFFER.md"
    $tsNow = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $entry = "[$tsNow] session-recovery -> ${copyName}:`nTYPE: update | PRIORITY: high`nCONTENT: Auto-recovery delegation from crashed session. Original task: $originalTask. Delegated to ${copyName}.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: [""context7: offline"", ""sequential-thinking: offline""]`nCOMPLIANCE: true`nSTATUS: resolved`n"
    Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
}

function Main-Loop {
    Write-Log "START: session-recovery daemon started (interval: ${CheckIntervalSec}s)"

    while ($true) {
        try {
            if (Test-LockConflict) {
                Write-Log "DETECTED: Lock conflict detected"

                $freeCopy = Get-FreeTeamLeadCopy
                if ($freeCopy) {
                    Write-Log "FREE COPY: $freeCopy available"

                    # Читаем последнюю задачу из CONTEXT-BUFFER
                    $bufferPath = Join-Path $RepoRoot "CONTEXT-BUFFER.md"
                    if (Test-Path $bufferPath) {
                        $content = Get-Content $bufferPath -Raw
                        # Ищем последнюю задачу пользователя
                        $pattern = '\[(?<time>[\d\-T:]+)\]\s+(?<agent>\S+)\s+>>\s+team-lead:.*?CONTENT:\s*(?<content>.*?)(?=\[|\Z)'
                        $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
                        if ($match.Success) {
                            $taskContent = $match.Groups['content'].Value.Trim()
                            Delegate-To-Copy -copyName $freeCopy -originalTask $taskContent
                        } else {
                            Delegate-To-Copy -copyName $freeCopy -originalTask "Recover from lock conflict - continue previous task"
                        }
                    }

                    # Ждём пока новая сессия поднимется
                    Start-Sleep -Seconds 30
                } else {
                    Write-Log "NO FREE COPY: All team-lead copies busy"
                    # Записываем blocker
                    $bufferPath = Join-Path $RepoRoot "CONTEXT-BUFFER.md"
                    $tsNow2 = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
                    $entry = "[$tsNow2] session-recovery -> team-lead:`nTYPE: blocker | PRIORITY: critical`nCONTENT: Lock conflict detected but ALL team-lead copies busy. Manual intervention needed.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: []`nCOMPLIANCE: false`nSTATUS: open`n"
                    Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
                }
            }
        } catch {
            Write-Log "ERROR: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $CheckIntervalSec
    }
}

# Singleton lock
if (Test-Path $LockFile) {
    $existingPid = Get-Content $LockFile -ErrorAction SilentlyContinue
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "Another recovery daemon already running (PID: $existingPid)" -ForegroundColor Yellow
        exit 0
    }
}
$currentPid = $PID
$currentPid | Out-File -FilePath $LockFile -Encoding UTF8

try {
    if ($Daemon) {
        Main-Loop
    } else {
        # One-shot check
        if (Test-LockConflict) {
            Write-Host "Lock conflict detected!" -ForegroundColor Red
            $freeCopy = Get-FreeTeamLeadCopy
            if ($freeCopy) {
                Write-Host "Free copy available: $freeCopy" -ForegroundColor Green
                exit 0
            } else {
                Write-Host "No free copies" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "No lock conflicts" -ForegroundColor Green
            exit 0
        }
    }
} finally {
    if (Test-Path $LockFile) { Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue }
}