#!/usr/bin/env pwsh
# prompt-gate.ps1 — структурный контроль промптов агентов (G1..G6)
#                  P1-5: scrub секретов + ручное одобрение рискованных промптов.
#
# Usage (legacy, поведение не изменилось):
#        .\prompt-gate.ps1 -Check
#        .\prompt-gate.ps1 -FixSync
#
# Usage (P1-5):
#        .\prompt-gate.ps1 -Scrub -Text "<промпт>"         # замаскировать секреты, отдать текст в stdout
#        .\prompt-gate.ps1 -Scrub -Path .\task.md          # то же для файла
#        .\prompt-gate.ps1 -Scrub -Text "..." -Strict      # секрет => жёсткий блок (exit 3)
#        .\prompt-gate.ps1 -Approve apr-0123456789abcdef  # одобрить рискованный промпт
#
# Exit codes (режимы -Scrub / -Approve):
#        0 — промпт допустим (stdout = очищенный текст)
#        1 — ошибка вызова / нет такой заявки на одобрение
#        2 — промпт рискованный: ждёт ручного одобрения (.memory\approvals\pending)
#        3 — -Strict: в промпте найдено секретоподобное содержимое
#
# Политика (P1-5):
#   * секретоподобное -> по умолчанию scrub + предупреждение (промпт проходит);
#     с -Strict -> жёсткий блок (exit 3; одобрением НЕ снимается).
#   * деструктивные/системные шаблоны (rm -rf, Remove-Item -Recurse -Force,
#     git push --force, reg add/delete, schtasks, HKLM/HKEY_LOCAL_MACHINE,
#     политики) -> всегда требуют ручного одобрения: запись в
#     .memory\approvals\pending\<id>.json, exit 2 до появления
#     .memory\approvals\approved\<id>.json (или CLI -Approve <id>).
#   * fail-closed: если заявку не удалось записать, промпт всё равно НЕ проходит.
#
# Dot-source (например, из message-queue.ps1): при загрузке через `.` скрипт только
# объявляет функции и НЕ выполняет ни G1..G6-прогон, ни режимы -Scrub/-Approve.

param(
    [switch]$Check,
    [switch]$FixSync,
    [switch]$Scrub,
    [string]$Text,
    [string]$Path,
    [switch]$Strict,
    [string]$Approve,
    [switch]$Quiet
)

# Set UTF-8 output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$baseDir = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# Загружаем redact.ps1: чистая функция Redact-Secrets, без побочных эффектов.
# Если файла нет — scrub недоступен, и промпт блокируется (fail-closed), см. Invoke-PromptScrub.
$__redactPath = Join-Path $PSScriptRoot "redact.ps1"
if (Test-Path -LiteralPath $__redactPath -PathType Leaf) {
    . $__redactPath
}

# ===========================================================================
# P1-5: scrub + risk detection + human approval
# ===========================================================================

