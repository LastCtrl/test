<#
.SYNOPSIS
    Удаляет plaintext-ключи провайдеров из пользовательского окружения (HKCU\Environment).

.DESCRIPTION
    Вариант B: ключи провайдеров должны жить ТОЛЬКО в DPAPI-vault и подкладываться в
    окружение дочернего процесса на время запуска через run-with-secrets.ps1.
    Значения, оставшиеся в HKCU\Environment от прежней схемы, надо убрать.

    Без параметров (и с -DryRun) — РЕЖИМ ПРОСМОТРА: печатает, что БУДЕТ удалено, и
    ничего не меняет. Реальное удаление — только с -Apply.

    Значения ключей НИКОГДА не печатаются: выводится только имя, факт наличия и
    действие. В лог/память/файлы значения не попадают.

    Границы:
      * Затрагивается только HKCU (по умолчанию HKCU:\Environment) — пользовательская
        зона. HKLM и HKCU\SOFTWARE\Policies не читаются и не изменяются.
      * Ключи в vault (secret.<имя>.enc) не трогаются — удаляется только копия в env.
      * Уже запущенные процессы сохранят старое значение до перезапуска (для штатной
        ветки дополнительно рассылается оповещение об изменении env).
      * Атомарность: каждое значение удаляется отдельно; неудача фиксируется и
        приводит к exit 1, остальные значения всё равно обрабатываются.

.PARAMETER DryRun
    Показать план и ничего не менять (поведение по умолчанию).

.PARAMETER Apply
    Реально удалить найденные значения. Несовместим с -DryRun.

.PARAMETER RegistryPath
    Ветка реестра (нужна для изолированных тестов). По умолчанию HKCU:\Environment.

.EXAMPLE
    powershell -NoProfile -File clear-plaintext-env.ps1
    powershell -NoProfile -File clear-plaintext-env.ps1 -Apply
    powershell -NoProfile -File clear-plaintext-env.ps1 -DryRun -RegistryPath 'HKCU:\Software\agent-hq-tests\x'

.NOTES
    Exit codes: 0 = ok (в dry-run — план показан), 1 = ошибка удаления/чтения,
    2 = неверная комбинация параметров.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [string]$RegistryPath = 'HKCU:\Environment'
)

$ErrorActionPreference = 'Continue'

$EnvPathDefault = 'HKCU:\Environment'
$TargetNames = @(
    'AIHUBMIX_API_KEY',
    'OPENROUTER_API_KEY',
    'TOKENROUTER_API_KEY',
    'GROQ_API_KEY',
    'OPENCODE_API_KEY'
)

if ($DryRun -and $Apply) {
    Write-Host '[clear-env] ОШИБКА: -DryRun и -Apply взаимоисключающие.'
    exit 2
}
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Write-Host '[clear-env] ОШИБКА: -RegistryPath пуст.'
    exit 2
}

Write-Host '=== clear-plaintext-env.ps1 — plaintext-ключи провайдеров в пользовательском окружении ==='
Write-Host ("Ветка : {0}" -f $RegistryPath)
if ($Apply) {
    Write-Host 'Режим : APPLY (значения будут удалены)'
} else {
    Write-Host 'Режим : DRY-RUN (ничего не меняется; для удаления добавьте -Apply)'
}

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    Write-Host ("[clear-env] Ветка не найдена: {0} — нечего удалять." -f $RegistryPath)
    exit 0
}

# --- текущее состояние: только ИМЕНА значений (значения не читаем и не печатаем) ---
function Get-ValueNames {
    param([string]$Path)
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    return @($key.GetValueNames())
}

$existing = @()
try {
    $existing = @(Get-ValueNames -Path $RegistryPath)
} catch {
    Write-Host ("[clear-env] ОШИБКА чтения {0}: {1}" -f $RegistryPath, $_.Exception.Message)
    exit 1
}

$found = @()
foreach ($name in $TargetNames) {
    if ($existing -contains $name) {
        $found += $name
        if ($Apply) {
            Write-Host ("  {0,-22} : НАЙДЕНО -> удаляю" -f $name)
        } else {
            Write-Host ("  {0,-22} : НАЙДЕНО -> будет удалено (нужен -Apply)" -f $name)
        }
    } else {
        Write-Host ("  {0,-22} : не найдено -> пропуск" -f $name)
    }
}

if ($found.Count -eq 0) {
    Write-Host '[clear-env] Итог: plaintext-ключей провайдеров в этой ветке нет. Изменений нет.'
    exit 0
}

if (-not $Apply) {
    Write-Host ("[clear-env] Итог (DRY-RUN): будет удалено значений: {0}. Реально не изменено ничего." -f $found.Count)
    exit 0
}

# --- APPLY: удаление -------------------------------------------------------------
$removed = 0
$failed = 0
foreach ($name in $found) {
    try {
        Remove-ItemProperty -LiteralPath $RegistryPath -Name $name -ErrorAction Stop
        $removed++
    } catch {
        $failed++
        Write-Host ("[clear-env] ОШИБКА удаления '{0}': {1}" -f $name, $_.Exception.Message)
        continue
    }
    # Штатная ветка: оповестить систему, чтобы новые процессы (и explorer) увидели
    # удаление. Значение при этом не читается.
    if ($RegistryPath -eq $EnvPathDefault) {
        try {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
        } catch {
            Write-Host ("[clear-env] ПРЕДУПРЕЖДЕНИЕ: не удалось оповестить об удалении '{0}': {1}" -f $name, $_.Exception.Message)
        }
    }
}

# --- верификация ----------------------------------------------------------------
$stillPresent = @()
try {
    $after = @(Get-ValueNames -Path $RegistryPath)
    foreach ($name in $found) {
        if ($after -contains $name) { $stillPresent += $name }
    }
} catch {
    Write-Host ("[clear-env] ПРЕДУПРЕЖДЕНИЕ: не удалось перечитать {0}: {1}" -f $RegistryPath, $_.Exception.Message)
}

if ($stillPresent.Count -gt 0) {
    Write-Host ("[clear-env] Итог: удалено {0} из {1}; ОСТАЛИСЬ: {2}" -f $removed, $found.Count, ($stillPresent -join ', '))
    exit 1
}
Write-Host ("[clear-env] Итог: удалено значений: {0}. Ключи остались только в vault; запущенные процессы сохранят старое значение до перезапуска." -f $removed)
exit 0
