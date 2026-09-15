param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"


# ============================================================
# Вспомогательная функция: найти индекс закрывающей }
# с учётом вложенности и строк в кавычках
# ============================================================
function Find-JsonBlockEnd {
    param(
        [string]$text,
        [int]$startBraceIndex
    )

    $depth = 0
    $inString = $false
    $escape = $false
    $len = $text.Length

    for ($i = $startBraceIndex; $i -lt $len; $i++) {
        $ch = $text[$i]

        if ($escape) {
            $escape = $false
            continue
        }

        if ($ch -eq '\') {
            $escape = $true
            continue
        }

        if ($ch -eq '"') {
            $inString = -not $inString
            continue
        }

        if ($inString) { continue }

        if ($ch -eq '{') {
            $depth++
        }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }

    return -1
}

# ============================================================
# Ручной JSON-эскейп строки (без ConvertTo-Json — PS 5.1 ломает кириллицу)
# ============================================================
function ConvertTo-JsonString {
    param([string]$text)

    if ($null -eq $text) { return '""' }

    $escaped = $text
    $escaped = $escaped.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`t", '\t')

    return '"' + $escaped + '"'
}

# ============================================================
# Ручная сериализация одного агента в JSON (без ConvertTo-Json)
# ============================================================
function ConvertTo-AgentJson {
    param(
        [string]$name,
        [string]$description,
        [string]$mode,
        [string]$model,
        $temperature,
        [hashtable]$permission,
        [string]$prompt
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('    ' + (ConvertTo-JsonString $name) + ': {')

    $descJson = ConvertTo-JsonString $description
    [void]$sb.AppendLine('        ' + '"description": ' + $descJson + ',')

    $modeJson = ConvertTo-JsonString $mode
    [void]$sb.AppendLine('        ' + '"mode": ' + $modeJson + ',')

    $modelJson = ConvertTo-JsonString $model
    [void]$sb.AppendLine('        ' + '"model": ' + $modelJson + ',')

    if ($null -ne $temperature) {
        [void]$sb.AppendLine('        ' + '"temperature": ' + ([double]$temperature).ToString('G', [System.Globalization.CultureInfo]::InvariantCulture) + ',')
    }

    # permission
    [void]$sb.AppendLine('        ' + '"permission": {')
    $permKeys = @($permission.Keys | Sort-Object)
    for ($i = 0; $i -lt $permKeys.Count; $i++) {
        $k = $permKeys[$i]
        $v = $permission[$k]
        if ($v -is [System.Collections.IDictionary]) {
            # nested dict (external_directory patterns) — ручная сериализация
            [void]$sb.AppendLine('            ' + (ConvertTo-JsonString $k) + ': {')
            $subKeys = @($v.Keys | Sort-Object)
            for ($j = 0; $j -lt $subKeys.Count; $j++) {
                $sk = $subKeys[$j]
                $sv = $v[$sk]
                $subComma = if ($j -lt $subKeys.Count - 1) { ',' } else { '' }
                [void]$sb.AppendLine('                ' + (ConvertTo-JsonString $sk) + ': ' + (ConvertTo-JsonString $sv) + $subComma)
            }
            $comma = if ($i -lt $permKeys.Count - 1) { ',' } else { '' }
            [void]$sb.AppendLine('            }' + $comma)
        } else {
            $permJson = ConvertTo-JsonString $v
            $comma = if ($i -lt $permKeys.Count - 1) { ',' } else { '' }
            [void]$sb.AppendLine('            ' + (ConvertTo-JsonString $k) + ': ' + $permJson + $comma)
        }
    }
    [void]$sb.AppendLine('        ' + '},')

    $promptJson = ConvertTo-JsonString $prompt
    [void]$sb.AppendLine('        ' + '"prompt": ' + $promptJson)

    [void]$sb.AppendLine('    ' + '}')

    return $sb.ToString()
}

# ============================================================
# Валидация: top-level ключи opencode.json ⊆ $defs.Config.properties
# схемы schemas/opencode.config.schema.json. Неизвестный ключ → ошибка.
# ============================================================
function Assert-ConfigSchemaKeys {
    param(
        [string]$ConfigPath,
        [string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        Write-Warning "Schema not found: $SchemaPath — skipping top-level key validation"
        return
    }

    try {
        $schemaRaw = [System.IO.File]::ReadAllText($SchemaPath, [System.Text.Encoding]::UTF8)
        $schema = $schemaRaw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Cannot parse schema ($SchemaPath): $($_.Exception.Message) — skipping top-level key validation"
        return
    }

    $configDef = $schema.'$defs'.Config
    if (($null -eq $configDef) -or ($null -eq $configDef.properties)) {
        Write-Warning "Schema has no `$defs.Config.properties — skipping top-level key validation"
        return
    }

    $allowed = @($configDef.properties.PSObject.Properties.Name)

    $configRaw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $config = $configRaw | ConvertFrom-Json
    $actual = @($config.PSObject.Properties.Name)

    Write-Host "Top-level keys in opencode.json: $($actual -join ', ')" -ForegroundColor Cyan

    $unknown = @($actual | Where-Object { $allowed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "Unknown top-level key(s) in opencode.json not present in schema `$defs.Config.properties: $($unknown -join ', ')"
    }

    Write-Host "Schema validation OK: all top-level keys are known." -ForegroundColor Green
}

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$agentsDir = Join-Path $root ".opencode\agents"
$promptsDir = Join-Path $agentsDir "prompts"
$configPath = Join-Path $root "opencode.json"
$schemaPath = Join-Path $root "schemas\opencode.config.schema.json"

