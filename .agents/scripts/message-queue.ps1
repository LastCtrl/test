#!/usr/bin/env pwsh
# Message Queue System for agent-hq
# Управление inbox/outbox/dead-letter агентами

param(
    [string]$Action,
    [string]$AgentName,
    [string]$MessageId,
    [string]$From,
    [string]$To,
    [string]$Type,
    [string]$Priority,
    [string]$Payload,
    [string]$Days
)

$Base = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$Memory = Join-Path $Base ".memory"
$Inbox = Join-Path $Memory "inbox"
$Outbox = Join-Path $Memory "outbox"
$DeadLetter = Join-Path $Memory "dead-letter"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Все функции ниже возвращают $true только при ПОДТВЕРЖДЁННОМ результате
# (файл реально записан/прочитан/удалён). Ложный «успех» запрещён: при ошибке
# печатается статус FAILED и возвращается $false -> скрипт завершается с exit 1.
function Write-Log { param($msg) Write-Host "$(Get-Date -Format HH:mm:ss) $msg" }
function Write-Fail { param($msg) Write-Host "$(Get-Date -Format HH:mm:ss) ❌ FAILED: $msg" }

function New-Message {
    param($From, $To, $Type, $Priority, $Payload)
    $msg = @{
        id = [Guid]::NewGuid().Guid
        from = $From
        to = $To
        type = $Type
        priority = $Priority
        payload = $Payload
        created = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    }
    return $msg
}

function Send-Message {
    param($msg)

    if ($null -eq $msg -or [string]::IsNullOrWhiteSpace($msg.id) -or [string]::IsNullOrWhiteSpace($msg.to)) {
        Write-Fail "сообщение не сформировано (нужны -To; -From/-Type/-Priority/-Payload опциональны)"
        return $false
    }

    if (-not (Test-Path -LiteralPath $Outbox -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $Outbox -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Fail "не удалось создать каталог outbox '$Outbox': $($_.Exception.Message)"
            return $false
        }
        if (-not (Test-Path -LiteralPath $Outbox -PathType Container)) {
            Write-Fail "каталог outbox '$Outbox' не существует после создания"
            return $false
        }
    }

    $msgPath = Join-Path $Outbox "$($msg.id).json"
    try {
        $json = $msg | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($msgPath, $json, $utf8NoBom)
    } catch {
        Write-Fail "не удалось записать сообщение '$($msg.id)': $($_.Exception.Message)"
        return $false
    }

    # Честная проверка артефакта: файл существует и является валидным JSON.
    if (-not (Test-Path -LiteralPath $msgPath -PathType Leaf)) {
        Write-Fail "сообщение '$($msg.id)' отсутствует на диске после записи: $msgPath"
        return $false
    }
    try {
        $null = ConvertFrom-Json ([System.IO.File]::ReadAllText($msgPath, $utf8NoBom))
    } catch {
        Write-Fail "записанный файл '$msgPath' не является валидным JSON: $($_.Exception.Message)"
        return $false
    }

    Write-Log "✅ Сообщение отправлено: $($msg.id) → $($msg.to)"
    return $true
}

