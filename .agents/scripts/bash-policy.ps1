# ============================================================
# bash-policy.ps1 — ЕДИНЫЙ ИСТОЧНИК granулярной bash-политики.
#
# Канон правил живёт в Get-BashPermissionRules. Этот файл:
#   * dot-source'ится sync-agents.ps1 (только функции) и используется и для
#     per-agent permission.bash, и для top-level permission.bash в repo
#     opencode.json — repo-копия БОЛЬШЕ НЕ ведётся руками;
#   * может запускаться самостоятельно для применения той же политики к
#     внешнему конфигу (по умолчанию — глобальный opencode.jsonc):
#         .\bash-policy.ps1 -Apply [-Path <файл>] [-DryRun] [-NoBackup]
#
# ВАЖНО: параметры названы с префиксом Policy и снабжены Alias(...), чтобы
# dot-source НИКОГДА не затирал переменные вызывающего (например $DryRun в
# sync-agents.ps1). Ровно поэтому Alias, а не голые -Apply/-Path/-DryRun.
#
# Формат: PowerShell 5.1, CRLF, UTF-8 BOM (кириллица в комментариях).
# ============================================================
param(
    [Alias('Apply')][switch]$PolicyApply,
    [Alias('Path')][string]$PolicyPath,
    [Alias('DryRun')][switch]$PolicyDryRun,
    [Alias('NoBackup')][switch]$PolicyNoBackup,
    [switch]$PolicyQuiet
)

# ============================================================
# КАНОН. opencode применяет ПОСЛЕДНЕЕ совпавшее правило, поэтому порядок
# ключей критичен: сначала широкий catch-all "*", затем allow, затем ask,
# а ВСЕ deny — В КОНЦЕ. Так запрет гарантированно побеждает более широкие
# allow/ask (например "git push*": ask не перекрывает "git push --force*": deny).
# Возвращаем НОВЫЙ [ordered] на каждый вызов (не общий мутабельный объект),
# чтобы агенты не делили одно состояние.
# ============================================================
function Get-BashPermissionRules {
    $rules = [ordered]@{}

    # --- catch-all: широкая политика идёт ПЕРВОЙ ---
    $rules['*'] = 'allow'

    # --- allow (молча): безопасные read-only / сборка ---
    $rules['git status*'] = 'allow'
    $rules['git diff*'] = 'allow'
    $rules['git log*'] = 'allow'
    $rules['git show*'] = 'allow'
    $rules['git add*'] = 'allow'
    $rules['git commit*'] = 'allow'
    $rules['Get-ChildItem*'] = 'allow'
    $rules['Get-Content*'] = 'allow'
    $rules['Select-String*'] = 'allow'
    $rules['Test-Path*'] = 'allow'
    $rules['Get-FileHash*'] = 'allow'
    $rules['pwsh*'] = 'allow'
    $rules['powershell*'] = 'allow'
    $rules['node *'] = 'allow'
    $rules['npm *'] = 'allow'
    $rules['python*'] = 'allow'
    $rules['dotnet *'] = 'allow'
    $rules['opencode *'] = 'allow'

    # --- ask: широкие команды, требующие подтверждения ---
    $rules['git push*'] = 'ask'
    $rules['reg *'] = 'ask'
    $rules['schtasks*'] = 'ask'
    $rules['Set-ItemProperty HKCU*'] = 'ask'

    # --- deny: необратимые/опасные/системные — ПОСЛЕДНИМИ (всегда побеждают) ---
    $rules['rm -rf*'] = 'deny'
    $rules['rm -r *'] = 'deny'
    $rules['Remove-Item*-Recurse*'] = 'deny'
    $rules['git push --force*'] = 'deny'
    $rules['git push -f*'] = 'deny'
    $rules['git reset --hard*'] = 'deny'
    $rules['git clean*'] = 'deny'
    $rules['reg add*'] = 'deny'
    $rules['*HKLM:*'] = 'deny'
    $rules['secedit*'] = 'deny'
    $rules['gpedit*'] = 'deny'
    $rules['shutdown*'] = 'deny'
    $rules['Stop-Computer*'] = 'deny'
    $rules['Restart-Computer*'] = 'deny'
    # Формат диска (disk format). ПРОБЕЛ обязателен: голый glob `format*`
    # матчил безобидные Format-List/Format-Table (баг — блокировал команды
    # тимлида). `format *` матчит `format C:`, но не `Format-List`.
    $rules['format *'] = 'deny'
    # Фоновый запуск процессов запрещён (AGENTS.md §3.7): Start-Process без
    # остановки в том же вызове оставляет осиротевший процесс. Deny — последним
    # правилом, чтобы «last-rule-wins» побеждал allow-правила выше.
    $rules['Start-Process*'] = 'deny'

    return $rules
}