if (-not (Test-Path $promptsDir)) {
    New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
}

$allowKeys = @("read", "edit", "bash", "glob", "grep", "skill", "question", "webfetch", "websearch", "task", "list")
$denyIfMissing = @("edit", "bash", "task")

# ============================================================
# Блок evidence-discipline, добавляемый в начало КАЖДОГО промпта
# (6 правил + запрет DONE без артефакта). Verbatim here-string —
# одинарные кавычки, чтобы backtick-символы не интерпретировались.
# ============================================================
$evidenceHeader = @'
## EVIDENCE-DISCIPLINE (обязательно; нарушение = REJECT)
1. Не утверждай существование файла/команды/API/скилла без проверки (Read или запуск).
2. Не проверено — пиши `NOT ENOUGH EVIDENCE: <что именно>`, не догадывайся.
3. `DONE` — только с артефактом (путь + вывод/diff). Нет артефакта — `PARTIAL`.
4. Ссылки на код — `path:line`, только после чтения.
5. Отсутствующее называй `missing`, не подменяй похожим.
6. Различай: «проверил» / «предполагаю» / «сделал».

ЗАПРЕЩЕНО писать `DONE` без артефакта — это ложный отчёт (REJECT).

---

'@

$jsonFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }

Write-Host "=== Sync Agents: $($jsonFiles.Count) files found ===" -ForegroundColor Cyan

$agentEntries = [System.Collections.ArrayList]::new()
$count = 0

