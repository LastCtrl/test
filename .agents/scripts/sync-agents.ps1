param(
    [switch]$DryRun,
    # Применить ту же (единый источник) bash-политику к ВНЕШНЕМУ конфигу —
    # по умолчанию к глобальному opencode.jsonc. Repo-файл обновляется всегда.
    [switch]$SyncGlobalPolicy,
    # Явный путь внешнего конфига (для тестов/нестандартных установок).
    [string]$GlobalConfigPath
)

$ErrorActionPreference = "Stop"

# Единый источник bash-политики (канон + генератор top-level permission.bash).
# Dot-source выполняет ТОЛЬКО определения (см. guard по InvocationName внутри),
# параметры библиотеки префиксованы, поэтому $DryRun не затирается.
$bashPolicyPath = Join-Path $PSScriptRoot "bash-policy.ps1"
if (-not (Test-Path -LiteralPath $bashPolicyPath)) {
    throw "bash-policy.ps1 not found: $bashPolicyPath"
}
. $bashPolicyPath


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
# P0-B: разбор metadata.task_allow — allowlist агентов, которым
# ДАННЫЙ агент может делегировать через task (deny-by-default).
# Fail-safe: нестроковые/небезопасные элементы ОТБРАСЫВАЮТСЯ с warning,
# а не роняют sync. Инвариант anti-fork-bomb: ни сам агент, ни другой
# оркестратор (team-lead*) не попадают в allow-список.
# ============================================================
function Get-TaskAllowList {
    param(
        [string]$AgentName,
        $TaskAllow
    )

    $result = [System.Collections.ArrayList]::new()

    if ($null -eq $TaskAllow) { return $result.ToArray() }

    foreach ($item in @($TaskAllow)) {
        if ($null -eq $item) {
            Write-Warning "task_allow: null entry ignored for '$AgentName'"
            continue
        }
        if (-not ($item -is [System.String])) {
            Write-Warning "task_allow: non-string entry ignored for '$AgentName'"
            continue
        }

        $candidate = $item.Trim()
        if ($candidate.Length -eq 0) {
            Write-Warning "task_allow: empty entry ignored for '$AgentName'"
            continue
        }
        if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            Write-Warning "task_allow: unsafe agent name '$candidate' ignored for '$AgentName'"
            continue
        }
        if ($candidate -eq $AgentName) {
            Write-Warning "task_allow: self-reference ('$candidate') ignored for '$AgentName' (anti-fork-bomb)"
            continue
        }
        if ($candidate -match $script:TaskOrchestratorPattern) {
            Write-Warning "task_allow: orchestrator '$candidate' ignored for '$AgentName' (anti-fork-bomb)"
            continue
        }
        if (-not $result.Contains($candidate)) {
            [void]$result.Add($candidate)
        }
    }

    return $result.ToArray()
}