# ============================================================
# Валидация набора правил: непусто, '*' первым, allow/ask не идут после
# первого deny. Возвращает { Ok; Errors } — fail-closed для генераторов.
# ============================================================
function Test-BashPolicyObject {
    param($Rules)

    $errors = New-Object System.Collections.ArrayList

    if ($null -eq $Rules) {
        [void]$errors.Add('rules object is null')
        return [pscustomobject]@{ Ok = $false; Errors = @($errors) }
    }

    $keys = @($Rules.Keys)
    if ($keys.Count -eq 0) {
        [void]$errors.Add('rules object is empty')
        return [pscustomobject]@{ Ok = $false; Errors = @($errors) }
    }

    if ([string]$keys[0] -ne '*') {
        [void]$errors.Add("first rule must be '*' (got '$($keys[0])')")
    }

    $seenDeny = $false
    foreach ($k in $keys) {
        $action = [string]$Rules[$k]
        if ($action -notin @('allow', 'ask', 'deny')) {
            [void]$errors.Add("rule '$k' has invalid action '$action'")
        }
        if ($action -eq 'deny') { $seenDeny = $true }
        elseif ($seenDeny) {
            [void]$errors.Add("rule '$k' action '$action' appears AFTER a deny rule (deny must be last)")
        }
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors) }
}

# ============================================================
# Ручная JSON-эскейп строки (PS 5.1 ConvertTo-Json ломает кириллицу).
# ============================================================
function ConvertTo-BashPolicyJsonString {
    param([string]$Text)

    if ($null -eq $Text) { return '""' }

    $escaped = $Text
    $escaped = $escaped.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`r", '\r')
    $escaped = $escaped.Replace("`t", '\t')

    return '"' + $escaped + '"'
}

# ============================================================
# Сериализация правил в JSON-объект (значение "bash").
#   $KeyIndent  — отступ строки ключа "bash"
#   $IndentUnit — один шаг отступа (обычно два пробела)
# ============================================================
function ConvertTo-BashPolicyBlock {
    param(
        [System.Collections.IDictionary]$Rules,
        [string]$KeyIndent,
        [string]$IndentUnit,
        [string]$NewLine
    )

    $ruleIndent = $KeyIndent + $IndentUnit
    $keys = @($Rules.Keys)
    if ($keys.Count -eq 0) { throw 'bash policy is empty — refusing to generate an empty object' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{')
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = [string]$keys[$i]
        $v = [string]$Rules[$k]
        $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }
        [void]$sb.Append($NewLine)
        [void]$sb.Append($ruleIndent)
        [void]$sb.Append((ConvertTo-BashPolicyJsonString $k))
        [void]$sb.Append(': ')
        [void]$sb.Append((ConvertTo-BashPolicyJsonString $v))
        [void]$sb.Append($comma)
    }
    [void]$sb.Append($NewLine)
    [void]$sb.Append($KeyIndent)
    [void]$sb.Append('}')

    return $sb.ToString()
}