foreach ($file in $jsonFiles) {
    # Защита от аномально большого входного файла (>50 КБ)
    if ($file.Length -gt 51200) {
        Write-Warning "SKIP $($file.Name): file size $([math]::Round($file.Length / 1024, 1)) KB exceeds 50 KB limit — suspicious"
        continue
    }

    $raw = $null
    $data = $null

    # Валидация JSON после чтения — try/catch, пропуск при ошибке
    try {
        $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $data = $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "SKIP $($file.Name): invalid JSON — $($_.Exception.Message)"
        continue
    }

    # Валидация обязательных полей
    $hasDescription = $data.description -and ($data.description -is [string]) -and ($data.description.Trim().Length -gt 0)
    $hasMode = $data.mode -and ($data.mode -is [string]) -and ($data.mode.Trim().Length -gt 0)
    $hasModel = $data.model -and ($data.model -is [string]) -and ($data.model.Trim().Length -gt 0)

    if (-not $hasDescription) {
        Write-Warning "SKIP $($file.Name): missing or empty required field 'description'"
        continue
    }
    if (-not $hasMode) {
        Write-Warning "SKIP $($file.Name): missing or empty required field 'mode'"
        continue
    }
    if (-not $hasModel) {
        Write-Warning "SKIP $($file.Name): missing or empty required field 'model'"
        continue
    }

    $name = if ($data.name) { $data.name } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }

    $promptFile = Join-Path $promptsDir "$name.txt"
    [System.IO.File]::WriteAllText($promptFile, ($evidenceHeader + $data.prompt), (New-Object System.Text.UTF8Encoding($false)))

    $perm = [ordered]@{}
    foreach ($key in $allowKeys) {
        if ($data.permissions -contains $key) {
            $perm[$key] = "allow"
        } elseif ($denyIfMissing -contains $key) {
            $perm[$key] = "deny"
        }
    }
    # external_directory: ТОЛЬКО корень репо (worktrees — внутри репо).
    # Конфиг/креды opencode и прочие пути C: агентам недоступны.
    $perm["external_directory"] = [ordered]@{
        "D:\Тест\agent-hq\**" = "allow"
    }

    # Собираем entry как хэштаблицу (не PSCustomObject — для ручной сериализации)
    $entry = @{
        name        = $name
        description = [string]$data.description
        mode        = if ($data.mode) { [string]$data.mode } else { "subagent" }
        model       = if ($data.model) { [string]$data.model } else { "" }
        temperature = if ($null -ne $data.temperature) { [double]$data.temperature } else { $null }
        permission  = $perm
        prompt      = "{file:.opencode/agents/prompts/$name.txt}"
    }

    $agentEntries.Add($entry) | Out-Null
    $count++
    Write-Host "  [$count] $name -> $($data.model)" -ForegroundColor Green
}

if ($count -eq 0) {
    Write-Warning "No valid agents found — aborting"
    exit 1
}

# --- DryRun: показать превью и выйти ---
if ($DryRun) {
    Write-Host "`n=== DRY RUN: generated agent section preview ===" -ForegroundColor Yellow
    Write-Host '  "agent": {'
    for ($i = 0; $i -lt $agentEntries.Count; $i++) {
        $e = $agentEntries[$i]
        $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
        $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
        Write-Host ($jsonBlock + $comma)
    }
    Write-Host '  }'
    Write-Host "`n=== DRY RUN: opencode.json NOT modified ===" -ForegroundColor Yellow
    exit 0
}

# ============================================================
# ТОЧЕЧНАЯ ТЕКСТОВАЯ ЗАМЕНА секции "agent" в opencode.json
# НЕ используем ConvertFrom-Json/ConvertTo-Json на всём файле —
# PS 5.1 теряет NoteProperty-секции и портит кириллицу.
# ВАЖНО: единственный корректный ключ схемы — "agent" (ед.ч.).
# Легаси-ключ "agents" (мн.ч.) больше НЕ поддерживается и не ищется.
# ============================================================

if (-not (Test-Path $configPath)) {
    throw "opencode.json not found: $configPath"
}

# 1. Прочитать как ТЕКСТ с явным UTF-8
$configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)

# 2. Собрать JSON секции agent вручную (без ConvertTo-Json — PS 5.1 ломает кириллицу)
$agentLines = [System.Collections.ArrayList]::new()
[void]$agentLines.Add('  "agent": {')
for ($i = 0; $i -lt $agentEntries.Count; $i++) {
    $e = $agentEntries[$i]
    $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
    $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
    [void]$agentLines.Add($jsonBlock + $comma)
}
[void]$agentLines.Add('  }')
$agentJsonBlock = $agentLines -join "`n"

# 3. Найти верхнеуровневый ключ "agent" (любой отступ, но ТОЛЬКО top-level).
#    Ключ "agent" — канонический ключ схемы; НЕ удаляем его как legacy.
$agentPattern = '(?m)^[ \t]*"agent"\s*:\s*\{'
$agentMatch = [regex]::Match($configText, $agentPattern)

