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

function Write-Log { param($msg) Write-Host "$(Get-Date -Format HH:mm:ss) $msg" }

function New-Message {
    param($From, $To, $Type, $Priority, $Payload)
    $msg = @{
        id = [Guid]::NewGuid().Guid
        from = $From
        to = $To
        type = $Type
        priority = $Priority
        payload = $Payload
        created = (Get-Date).yyyy-MM-ddTHH:mm:ss
    }
    return $msg
}

function Send-Message {
    param($msg)
    $msgPath = Join-Path $Outbox "$($msg.id).json"
    $msg | ConvertTo-Json -Depth 3 | Out-File -FilePath $msgPath -Encoding UTF8
    Write-Log "✅ Сообщение отправлено: $($msg.id) → $($msg.to)"
}

function Receive-Message() {
    Write-Log "📥 Чтение inbox для агента: $AgentName"
    $pattern = Join-Path $Inbox "$AgentName\*"
    Get-ChildItem $pattern | ForEach-Object {
        $content = Get-Content $_.FullName -Encoding UTF8
        Write-Host "┌─── Сообщение $($_.Name) ─────────────"
        Write-Host "│ Type: $($_.BaseName)"
        $json = ConvertFrom-Json $content
        Write-Host "│ From: $($json.from)"
        Write-Host "│ Type: $($json.type)"
        Write-Host "│ Priority: $($json.priority)"
        Write-Host "│ Payload: $($json.payload)"
        Write-Host "│ Created: $($json.created)"
        Write-Host "└─────────────────────────────────"
    }
}

function List-Messages() {
    Write-Log "📋 Список сообщений в inbox для $AgentName"
    Get-ChildItem (Join-Path $Inbox "$AgentName\*") | ForEach-Object {
        Write-Host "  - $($_.BaseName)"
    }
}

function Archive-Old {
    param($Days)
    $cutoff = (Get-Date).AddDays(-$Days)
    Get-ChildItem $Outbox | Where-Object { $_.CreationTime -lt $cutoff } | ForEach-Object {
        Remove-Item $_.FullName
        Write-Log "📦 Архивировано старое сообщение: $($_.Name)"
    }
    Write-Log "✅ Арşivовка завершена (старше $Days дней)"
}

# Обработка действий
switch ($Action) {
    "receive" { Receive-Message }
    "list" { List-Messages }
    "send" { Send-Message $Payload }
    "archive" { Archive-Old $Days }
    dead-letter { 
        Write-Log "💀 Dead Letter Queue: просмотр упавших задач"
        Get-ChildItem $DeadLetter | ForEach-Object { Write-Host "Файл: $($_.Name)" }
    }
    default { 
        Write-Log "Доступные действия: receive, list, send, archive, dead-letter"
        Write-Log "Или просто запускайте скрипт для автоматической обработки inbox"
    }
}

# Автоматическая обработка при запуске без аргументов
if ($Actions.Count -eq 0) {
    Write-Log "🔍 Проверка inbox для всех агентов..."
    Get-ChildItem $Inbox -Recurse | ForEach-Object {
        $agent = $_.Directory.Name
        Write-Log "📭 Inbox for: $agent"
        foreach ($msg in (Get-ChildItem $_.FullName)) {
            Write-Host "  Ид: $($msg.BaseName) — требует внимания"
        }
    }
    Write-Log "📤 Проверка outbox для отправленных задач..."
    Get-ChildItem $Outbox | ForEach-Object {
        Write-Host "  📤 $($_.Name) — уже отправлено"
    }
}