# ============================================================
# P0-B: granular bash command policy. КАНОН вынесен в
# .agents\scripts\bash-policy.ps1 (Get-BashPermissionRules), который
# dot-source'ится выше. Оттуда же берётся top-level permission.bash repo
# opencode.json — repo-копия больше НЕ ведётся руками (единый источник).
# ============================================================

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
            # P0-B: порядок вложенных правил ВАЖЕН — opencode применяет
            # ПОСЛЕДНЕЕ совпавшее правило. Сортировку НЕ применяем,
            # порядок вставки сохраняется (широкое "*" задаётся первым).
            $subKeys = @($v.Keys)
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
# Разрешение локальных $ref схемы (#/$defs/...). Внешние ссылки
# (https://...) не разрешаются -> $null (узел пропускается, данных нет).
# ============================================================
function Resolve-JsonSchemaRef {
    param(
        $Schema,
        [string]$Ref
    )

    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    if (-not $Ref.StartsWith('#/')) { return $null }

    $pointer = $Ref.Substring(2)
    $node = $Schema
    foreach ($rawSegment in ($pointer -split '/')) {
        $segment = $rawSegment.Replace('~1', '/').Replace('~0', '~')
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

# ============================================================
# Совместим ли узел схемы с фактическим значением (по ключу "type").
# Нужно для ветвления anyOf/oneOf: неприменимую ветвь не считаем "пройденной".
# ============================================================
function Test-SchemaNodeApplicable {
    param(
        $Schema,
        $SchemaNode,
        $ConfigValue,
        [int]$Depth = 0
    )

    if ($null -eq $SchemaNode) { return $false }
    if ($Depth -gt 16) { return $true }

    $refProp = $SchemaNode.PSObject.Properties['$ref']
    if ($null -ne $refProp) {
        $resolved = Resolve-JsonSchemaRef -Schema $Schema -Ref ([string]$refProp.Value)
        if ($null -eq $resolved) { return $true }  # неразрешимая ссылка -> не исключаем ветвь
        return (Test-SchemaNodeApplicable -Schema $Schema -SchemaNode $resolved -ConfigValue $ConfigValue -Depth ($Depth + 1))
    }

    $typeProp = $SchemaNode.PSObject.Properties['type']
    if ($null -eq $typeProp) { return $true }

    switch ([string]$typeProp.Value) {
        'object'  { return ($ConfigValue -is [System.Management.Automation.PSCustomObject]) }
        'array'   { return ($ConfigValue -is [System.Array]) }
        'string'  { return ($ConfigValue -is [System.String]) }
        'boolean' { return ($ConfigValue -is [System.Boolean]) }
        'integer' { return ($ConfigValue -is [System.Int64] -or $ConfigValue -is [System.Int32] -or $ConfigValue -is [System.Double] -or $ConfigValue -is [System.Decimal]) }
        'number'  { return ($ConfigValue -is [System.Int64] -or $ConfigValue -is [System.Int32] -or $ConfigValue -is [System.Double] -or $ConfigValue -is [System.Decimal]) }
        'null'    { return ($null -eq $ConfigValue) }
        default   { return $true }
    }
}

# ============================================================
# РЕКУРСИВНАЯ проверка структуры конфига по JSON-схеме.
# Падает (throw) на неизвестный ключ в узле, где схема объявляет
# additionalProperties: false. Обходит properties, $ref,
# additionalProperties (как схему), anyOf/oneOf/allOf и items.
# ============================================================
$script:SchemaNodesChecked = 0

function Assert-ConfigSchemaNode {
    param(
        $Schema,
        $SchemaNode,
        $ConfigValue,
        [string]$Path,
        [int]$Depth = 0
    )

    if ($null -eq $SchemaNode) { return }
    if ($Depth -gt 64) {
        throw "Schema recursion depth exceeded at '$Path' (possible `$ref cycle)."
    }

    # 1. $ref: локальные разворачиваем; внешние пропускаем (нет данных для сверки).
    $refProp = $SchemaNode.PSObject.Properties['$ref']
    if ($null -ne $refProp) {
        $resolved = Resolve-JsonSchemaRef -Schema $Schema -Ref ([string]$refProp.Value)
        if ($null -eq $resolved) { return }
        Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $resolved -ConfigValue $ConfigValue -Path $Path -Depth ($Depth + 1)
        return
    }

    # 2. anyOf / oneOf: значение обязано удовлетворять хотя бы одной применимой ветви.
    foreach ($combiner in @('anyOf', 'oneOf')) {
        $combinerProp = $SchemaNode.PSObject.Properties[$combiner]
        if ($null -ne $combinerProp) {
            $branches = @($combinerProp.Value)
            $applicable = @($branches | Where-Object { Test-SchemaNodeApplicable -Schema $Schema -SchemaNode $_ -ConfigValue $ConfigValue })
            if ($applicable.Count -eq 0) { $applicable = $branches }  # тип не определить -> судим по всем

            $branchErrors = @()
            $branchOk = $false
            foreach ($branch in $applicable) {
                try {
                    Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $branch -ConfigValue $ConfigValue -Path $Path -Depth ($Depth + 1)
                    $branchOk = $true
                    break
                }
                catch {
                    $branchErrors += $_.Exception.Message
                }
            }
            if (-not $branchOk) {
                $firstError = if ($branchErrors.Count -gt 0) { $branchErrors[0] } else { 'no branch matched' }
                throw "Config node '$Path' violates schema ${combiner}: $firstError"
            }
            return
        }
    }

    # 3. allOf: проверяем все ветви, затем продолжаем обход прочих ключевых слов.
    $allOfProp = $SchemaNode.PSObject.Properties['allOf']
    if ($null -ne $allOfProp) {
        foreach ($branch in @($allOfProp.Value)) {
            Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $branch -ConfigValue $ConfigValue -Path $Path -Depth ($Depth + 1)
        }
    }

    # 4. Массивы: элементы проверяем по items.
    if ($ConfigValue -is [System.Array]) {
        $itemsProp = $SchemaNode.PSObject.Properties['items']
        if ($null -ne $itemsProp) {
            for ($i = 0; $i -lt $ConfigValue.Count; $i++) {
                Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $itemsProp.Value -ConfigValue $ConfigValue[$i] -Path ("{0}[{1}]" -f $Path, $i) -Depth ($Depth + 1)
            }
        }
        return
    }

    # 5. Объекты: контроль неизвестных ключей там, где additionalProperties: false.
    if (-not ($ConfigValue -is [System.Management.Automation.PSCustomObject])) { return }
    $script:SchemaNodesChecked++

    $propertiesProp = $SchemaNode.PSObject.Properties['properties']
    $declaredProps = if ($null -ne $propertiesProp) { $propertiesProp.Value } else { $null }

    $addlProp = $SchemaNode.PSObject.Properties['additionalProperties']
    $addlValue = if ($null -ne $addlProp) { $addlProp.Value } else { $null }
    $addlIsFalse = ($null -ne $addlProp) -and ($addlValue -is [System.Boolean]) -and ($addlValue -eq $false)

    foreach ($member in @($ConfigValue.PSObject.Properties)) {
        $key = $member.Name
        $childPath = if ($Path.Length -gt 0) { "$Path.$key" } else { $key }

        $declared = $null
        if ($null -ne $declaredProps) {
            $declared = $declaredProps.PSObject.Properties[$key]
        }

        if ($null -ne $declared) {
            Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $declared.Value -ConfigValue $member.Value -Path $childPath -Depth ($Depth + 1)
        }
        elseif ($addlIsFalse) {
            throw "Unknown key '$key' at config path '$childPath' — not allowed by schema (additionalProperties: false)."
        }
        elseif ($null -ne $addlProp) {
            # additionalProperties задана схемой -> валидируем значение как запись map.
            Assert-ConfigSchemaNode -Schema $Schema -SchemaNode $addlValue -ConfigValue $member.Value -Path $childPath -Depth ($Depth + 1)
        }
    }
}

# ============================================================
# Валидация opencode.json против схемы schemas/opencode.config.schema.json:
#   1) top-level ключи ⊆ $defs.Config.properties;
#   2) РЕКУРСИВНО — неизвестные ключи во ВСЕХ вложенных узлах, где схема
#      объявляет additionalProperties: false (properties/$ref/anyOf/items/map).
# Неизвестный ключ → throw (fail-closed).
# ============================================================
function Assert-ConfigSchemaKeys {
    param(
        [string]$ConfigPath,
        [string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        throw "Schema not found: $SchemaPath — schema validation cannot run (fail-closed)."
    }

    try {
        $schemaRaw = [System.IO.File]::ReadAllText($SchemaPath, [System.Text.Encoding]::UTF8)
        $schema = $schemaRaw | ConvertFrom-Json
    }
    catch {
        throw "Cannot parse schema ($SchemaPath): $($_.Exception.Message)"
    }

    $configDef = $schema.'$defs'.Config
    if (($null -eq $configDef) -or ($null -eq $configDef.properties)) {
        throw "Schema has no `$defs.Config.properties — cannot validate top-level keys (fail-closed)."
    }

    $allowed = @($configDef.properties.PSObject.Properties.Name)

    $configRaw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $config = $configRaw | ConvertFrom-Json
    $actual = @($config.PSObject.Properties.Name)

    Write-Host "Top-level keys in opencode.json: $($actual -join ', ')" -ForegroundColor Cyan

    $unknown = @($actual | Where-Object { $allowed -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "Unknown top-level key(s) in opencode.json not present in schema `$defs.Config.properties: $($unknown -join ', ')"
    }

    # Рекурсивный обход вложенной структуры.
    $script:SchemaNodesChecked = 0
    Assert-ConfigSchemaNode -Schema $schema -SchemaNode $configDef -ConfigValue $config -Path '' -Depth 0

    Write-Host "Schema validation OK (recursive, fail-closed): $($actual.Count) top-level keys, $($script:SchemaNodesChecked) object node(s) checked; unknown keys rejected where additionalProperties=false." -ForegroundColor Green
}

# Portability: предпочитаем явный AGENT_HQ_ROOT, иначе выводим корень из расположения скрипта.
$root = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
# Нормализация: убрать завершающий разделитель (кроме корня диска "X:\"),
# иначе шаблон "{0}\**" даст двойной слэш.
if ($root.Length -gt 3 -and ($root.EndsWith('\') -or $root.EndsWith('/'))) {
    $root = $root.Substring(0, $root.Length - 1)
}
$agentsDir = Join-Path $root ".opencode\agents"
$promptsDir = Join-Path $agentsDir "prompts"
$configPath = Join-Path $root "opencode.json"
$schemaPath = Join-Path $root "schemas\opencode.config.schema.json"

if (-not (Test-Path $promptsDir)) {
    New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
}

# P0-B: "task" СОЗНАТЕЛЬНО исключён из allowKeys/denyIfMissing — он
# вычисляется отдельно из metadata.task_allow (allowlist, deny-by-default).
# Непустой task_allow -> permission.task = { "*": "deny", "<agent>": "allow", ... }
# Пусто/отсутствует  -> permission.task = "deny"
$allowKeys = @("read", "edit", "bash", "glob", "grep", "skill", "question", "webfetch", "websearch", "list")
$denyIfMissing = @("edit", "bash")

# Агенты-оркестраторы: не могут быть целью делегирования (anti-fork-bomb).
$script:TaskOrchestratorPattern = '^team-lead(-\d+)?$'

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

## KNOWN ENVIRONMENT ISSUES (сверяться при помехах)
- Защита Kaspersky/AMSI/EDR может блокировать: содержимое `.ps1` (AMSI) и создание дочерних процессов (`EPERM ... uv_spawn 'powershell'|'git'`), особенно на длинных командных строках и при параллельных спавнах.
- Актуальный список и обходы: **`.agents/docs/ib-requests.md`** — читать при любых блокировках/ошибках спавна; новый инцидент — дописывать туда.

## CONSOLE ENCODING (кириллица)
- Перед выводом/чтением кириллицы ставь UTF-8: `[Console]::OutputEncoding=[Console]::InputEncoding=$OutputEncoding=[System.Text.Encoding]::UTF8; chcp 65001`.
- Файлы читай через `[IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8)`; не используй `Get-Content` без `-Encoding`.
- Хелпер: `.agents/scripts/set-console-utf8.ps1`.

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
            if ($key -eq "bash") {
                # P0-B: bash — не "allow", а гранулярный объект правил
                # (единый источник — Get-BashPermissionRules).
                $perm[$key] = Get-BashPermissionRules
            } else {
                $perm[$key] = "allow"
            }
        } elseif ($denyIfMissing -contains $key) {
            # Агенты без "bash" в permissions получают bash: "deny" (не меняем).
            $perm[$key] = "deny"
        }
    }

    # P0-B: task — allowlist с deny-by-default.
    # Правило "*" обязано идти ПЕРВЫМ (opencode применяет последнее
    # совпавшее правило), поэтому [ordered] с "*" в начале, allow после.
    $taskAllow = @(Get-TaskAllowList -AgentName $name -TaskAllow $data.task_allow)
    if ($taskAllow.Count -gt 0) {
        $taskPerm = [ordered]@{ "*" = "deny" }
        foreach ($target in $taskAllow) {
            $taskPerm[$target] = "allow"
        }
        $perm["task"] = $taskPerm
        Write-Host "      task: allowlist ($($taskAllow.Count) targets) + '*' deny" -ForegroundColor DarkCyan
    } else {
        $perm["task"] = "deny"
        if ($data.permissions -contains "task") {
            Write-Warning "  $name has 'task' in permissions but no non-empty task_allow — task set to 'deny' (deny-by-default)"
        }
    }

    # external_directory: ТОЛЬКО корень репо (worktrees — внутри репо).
    # Конфиг/креды opencode и прочие пути C: агентам недоступны.
    $perm["external_directory"] = [ordered]@{
        ("{0}\**" -f $root) = "allow"
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
    if ($SyncGlobalPolicy) {
        $globalPath = if ([string]::IsNullOrWhiteSpace($GlobalConfigPath)) { Get-DefaultGlobalPolicyPath } else { $GlobalConfigPath }
        if (Test-Path -LiteralPath $globalPath -PathType Leaf) {
            try {
                $graw = [System.IO.File]::ReadAllText($globalPath, [System.Text.Encoding]::UTF8)
                $gnew = Set-BashPolicyText -Text $graw -Rules (Get-BashPermissionRules)
                $gchanged = -not ($gnew -ceq $graw)
                Write-Host ("DRY RUN: global policy " + $globalPath + " changed=" + $gchanged) -ForegroundColor Yellow
            }
            catch {
                Write-Warning "DRY RUN: global check failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "DRY RUN: global config not found: $globalPath"
        }
    }
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

# 5b. Top-level permission.bash в repo opencode.json — генерируется из ТОГО ЖЕ
#     источника (Get-BashPermissionRules / Set-BashPolicyText). Файл уже собран
#     как текст, поэтому правка делается в памяти до бэкапа/записи/валидации:
#     один атомарный write и одна схема-проверка.
$bashRules = Get-BashPermissionRules
$configText = Set-BashPolicyText -Text $configText -Rules $bashRules
Write-Host "Top-level permission.bash: generated from bash-policy.ps1 ($($bashRules.Count) rules)" -ForegroundColor DarkCyan

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

# 9c. -SyncGlobalPolicy: та же (единый источник) политика во ВНЕШНИЙ конфиг.
#     По умолчанию — глобальный opencode.jsonc. Отсутствующий/битый внешний
#     файл — предупреждение, НЕ ошибка: repo-синк не должен падать из-за него.
if ($SyncGlobalPolicy) {
    $globalPath = if ([string]::IsNullOrWhiteSpace($GlobalConfigPath)) { Get-DefaultGlobalPolicyPath } else { $GlobalConfigPath }
    Write-Host "`n=== Global policy sync: $globalPath ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $globalPath -PathType Leaf)) {
        Write-Warning "Global config not found: $globalPath - skipped"
    }
    else {
        try {
            $gRules = Get-BashPermissionRules
            $gres = Set-BashPolicyInFile -Path $globalPath -Rules $gRules -Backup
            if ($gres.Changed) {
                Write-Host "Global permission.bash updated ($($gRules.Count) rules)" -ForegroundColor Green
                if ($null -ne $gres.Backup) { Write-Host "  backup: $($gres.Backup)" -ForegroundColor Gray }
            }
            else {
                Write-Host "Global permission.bash already in sync" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Global policy sync failed (repo sync unaffected): $($_.Exception.Message)"
        }
    }
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

# 11. Установка git-хука (отдельный скрипт; безопасно при CRLF).
& (Join-Path $PSScriptRoot "install-hooks.ps1")

Write-Host "`n=== DONE: $count agents written to opencode.json (text replacement, manual JSON serialization) ===" -ForegroundColor Cyan
Write-Host "Prompts saved to: $promptsDir" -ForegroundColor Gray