# Деструктивные/системные шаблоны. Совпадение с ЛЮБЫМ из них => промпт
# помечается рискованным и без ручного одобрения не уходит.
# $script: — переменная живёт в области загрузки скрипта (в т.ч. при dot-source).
$script:PromptRiskPatterns = @(
    @{ Id = 'rm-rf';           Description = 'рекурсивное удаление файлов (rm -rf)';        Pattern = 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\b|rm\s+-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\b|rm\s+-r\s+-f\b|rm\s+-f\s+-r\b' },
    @{ Id = 'remove-item-rec'; Description = 'Remove-Item -Recurse -Force';                  Pattern = 'Remove-Item\b[^\r\n]*(-Recurse[^\r\n]*-Force|-Force[^\r\n]*-Recurse)' },
    @{ Id = 'git-push-force';  Description = 'git push с --force / -f';                      Pattern = 'git\s+push\b[^\r\n]*(\s--force\b|\s-f(\s|$))' },
    @{ Id = 'reg-add';         Description = 'правка реестра (reg add/delete/import)';        Pattern = '(^|[\s;&|])reg(\.exe)?\s+(add|delete|import)\b' },
    @{ Id = 'schtasks';        Description = 'планировщик задач (schtasks)';                 Pattern = '(^|[\s;&|])schtasks(\.exe)?\b' },
    @{ Id = 'hklm';            Description = 'доступ к системному реестру HKLM';             Pattern = 'HKLM|HKEY_LOCAL_MACHINE' },
    @{ Id = 'policy';          Description = 'системные/групповые политики';                 Pattern = 'SOFTWARE\\Policies|gpedit|secedit|secpol\.msc|LocalSecurityPolicy' }
)

$__utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-PromptSha256 {
    # SHA256 (hex, lowercase) от UTF-8 байтов. $null безопасен.
    param([string]$Text)
    $value = if ($null -eq $Text) { "" } else { $Text }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value))
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-PromptScrubId {
    # Детерминированный id заявки: одна и та же очищенная строка => один id
    # (идемпотентность; повторная отправка не плодит дубли заявок).
    param([string]$Text)
    $value = if ($null -eq $Text) { "" } else { $Text }
    return "apr-" + (Get-PromptSha256 $value).Substring(0, 16)
}

function Get-PromptRiskReasons {
    # Возвращает массив id сработавших деструктивных шаблонов (пустой массив, если нет).
    param([string]$Text)
    $reasons = @()
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($p in $script:PromptRiskPatterns) {
        try {
            if ([regex]::IsMatch($Text, $p.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $reasons += $p.Id
            }
        } catch {
            # защитно: сломанный шаблон не должен валить гейт молча — помечаем причину
            $reasons += ("pattern-error:" + $p.Id)
        }
    }
    return $reasons
}

function Get-PromptApprovalPaths {
    param([string]$Root)
    $root = if ([string]::IsNullOrWhiteSpace($Root)) { $baseDir } else { $Root }
    $approvals = Join-Path $root ".memory\approvals"
    return [pscustomobject]@{
        Root     = $root
        Base     = $approvals
        Pending  = Join-Path $approvals "pending"
        Approved = Join-Path $approvals "approved"
    }
}

function Test-PromptApprovalId {
    # Строгий формат id: apr- + 16 hex. Защита от path traversal в имени файла.
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return ($Id -cmatch '^apr-[0-9a-f]{16}$')
}

function New-PromptApprovalRequest {
    # Пишет заявку в .memory\approvals\pending\<id>.json. Секреты в файл НЕ попадают:
    # сохраняется только очищенный текст (или заглушка, если секреты были).
    # Возвращает $true только после подтверждения, что файл реально создан.
    param(
        [string]$Id,
        [string]$ScrubbedText,
        [string[]]$Reasons,
        [bool]$SecretsFound,
        [string]$Root
    )
    if (-not (Test-PromptApprovalId $Id)) { return $false }
    $paths = Get-PromptApprovalPaths -Root $Root
    try {
        if (-not (Test-Path -LiteralPath $paths.Pending -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.Pending -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $paths.Pending -PathType Container)) { return $false }

        $safeText = if ($null -eq $ScrubbedText) { "" } else { $ScrubbedText }
        $record = [ordered]@{
            id            = $Id
            status        = "pending"
            created       = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
            reasons       = @($Reasons)
            secrets_found = [bool]$SecretsFound
            prompt_sha256 = (Get-PromptSha256 $safeText)
            prompt_length = $safeText.Length
        }
        if ($SecretsFound) {
            $record["preview"] = "[скрыт: в промпте были секретоподобные данные]"
        } else {
            $preview = $safeText
            if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) + "..." }
            $record["preview"] = $preview
        }

        $file = Join-Path $paths.Pending ($Id + ".json")
        [System.IO.File]::WriteAllText($file, ($record | ConvertTo-Json -Depth 4), $__utf8NoBom)
        return (Test-Path -LiteralPath $file -PathType Leaf)
    } catch {
        return $false
    }
}