if (-not $agentMatch.Success) {
    Write-Warning "Top-level 'agent' key not found — appending before final }"
    $lastBrace = $configText.LastIndexOf("}")
    if ($lastBrace -lt 0) {
        throw "opencode.json has no closing brace — cannot inject agent section"
    }
    $beforeLast = $configText.Substring(0, $lastBrace).TrimEnd()
    $needsComma = (-not $beforeLast.EndsWith(",")) -and ($beforeLast.Length -gt 0)
    $comma = if ($needsComma) { "," } else { "" }
    $inject = "`n" + $agentJsonBlock + "`n"
    $configText = $configText.Substring(0, $lastBrace) + $comma + $inject + "}"
}
else {
    # 4. Найти конец секции agent через balanced braces
    $braceStart = $agentMatch.Index + $agentMatch.Length - 1  # индекс открывающей {
    $braceEnd = Find-JsonBlockEnd -text $configText -startBraceIndex $braceStart

    if ($braceEnd -lt 0) {
        throw "Cannot find matching closing brace for 'agent' section — aborting"
    }

    # 5. Заменить подстроку от начала совпадения до парной } включительно
    $replaceFrom = $agentMatch.Index
    $replaceTo = $braceEnd + 1  # включая }
    $configText = $configText.Remove($replaceFrom, $replaceTo - $replaceFrom).Insert($replaceFrom, $agentJsonBlock)
}

# 6. Бэкап ПЕРЕД перезаписью
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $root "opencode.json.bak.$timestamp"

try {
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Write-Host "`nBackup created: $backupPath" -ForegroundColor Gray
}
catch {
    Write-Warning "Failed to create backup: $($_.Exception.Message) — aborting to prevent data loss"
    exit 1
}

# 7. Записать UTF-8 без BOM
[System.IO.File]::WriteAllText($configPath, $configText, (New-Object System.Text.UTF8Encoding($false)))

# 8. Проверка размера (>100 КБ — аномалия, откат)
$writtenFile = Get-Item -LiteralPath $configPath
if ($writtenFile.Length -gt 102400) {
    Write-Error "opencode.json size $([math]::Round($writtenFile.Length / 1024, 1)) KB exceeds 100 KB limit — rolling back from backup"
    Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
    exit 1
}

# 9. Валидация JSON ПОСЛЕ записи (ConvertFrom-Json ТОЛЬКО для проверки!)
try {
    $verifyRaw = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $null = $verifyRaw | ConvertFrom-Json
}
catch {
    Write-Error "opencode.json is invalid JSON after write — rolling back from backup: $($_.Exception.Message)"
    Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
    exit 1
}

# 9b. Валидация top-level ключей против схемы; неизвестный ключ → откат
try {
    Assert-ConfigSchemaKeys -ConfigPath $configPath -SchemaPath $schemaPath
}
catch {
    Write-Error "$($_.Exception.Message) — rolling back from backup"
    Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
    exit 1
}

# 10. Удаление старых бэкапов — оставить только последние 3
#     (pre-migration бэкап — исключение, не удаляем)
$allBackups = Get-ChildItem -LiteralPath $root -Filter "opencode.json.bak.*" |
    Where-Object { $_.Name -notlike "*.pre-migration" } |
    Sort-Object Name -Descending
if ($allBackups.Count -gt 3) {
    $toDelete = $allBackups | Select-Object -Skip 3
    foreach ($old in $toDelete) {
        Remove-Item -LiteralPath $old.FullName -Force
        Write-Host "Old backup removed: $($old.Name)" -ForegroundColor Gray
    }
}

# 11. Шаг безопасности .git выполняется отдельной командой (см. CONTEXT-BUFFER / install-step).

Write-Host "`n=== DONE: $count agents written to opencode.json (text replacement, manual JSON serialization) ===" -ForegroundColor Cyan
Write-Host "Prompts saved to: $promptsDir" -ForegroundColor Gray