# ============================================================
# Мини-сканер JSON/JSONC (комментарии // и /* */, строки с экранированием).
# Нужен, чтобы текстово и безопасно править ровно один узел, не переписывая
# весь файл через ConvertTo-Json (PS 5.1 теряет порядок/кириллицу) и умея
# читать JSONC (глобальный конфиг содержит комментарии).
# ============================================================
function Skip-BashPolicyTrivia {
    param([string]$Text, [int]$Index)
    $n = $Text.Length
    while ($Index -lt $n) {
        $c = $Text[$Index]
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n") { $Index++; continue }
        if ($c -eq '/' -and ($Index + 1) -lt $n) {
            $nx = $Text[$Index + 1]
            if ($nx -eq '/') {
                $Index += 2
                while ($Index -lt $n -and $Text[$Index] -ne "`n") { $Index++ }
                continue
            }
            if ($nx -eq '*') {
                $Index += 2
                while (($Index + 1) -lt $n -and -not ($Text[$Index] -eq '*' -and $Text[$Index + 1] -eq '/')) { $Index++ }
                $Index = [Math]::Min($Index + 2, $n)
                continue
            }
        }
        break
    }
    return $Index
}

function Read-BashPolicyJsonString {
    param([string]$Text, [int]$Index)

    if ($Index -ge $Text.Length -or $Text[$Index] -ne '"') {
        throw "expected JSON string at index $Index"
    }

    $sb = New-Object System.Text.StringBuilder
    $i = $Index + 1
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq '\') {
            if (($i + 1) -ge $Text.Length) { throw "unterminated escape at index $i" }
            $nx = $Text[$i + 1]
            switch ($nx) {
                'n' { [void]$sb.Append("`n") }
                'r' { [void]$sb.Append("`r") }
                't' { [void]$sb.Append("`t") }
                '"' { [void]$sb.Append('"') }
                '\' { [void]$sb.Append('\') }
                '/' { [void]$sb.Append('/') }
                default { [void]$sb.Append($nx) }
            }
            $i += 2
            continue
        }
        if ($c -eq '"') {
            return [pscustomobject]@{ Value = $sb.ToString(); End = $i + 1 }
        }
        [void]$sb.Append($c)
        $i++
    }
    throw "unterminated JSON string starting at index $Index"
}

function Find-BashPolicyValueEnd {
    param([string]$Text, [int]$ValueStart)

    $n = $Text.Length
    $i = $ValueStart
    if ($i -ge $n) { return $i }

    $first = $Text[$i]
    if ($first -eq '{' -or $first -eq '[') {
        $depth = 0
        $inStr = $false
        $esc = $false
        while ($i -lt $n) {
            $ch = $Text[$i]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq '"') { $inStr = $false }
                $i++
                continue
            }
            if ($ch -eq '"') { $inStr = $true; $i++; continue }
            if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
                while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
                $i += 2
                while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i = [Math]::Min($i + 2, $n)
                continue
            }
            if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
            elseif ($ch -eq '}' -or $ch -eq ']') {
                $depth--
                if ($depth -eq 0) { $i++; break }
            }
            $i++
        }
        return $i
    }

    # scalar (строка/число/литерал): до ',' / '}' / ']' вне строки
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($ch -eq '"') {
            $s = Read-BashPolicyJsonString -Text $Text -Index $i
            $i = $s.End
            continue
        }
        if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']') { break }
        $i++
    }
    return $i
}

function Get-BashPolicyObjectMembers {
    param([string]$Text, [int]$ObjStart)

    $members = New-Object System.Collections.ArrayList
    $n = $Text.Length
    $i = $ObjStart + 1

    while ($true) {
        $i = Skip-BashPolicyTrivia -Text $Text -Index $i
        if ($i -ge $n -or $Text[$i] -eq '}') { break }
        if ($Text[$i] -ne '"') { break }

        $keyStart = $i
        $key = Read-BashPolicyJsonString -Text $Text -Index $i
        $i = Skip-BashPolicyTrivia -Text $Text -Index $key.End
        if ($i -lt $n -and $Text[$i] -eq ':') { $i++ }
        $i = Skip-BashPolicyTrivia -Text $Text -Index $i

        $valueStart = $i
        $valueEnd = Find-BashPolicyValueEnd -Text $Text -ValueStart $valueStart

        [void]$members.Add([pscustomobject]@{
            Name       = $key.Value
            KeyStart   = $keyStart
            ValueStart = $valueStart
            ValueEnd   = $valueEnd
        })

        $i = Skip-BashPolicyTrivia -Text $Text -Index $valueEnd
        if ($i -lt $n -and $Text[$i] -eq ',') { $i++; continue }
        break
    }

    return $members
}