function Test-PromptApproval {
    # Одобрено, если в .memory\approvals\approved есть <id>.json ИЛИ маркер-файл <id>.
    param([string]$Id, [string]$Root)
    if (-not (Test-PromptApprovalId $Id)) { return $false }
    $paths = Get-PromptApprovalPaths -Root $Root
    if (Test-Path -LiteralPath (Join-Path $paths.Approved ($Id + ".json")) -PathType Leaf) { return $true }
    if (Test-Path -LiteralPath (Join-Path $paths.Approved $Id) -PathType Leaf) { return $true }
    return $false
}

function Approve-PromptRequest {
    # Ручное одобрение: pending\<id>.json -> approved\<id>.json (status=approved).
    # Идемпотентно: повторный approve уже одобренного id тоже возвращает $true.
    param([string]$Id, [string]$Root, [string]$By)
    if (-not (Test-PromptApprovalId $Id)) { return $false }
    $paths = Get-PromptApprovalPaths -Root $Root
    if (Test-PromptApproval -Id $Id -Root $Root) { return $true }

    $pendingFile = Join-Path $paths.Pending ($Id + ".json")
    if (-not (Test-Path -LiteralPath $pendingFile -PathType Leaf)) { return $false }

    try {
        if (-not (Test-Path -LiteralPath $paths.Approved -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.Approved -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $paths.Approved -PathType Container)) { return $false }

        $record = $null
        try { $record = [System.IO.File]::ReadAllText($pendingFile, $__utf8NoBom) | ConvertFrom-Json } catch { $record = $null }

        $out = [ordered]@{
            id          = $Id
            status      = "approved"
            approved_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        }
        if (-not [string]::IsNullOrWhiteSpace($By)) { $out["approved_by"] = $By }
        if ($null -ne $record -and $null -ne $record.reasons) { $out["reasons"] = @($record.reasons) }

        $approvedFile = Join-Path $paths.Approved ($Id + ".json")
        [System.IO.File]::WriteAllText($approvedFile, ($out | ConvertTo-Json -Depth 4), $__utf8NoBom)
        if (-not (Test-Path -LiteralPath $approvedFile -PathType Leaf)) { return $false }

        Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Invoke-PromptScrub {
    # Единая точка входа: маскирует секреты, классифицирует риск, при необходимости
    # создаёт заявку на ручное одобрение.
    # Возвращает объект; ключевое поле .Allowed — можно ли пропускать промпт дальше.
    param(
        [string]$Text,
        [string]$Root,
        [switch]$Strict
    )

    $original = if ($null -eq $Text) { "" } else { $Text }

    $scrubAvailable = ($null -ne (Get-Command -Name 'Redact-Secrets' -ErrorAction SilentlyContinue))
    $scrubbed = $original
    $redactedCount = 0
    $secretsFound = $false
    if ($scrubAvailable) {
        try {
            $scrubbed = [string](Redact-Secrets $original)
            $redactedCount = ([regex]::Matches($scrubbed, '\[REDACTED\]')).Count
            $secretsFound = ($redactedCount -gt 0) -or ($scrubbed -cne $original)
        } catch {
            # Ошибка маскировки => считаем scrub недоступным (fail-closed).
            $scrubAvailable = $false
            $scrubbed = $original
            $redactedCount = 0
            $secretsFound = $false
        }
    }

    $reasons = @()
    if (-not $scrubAvailable) { $reasons += 'scrub-unavailable' }
    $reasons += @(Get-PromptRiskReasons -Text $scrubbed)
    $risky = ($reasons.Count -gt 0)

    # Strict: секрет = жёсткий блок. Scrub недоступен = тоже блок (fail-closed).
    $blocked = ((-not $scrubAvailable) -or (([bool]$Strict) -and $secretsFound))

    $approvalId = ""
    $approved = $false
    $pending = $false
    $approvalWriteFailed = $false
    if ($risky -and -not $blocked) {
        $approvalId = Get-PromptScrubId -Text $scrubbed
        $approved = Test-PromptApproval -Id $approvalId -Root $Root
        if (-not $approved) {
            $written = New-PromptApprovalRequest -Id $approvalId -ScrubbedText $scrubbed -Reasons $reasons -SecretsFound $secretsFound -Root $Root
            # fail-closed: не удалось записать заявку — промпт всё равно не проходит
            $pending = $true
            if (-not $written) { $approvalWriteFailed = $true }
        }
    }

    return [pscustomobject]@{
        Text                = $scrubbed
        Changed             = ($scrubbed -cne $original)
        ScrubAvailable      = $scrubAvailable
        SecretsFound        = $secretsFound
        RedactedCount       = $redactedCount
        Risky               = $risky
        RiskReasons         = $reasons
        Blocked             = $blocked
        ApprovalId          = $approvalId
        Approved            = $approved
        Pending             = $pending
        ApprovalWriteFailed = $approvalWriteFailed
        Allowed             = ((-not $blocked) -and (-not $pending))
    }
}

# ===========================================================================
# Точка ветвления: dot-source (только функции) vs обычный запуск
# ===========================================================================

$__promptGateDotSourced = ($MyInvocation.InvocationName -eq '.')
if ($__promptGateDotSourced) { return }

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# P1-5: режим ручного одобрения
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($Approve)) {
    $approveId = $Approve.Trim()
    if (Approve-PromptRequest -Id $approveId -Root $baseDir) {
        Write-Host ("[prompt-gate] одобрено: " + $approveId)
        exit 0
    }
    Write-Host ("[prompt-gate] НЕ одобрено: " + $approveId + " (нет заявки в .memory\approvals\pending или некорректный id)")
    exit 1
}

# ---------------------------------------------------------------------------
# P1-5: режим scrub
# ---------------------------------------------------------------------------
if ($Scrub) {
    $sourceText = $null
    # NB: в PS 5.1 необъявленный [string]-параметр равен "", а не $null, поэтому
    # отличить "не передали -Text" от "-Text ''" можно только по $PSBoundParameters.
    $pathGiven = ($PSBoundParameters.ContainsKey('Path') -and -not [string]::IsNullOrWhiteSpace($Path))
    $textGiven = $PSBoundParameters.ContainsKey('Text')

    if ($pathGiven) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Host ("[prompt-gate] файл не найден: " + $Path)
            exit 1
        }
        try {
            $sourceText = [System.IO.File]::ReadAllText($Path)
        } catch {
            Write-Host ("[prompt-gate] не удалось прочитать файл: " + $_.Exception.Message)
            exit 1
        }
    } elseif ($textGiven) {
        $sourceText = $Text
    } else {
        Write-Host "[prompt-gate] -Scrub требует -Text <строка> или -Path <файл>"
        exit 1
    }

    $gate = Invoke-PromptScrub -Text $sourceText -Root $baseDir -Strict:([bool]$Strict)

    if ($gate.SecretsFound -and -not $gate.Blocked -and -not $Quiet) {
        Write-Host ("[prompt-gate] scrub: секретоподобных фрагментов замаскировано: " + $gate.RedactedCount)
    }

    if ($gate.Blocked) {
        if (-not $gate.ScrubAvailable) {
            Write-Host "[prompt-gate] БЛОК: Redact-Secrets недоступен (нет redact.ps1) - маскировка не гарантирована"
        } else {
            Write-Host ("[prompt-gate] БЛОК (-Strict): в промпте найдено секретоподобное содержимое (" + $gate.RedactedCount + " шт.)")
        }
        exit 3
    }

    if ($gate.Pending) {
        $hint = if ($gate.ApprovalWriteFailed) { " ВНИМАНИЕ: заявку не удалось записать (fail-closed)" } else { "" }
        Write-Host ("[prompt-gate] ОЖИДАЕТ ОДОБРЕНИЯ: id=" + $gate.ApprovalId + " причины: " + ($gate.RiskReasons -join ', ') + "." + $hint)
        Write-Host ("[prompt-gate] одобрить: .agents\scripts\prompt-gate.ps1 -Approve " + $gate.ApprovalId)
        exit 2
    }

    # Разрешённый промпт: очищенный текст уходит в stdout (пригоден для использования).
    Write-Output $gate.Text
    exit 0
}