function Get-AgentInboxFiles {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return @()
    }
    $agentInbox = Join-Path $Inbox $Name
    if (-not (Test-Path -LiteralPath $agentInbox -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $agentInbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
}

function Receive-Message() {
    if ([string]::IsNullOrWhiteSpace($AgentName)) {
        Write-Fail "receive требует -AgentName"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) {
        Write-Fail "каталог inbox не найден: $Inbox"
        return $false
    }
    $agentInbox = Join-Path $Inbox $AgentName
    if (-not (Test-Path -LiteralPath $agentInbox -PathType Container)) {
        Write-Fail "нет inbox для агента '$AgentName': $agentInbox"
        return $false
    }

    Write-Log "📥 Чтение inbox для агента: $AgentName"
    $files = @(Get-AgentInboxFiles -Name $AgentName)
    if ($files.Count -eq 0) {
        Write-Log "inbox пуст: 0 сообщений"
        return $true
    }

    $invalid = 0
    foreach ($file in $files) {
        try {
            $json = ConvertFrom-Json ([System.IO.File]::ReadAllText($file.FullName, $utf8NoBom))
        } catch {
            Write-Fail "невалидный JSON в '$($file.Name)': $($_.Exception.Message)"
            $invalid++
            continue
        }
        Write-Host "┌─── Сообщение $($file.Name) ─────────────"
        Write-Host "│ From: $($json.from)"
        Write-Host "│ Type: $($json.type)"
        Write-Host "│ Priority: $($json.priority)"
        Write-Host "│ Payload: $($json.payload)"
        Write-Host "│ Created: $($json.created)"
        Write-Host "└─────────────────────────────────"
    }

    Write-Log "📥 Прочитано: $($files.Count - $invalid) из $($files.Count); невалидных: $invalid"
    if ($invalid -gt 0) { return $false }
    return $true
}

function List-Messages() {
    if ([string]::IsNullOrWhiteSpace($AgentName)) {
        Write-Fail "list требует -AgentName"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) {
        Write-Fail "каталог inbox не найден: $Inbox"
        return $false
    }
    $agentInbox = Join-Path $Inbox $AgentName
    if (-not (Test-Path -LiteralPath $agentInbox -PathType Container)) {
        Write-Fail "нет inbox для агента '$AgentName': $agentInbox"
        return $false
    }

    $files = @(Get-AgentInboxFiles -Name $AgentName)
    Write-Log "📋 Список сообщений в inbox для $AgentName ($($files.Count))"
    foreach ($file in $files) { Write-Host "  - $($file.BaseName)" }
    return $true
}

function Archive-Old {
    param($Days)

    $daysInt = 0
    if (-not [int]::TryParse([string]$Days, [ref]$daysInt) -or $daysInt -lt 1) {
        Write-Fail "archive требует -Days (целое число >= 1)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Outbox -PathType Container)) {
        Write-Fail "каталог outbox не найден: $Outbox"
        return $false
    }

    $cutoff = (Get-Date).AddDays(-$daysInt)
    $old = @(Get-ChildItem -LiteralPath $Outbox -File -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt $cutoff })

    $removed = 0
    $failed = 0
    foreach ($file in $old) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed++
            Write-Log "📦 Архивировано старое сообщение: $($file.Name)"
        } catch {
            Write-Fail "не удалось удалить '$($file.Name)': $($_.Exception.Message)"
            $failed++
        }
    }

    if ($failed -gt 0) {
        Write-Fail "архивирование завершено с ошибками: удалено $removed из $($old.Count), ошибок $failed"
        return $false
    }
    Write-Log "✅ Архивирование завершено: удалено $removed из $($old.Count) (старше $daysInt дней)"
    return $true
}

function Show-DeadLetter {
    if (-not (Test-Path -LiteralPath $DeadLetter -PathType Container)) {
        Write-Fail "каталог dead-letter не найден: $DeadLetter"
        return $false
    }
    Write-Log "💀 Dead Letter Queue: просмотр упавших задач"
    $files = @(Get-ChildItem -LiteralPath $DeadLetter -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if ($files.Count -eq 0) { Write-Log "dead-letter пуст: 0 файлов" }
    foreach ($file in $files) { Write-Host "Файл: $($file.Name)" }
    return $true
}

function Invoke-Scan {
    $agentCount = 0
    $messageCount = 0

    if (Test-Path -LiteralPath $Inbox -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -eq '.gitkeep') { continue }
            $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
            $agentCount++
            $messageCount += $files.Count
            Write-Log "📭 Inbox for: $($dir.Name) — $($files.Count) сообщений"
            foreach ($file in $files) { Write-Host "  Ид: $($file.BaseName) — ожидает обработки" }
        }
    } else {
        Write-Fail "каталог inbox не найден: $Inbox (скан не выполнен)"
        return $false
    }

    $outboxCount = 0
    if (Test-Path -LiteralPath $Outbox -PathType Container) {
        $outboxCount = @(Get-ChildItem -LiteralPath $Outbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    }
    Write-Log "📊 Сканирование: агентов с inbox=$agentCount, входящих сообщений=$messageCount, файлов в outbox=$outboxCount (отправка не выполнялась)"
    return $true
}

# Обработка действий. $ok == $null означает, что действие не выбрано.
$ok = $null

if ([string]::IsNullOrWhiteSpace($Action)) {
    $ok = Invoke-Scan
} else {
    switch ($Action) {
        "receive" { $ok = Receive-Message }
        "list" { $ok = List-Messages }
        "send" {
            $msg = New-Message -From $From -To $To -Type $Type -Priority $Priority -Payload $Payload
            $ok = Send-Message $msg
        }
        "archive" { $ok = Archive-Old $Days }
        "dead-letter" { $ok = Show-DeadLetter }
        default {
            Write-Fail "неизвестное действие: '$Action'"
            Write-Log "Доступные действия: receive, list, send, archive, dead-letter"
            $ok = $false
        }
    }
}

# Exit code отражает реальный результат: 0 только при подтверждённом успехе.
if ($ok) { exit 0 } else { exit 1 }