function Get-BashPolicyLineIndent {
    param([string]$Text, [int]$Index)

    $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $Index - 1))
    $from = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $indent = $Text.Substring($from, [Math]::Max(0, $Index - $from))
    if ($indent.Trim().Length -ne 0) { return '' }
    return $indent
}

function Get-BashPolicyIndentUnit {
    param([string]$Text)

    $objStart = Skip-BashPolicyTrivia -Text $Text -Index 0
    if ($objStart -ge $Text.Length -or $Text[$objStart] -ne '{') { return '  ' }
    $members = @(Get-BashPolicyObjectMembers -Text $Text -ObjStart $objStart)
    if ($members.Count -ge 2) {
        $ind1 = Get-BashPolicyLineIndent -Text $Text -Index $members[0].KeyStart
        $ind2 = Get-BashPolicyLineIndent -Text $Text -Index $members[1].KeyStart
        if ($ind2.Length -gt $ind1.Length) {
            $delta = $ind2.Substring($ind1.Length)
            if ($delta.Trim().Length -eq 0) { return $delta }
        }
    }
    foreach ($m in $members) {
        $ind = Get-BashPolicyLineIndent -Text $Text -Index $m.KeyStart
        if ($ind.Length -gt 0) { return $ind }
    }
    return '  '
}