# ---------------------------------------------------------------------------
# Legacy: структурный контроль промптов агентов (G1..G6)
# ---------------------------------------------------------------------------

if ($FixSync) {
    Write-Host "[-FixSync] Re-running sync-agents.ps1 before check..."
    & (Join-Path $baseDir ".agents\scripts\sync-agents.ps1")
}
$agentsDir = Join-Path $baseDir ".opencode\agents"
$promptsDir = Join-Path $agentsDir "prompts"

# Список агентов (JSON файлы, кроме registry.json)
$agentFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }
$agentNames = $agentFiles | ForEach-Object { $_.Name -replace "\.json$", "" }

# Союзы/предлоги, на которые строка не должна заканчиваться
$conjunctions = @(" и", " в", " на", " с", " по", " за", " к", " о", " у", " от", " до", " при", "—", "-")

function Check-G1 {
    param($agentFile)
    try {
        $content = Get-Content $agentFile.FullName -Encoding UTF8
        $json = $content | ConvertFrom-Json
        return $true
    } catch {
        return $false
    }
}

function Check-G2 {
    param($agent)
    if (-not $agent.prompt) { return $false }
    $prompt = $agent.prompt
    return $prompt.Length -gt 500
}

function Check-G3 {
    param($promptText)
    if (-not $promptText) { return $true }
    # Find duplicate '## ' headers using regex
    $pattern = '^## .+'
    $matches = [regex]::Matches($promptText, $pattern)
    $headers = $matches | ForEach-Object { $_.Value }
    if ($headers.Count -le 1) { return $true }
    $uniqueHeaders = $headers | Select-Object -Unique
    return ($headers.Count -eq $uniqueHeaders.Count)
}

