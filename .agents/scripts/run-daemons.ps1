# run-daemons.ps1 — Запуск фоновых демонов agent-hq
# Запускать от имени пользователя (не от администратора)

$ErrorActionPreference = "Continue"
$Root = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# --- Session Recovery Daemon ---
# Singleton-lock уже реализован в скрипте (recovery.lock + PID-проверка):
# повторный запуск безопасен — если recovery.lock существует и процесс жив, скрипт завершится с кодом 0.
Start-Process powershell -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "$Root\.agents\scripts\session-recovery.ps1",
    '-Daemon'
) -WindowStyle Hidden

Write-Host "session-recovery daemon launched (hidden window)" -ForegroundColor Green