# ============================================================
# Текстовая замена top-level permission.bash. Возвращает новый текст.
# Гарантии:
#   * правится ровно узел bash (остальные ключи permission, включая
#     external_directory, и весь остальной файл сохраняются);
#   * если текст уже синхронен — возвращается тот же текст (идемпотентность);
#   * EOL генерируемого блока берётся из существующего bash-блока, поэтому
#     CRLF-репозиторий и LF-глобал не «дрожат» при повторных прогонах;
#   * если top-level permission/bash отсутствуют — узел аккуратно создаётся.
# ============================================================
function Set-BashPolicyText {
    param([string]$Text, [System.Collections.IDictionary]$Rules)

    if ([string]::IsNullOrEmpty($Text)) { throw 'config text is empty' }

    $validation = Test-BashPolicyObject -Rules $Rules
    if (-not $validation.Ok) {
        throw ('refusing to write invalid bash policy: ' + ($validation.Errors -join '; '))
    }

    if ($Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }

    $indentUnit = Get-BashPolicyIndentUnit -Text $Text
    $fileEol = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }

    $rootStart = Skip-BashPolicyTrivia -Text $Text -Index 0
    if ($rootStart -ge $Text.Length -or $Text[$rootStart] -ne '{') {
        throw 'config root is not a JSON object'
    }
    $rootMembers = @(Get-BashPolicyObjectMembers -Text $Text -ObjStart $rootStart)
    $baseIndent = if ($rootMembers.Count -gt 0) {
        Get-BashPolicyLineIndent -Text $Text -Index $rootMembers[0].KeyStart
    } else { $indentUnit }

    $permMember = $null
    foreach ($m in $rootMembers) { if ($m.Name -eq 'permission') { $permMember = $m; break } }

    if ($null -eq $permMember) {
        # Нет top-level permission — создаём новый member с одним bash.
        $permIndent = $baseIndent
        $bashIndent = $permIndent + $indentUnit
        $bashValue = ConvertTo-BashPolicyBlock -Rules $Rules -KeyIndent $bashIndent -IndentUnit $indentUnit -NewLine $fileEol
        $permValue = '{' + $fileEol + $bashIndent + '"bash": ' + $bashValue + $fileEol + $permIndent + '}'
        if ($rootMembers.Count -eq 0) {
            # Пустой root: {} -> { <permission> }
            $insert = $fileEol + $permIndent + '"permission": ' + $permValue + $fileEol
            return $Text.Insert($rootStart + 1, $insert)
        }
        $lastMember = $rootMembers[$rootMembers.Count - 1]
        $insertAt = $lastMember.ValueEnd
        $insert = ',' + $fileEol + $permIndent + '"permission": ' + $permValue
        return $Text.Insert($insertAt, $insert)
    }

    $permRaw = $Text.Substring($permMember.ValueStart, $permMember.ValueEnd - $permMember.ValueStart)
    $permIndent = Get-BashPolicyLineIndent -Text $Text -Index $permMember.KeyStart

    if (-not $permRaw.TrimStart().StartsWith('{')) {
        # permission не объект (например строка) — заменяем его целиком.
        $bashIndent = $permIndent + $indentUnit
        $bashValue = ConvertTo-BashPolicyBlock -Rules $Rules -KeyIndent $bashIndent -IndentUnit $indentUnit -NewLine $fileEol
        $permValue = '{' + $fileEol + $bashIndent + '"bash": ' + $bashValue + $fileEol + $permIndent + '}'
        return $Text.Remove($permMember.ValueStart, $permMember.ValueEnd - $permMember.ValueStart).Insert($permMember.ValueStart, $permValue)
    }

    $permObjStart = Skip-BashPolicyTrivia -Text $Text -Index $permMember.ValueStart
    $permMembers = @(Get-BashPolicyObjectMembers -Text $Text -ObjStart $permObjStart)

    $bashMember = $null
    foreach ($m in $permMembers) { if ($m.Name -eq 'bash') { $bashMember = $m; break } }

    if ($null -ne $bashMember) {
        $existingRaw = $Text.Substring($bashMember.ValueStart, $bashMember.ValueEnd - $bashMember.ValueStart)
        $blockEol = if ($existingRaw.Contains("`r`n")) { "`r`n" } elseif ($existingRaw.Contains("`n")) { "`n" } else { $fileEol }
        $bashIndent = Get-BashPolicyLineIndent -Text $Text -Index $bashMember.KeyStart
        $generated = ConvertTo-BashPolicyBlock -Rules $Rules -KeyIndent $bashIndent -IndentUnit $indentUnit -NewLine $blockEol
        if ($generated -ceq $existingRaw) { return $Text }   # уже синхронно — not a single byte changes
        return $Text.Remove($bashMember.ValueStart, $bashMember.ValueEnd - $bashMember.ValueStart).Insert($bashMember.ValueStart, $generated)
    }

    # permission есть, bash нет — вставляем bash последним членом permission.
    $bashIndent = $permIndent + $indentUnit
    $blockEol = $fileEol
    $bashValue = ConvertTo-BashPolicyBlock -Rules $Rules -KeyIndent $bashIndent -IndentUnit $indentUnit -NewLine $blockEol
    if ($permMembers.Count -eq 0) {
        $permValue = '{' + $blockEol + $bashIndent + '"bash": ' + $bashValue + $blockEol + $permIndent + '}'
        return $Text.Remove($permMember.ValueStart, $permMember.ValueEnd - $permMember.ValueStart).Insert($permMember.ValueStart, $permValue)
    }
    $lastPermMember = $permMembers[$permMembers.Count - 1]
    $insert = ',' + $blockEol + $bashIndent + '"bash": ' + $bashValue
    return $Text.Insert($lastPermMember.ValueEnd, $insert)
}

# ============================================================
# Чтение файла конфига (UTF-8, BOM авто-детект), запись/бэкап.
# ============================================================
function Set-BashPolicyInFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Rules,
        [switch]$DryRun,
        [switch]$Backup
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is required' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "config file not found: $Path" }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    $original = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $updated = Set-BashPolicyText -Text $original -Rules $Rules
    $changed = -not ($updated -ceq $original)

    $backupPath = $null
    if ($changed -and -not $DryRun) {
        if ($Backup) {
            $backupPath = ('{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        }
        [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($hasBom)))
    }

    return [pscustomobject]@{
        Changed  = $changed
        Original = $original
        Updated  = $updated
        Backup   = $backupPath
        HadBom   = $hasBom
    }
}