function Check-G4 {
    param($promptText)
    if (-not $promptText) { return $true }
    $lines = $promptText -split [Environment]::NewLine
    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()
        # Проверяем, заканчивается ли строка на союзе/предлоге
        foreach ($conj in $conjunctions) {
            if ($trimmed.EndsWith($conj, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
    }
    return $true
}

function Check-G5 {
    param($agentName, $agent)
    $prompt = $agent.prompt
    if (-not $prompt) { return $false }

    $result = $true

    if ($agentName -eq "team-lead") {
        if ($prompt -match "ОТКАТА|OTKATA|[Rr]etry") { $result = $true }
        else { $result = $false }
    }
    elseif ($agentName -eq "qa-engineer" -or $agentName -eq "code-reviewer" -or $agentName -eq "security-auditor") {
        if ($prompt -match "read-only|чтен|изменя") { $result = $true }
        else { $result = $false }
    }
    else {
        if ($prompt -match "CONTEXT-BUFFER") { $result = $true }
        else { $result = $false }
    }

    return $result
}

function Check-G6 {
    param($agentName)
    $txtPath = Join-Path $promptsDir "$agentName.txt"
    if (-not (Test-Path $txtPath)) { return $false }

    $jsonRaw = Get-Content (Join-Path $agentsDir "$agentName.json") -Raw -Encoding UTF8
    try { $promptField = ($jsonRaw | ConvertFrom-Json).prompt } catch { return $false }
    if (-not $promptField) { return $false }
    $txtContent = Get-Content $txtPath -Raw -Encoding UTF8

    # Разворачиваем JSON-эскейпы в реальный текст
    $promptReal = $promptField -replace '\\r\\n', "`n" -replace '\\n', "`n" -replace '\\t', "`t"

    # Нормализация концов строк
    $p = ($promptReal -replace "`r`n", "`n").Trim()
    $t = ($txtContent -replace "`r`n", "`n").Trim()
    if ($p -eq $t) { return $true }

    # Fallback: каждая непустая строка txt должна встречаться в промпте как подстрока
    foreach ($line in ($t -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if (-not $p.Contains($line)) { return $false }
    }
    return $true
}

# Выполнение проверок
$results = @{}
foreach ($agentFile in $agentFiles) {
    $name = $agentFile.Name -replace "\.json$", ""
    $results[$name] = @{ G1 = $false; G2 = $false; G3 = $false; G4 = $false; G5 = $false; G6 = $false }

    # Чтение JSON
    try {
        $agent = Get-Content $agentFile.FullName -Encoding UTF8 | ConvertFrom-Json
    } catch {
        continue
    }

    # G1: JSON валиден
    $results[$name].G1 = $true

    # G2: prompt непустой и >500 символов
    $results[$name].G2 = Check-G2 $agent

    # G3: нет дублей заголовков ##
    $results[$name].G3 = Check-G3 $agent.prompt

    # G4: нет обрывов по концу строки
    $results[$name].G4 = Check-G4 $agent.prompt

    # G5: обязательные секции по роли
    $results[$name].G5 = Check-G5 $name $agent

    # G6: консистентность sync
    $results[$name].G6 = Check-G6 $name
}

# Формирование отчета в файл
$reportPath = Join-Path $baseDir "temp_prompt_gate_report.txt"
Remove-Item $reportPath -ErrorAction SilentlyContinue

$report = @()
$report += "PROMPT GATE CHECK REPORT"
$report += ""
$report += "Agent              G1 G2 G3 G4 G5 G6 Status"
$report += "----------------- ---- ---- ---- ---- ---- -----"

$allPass = $true
foreach ($name in ($results.Keys | Sort-Object)) {
    $r = $results[$name]
    $g1 = if ($r.G1) { "PASS" } else { "FAIL" }
    $g2 = if ($r.G2) { "PASS" } else { "FAIL" }
    $g3 = if ($r.G3) { "PASS" } else { "FAIL" }
    $g4 = if ($r.G4) { "PASS" } else { "FAIL" }
    $g5 = if ($r.G5) { "PASS" } else { "FAIL" }
    $g6 = if ($r.G6) { "PASS" } else { "FAIL" }

    $status = if ($g1 -eq "PASS" -and $g2 -eq "PASS" -and $g3 -eq "PASS" -and $g4 -eq "PASS" -and $g5 -eq "PASS" -and $g6 -eq "PASS") { "PASS" } else { "FAIL" }

    if ($status -eq "FAIL") { $allPass = $false }

    $line = $name + " " + $g1 + " " + $g2 + " " + $g3 + " " + $g4 + " " + $g5 + " " + $g6 + " " + $status
    $report += $line
}

$report += ""
$totalAgents = $results.Keys.Count
$passAgents = ($results.Values | Where-Object { $_.G1 -and $_.G2 -and $_.G3 -and $_.G4 -and $_.G5 -and $_.G6 }).Count
$report += "Total: " + $passAgents + "/" + $totalAgents + " PASS"

if (-not $allPass) {
    $report += "Verdict: FAIL — there are agents with check failures"
    "FAIL" | Out-File -FilePath "$baseDir\temp_exit_code.txt" -Encoding UTF8
} else {
    $report += "Verdict: PASS — all agents passed the check"
    "PASS" | Out-File -FilePath "$baseDir\temp_exit_code.txt" -Encoding UTF8
}

# Запись отчета в файл
$report | Out-File -FilePath $reportPath -Encoding UTF8