# ============================================================
# Парсинг JSONC (в PS 5.1 ConvertFrom-Json не понимает комментарии).
# Удаляет // и /* */ вне строк, затем парсит. Используется и тестом,
# и для диагностики.
# ============================================================
function ConvertFrom-BashPolicyJsonc {
    param([string]$Text)

    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }

    $sb = New-Object System.Text.StringBuilder
    $n = $Text.Length
    $i = 0
    $inStr = $false
    $esc = $false

    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($ch)
            if ($esc) { $esc = $false }
            elseif ($ch -eq '\') { $esc = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            $i++
            continue
        }
        if ($ch -eq '"') { $inStr = $true; [void]$sb.Append($ch); $i++; continue }
        if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
            $i += 2
            while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i = [Math]::Min($i + 2, $n)
            continue
        }
        [void]$sb.Append($ch)
        $i++
    }

    return ($sb.ToString() | ConvertFrom-Json)
}

function Get-BashPolicyFromFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $cfg = ConvertFrom-BashPolicyJsonc -Text $raw
    if ($null -eq $cfg) { return $null }
    if ($null -eq $cfg.permission) { return $null }
    return $cfg.permission.bash
}

# Упорядоченные пары правил (порядок ключей важен — last-rule-wins).
# Понимает и IDictionary ([ordered] источник), и PSCustomObject (после ConvertFrom-Json).
function Get-BashPolicyRulePairs {
    param($BashRuleObject)

    if ($null -eq $BashRuleObject) { return @() }
    if ($BashRuleObject -is [System.Collections.IDictionary]) {
        return @($BashRuleObject.Keys | ForEach-Object {
            [pscustomobject]@{ Pattern = [string]$_; Action = [string]$BashRuleObject[$_] }
        })
    }
    return @($BashRuleObject.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{ Pattern = [string]$_.Name; Action = [string]$_.Value }
    })
}

function Compare-BashPolicyRules {
    param($A, $B)

    $pa = @(Get-BashPolicyRulePairs -BashRuleObject $A)
    $pb = @(Get-BashPolicyRulePairs -BashRuleObject $B)
    if ($pa.Count -ne $pb.Count) { return $false }
    for ($i = 0; $i -lt $pa.Count; $i++) {
        if ($pa[$i].Pattern -cne $pb[$i].Pattern) { return $false }
        if ($pa[$i].Action -cne $pb[$i].Action) { return $false }
    }
    return $true
}

function Get-DefaultGlobalPolicyPath {
    $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($HOME) { $HOME } else { '' }
    if ([string]::IsNullOrWhiteSpace($home_)) { throw 'cannot resolve user home for the global opencode config' }
    return (Join-Path $home_ ".config\opencode\opencode.jsonc")
}

# ============================================================
# CLI (только при ПРЯМОМ запуске; dot-source выполняет лишь определения).
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $target = if ([string]::IsNullOrWhiteSpace($PolicyPath)) { Get-DefaultGlobalPolicyPath } else { $PolicyPath }

        if (-not $PolicyApply -and -not $PolicyDryRun) {
            Write-Host 'Usage: bash-policy.ps1 -Apply [-Path <config>] [-DryRun] [-NoBackup]' -ForegroundColor Yellow
            Write-Host '  default -Path is the global opencode.jsonc' -ForegroundColor Gray
            exit 2
        }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-Error "Target config not found: $target"
            exit 1
        }

        $rules = Get-BashPermissionRules
        $backupWanted = $PolicyApply -and (-not $PolicyNoBackup)
        $res = Set-BashPolicyInFile -Path $target -Rules $rules -DryRun:([bool]$PolicyDryRun) -Backup:$backupWanted

        if ($res.Changed) {
            if ($PolicyDryRun) { Write-Host ("DRY-RUN: bash policy differs in " + $target) -ForegroundColor Yellow }
            else { Write-Host ("bash policy updated in " + $target) -ForegroundColor Green }
            if ($null -ne $res.Backup) { Write-Host ("backup: " + $res.Backup) -ForegroundColor Gray }
        } else {
            Write-Host ("bash policy already in sync: " + $target) -ForegroundColor Green
        }
        $exitCode = 0
    }
    catch {
        Write-Error ("bash-policy failed: " + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
