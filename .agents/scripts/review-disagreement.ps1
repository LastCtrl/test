# ============================================================
# review-disagreement.ps1 - детектор расхождений вердиктов проверяющих.
#
# Мотивация (реальный инцидент): по P0 qa-engineer дал ПРИНЯТО, а
# code-reviewer - ВОЗВРАТЬ (portability/fail-open). Расхождение нашёл
# тимлид глазами; этот скрипт находит такие расхождения автоматически.
#
# Источник вердиктов (по факту доступного в репозитории):
#   * CONTEXT-BUFFER.md - self-report'ы (TYPE: update) с полями
#     VERDICT/ВЕРДИКТ/STATUS и релей-строки "<reviewer>: <вердикт>".
#   * .memory\evidence\*.json НЕ используется: каталог отсутствует, а
#     evidence-writer пишет исходы попыток (success/failed), а не вердикты
#     ревьюеров - приписать их ревью было бы ложным источником.
#   * .memory\reports - свободный текст без per-task вердиктов; не парсится
#     (хрупко и неоднозначно).
#
# Эвристика (реализация - Read-ReviewVerdictEntries):
#   Запись шины = блок от заголовка "[stamp] agent -> to:" до следующего.
#   Вердикт извлекается из трёх форм:
#     1) маркер VERDICT|ВЕРДИКТ|вердикт с известным токеном рядом;
#     2) релей-строка "<reviewer> [(модель)]: <токен>" - автор = reviewer
#        из строки (именно так записан инцидент P0);
#     3) поле "STATUS: <токен>", если токен - известный вердикт
#        (STATUS: resolved - это workflow-статус, НЕ вердикт).
#   ВСЕ три формы принимаются только от агентов из ReviewReviewerAllowlist:
#   проза исполнителя ("verdict pass", "STATUS: ok") вердиктом не считается.
#   Ключ задачи: явный task_id, иначе первый тег вида P#/US-#/BUG-#/TASK-#.
#   Хронология: позиция в файле (шина append-only), а не разбор метки.
#   Для каждой пары (задача, агент) остаётся ПОСЛЕДНИЙ вердикт - поэтому
#   ре-ревью того же проверяющего перекрывает его старый ВОЗВРАТ.
#   Расхождение = после схлопывания у задачи есть и accept, и reject от
#   РАЗНЫХ проверяющих.
#
# Только чтение, идемпотентно, не падает на пустом/битом/отсутствующем буфере.
# Формат: PowerShell 5.1, CRLF, UTF-8 BOM (кириллица в литералах шаблонов).
#
# Использование:
#   .\review-disagreement.ps1 -Status [-SinceHours N] [-TaskId X] [-Json]
#   .\review-disagreement.ps1 -All    [-SinceHours N] [-TaskId X] [-Json]
#   . "$PSScriptRoot\review-disagreement.ps1"   # только определения функций
# ============================================================
param(
    [Alias('Status')][switch]$ReviewStatus,
    [Alias('All')][switch]$ReviewAll,
    [Alias('SinceHours')][int]$ReviewSinceHours = 0,
    [Alias('TaskId')][string]$ReviewTaskId = '',
    [Alias('Json')][switch]$ReviewJson,
    [Alias('BufferPath')][string]$ReviewBufferPath = '',
    [Alias('Root')][string]$ReviewRoot = ''
)

$ReviewDisagreementScriptRoot = $PSScriptRoot

# Нормализация токенов вердиктов: accept / reject / partial / blocker.
# Ключи - строго в верхнем регистре (см. Get-ReviewVerdictCategory).
$script:ReviewVerdictMap = @{
    # accept
    'PASS'              = 'accept'
    'PASSED'            = 'accept'
    'ACCEPT'            = 'accept'
    'ACCEPTED'          = 'accept'
    'APPROVE'           = 'accept'
    'APPROVED'          = 'accept'
    'OK'                = 'accept'
    'GREEN'             = 'accept'
    'ПРИНЯТО'           = 'accept'
    'ПРИНЯТ'            = 'accept'
    'PRINJATO'          = 'accept'
    'PRINYATO'          = 'accept'
    # reject
    'REJECT'            = 'reject'
    'REJECTED'          = 'reject'
    'FAIL'              = 'reject'
    'FAILED'            = 'reject'
    'REQUEST_CHANGES'   = 'reject'
    'REQUESTCHANGES'    = 'reject'
    'CHANGES_REQUESTED' = 'reject'
    'ВОЗВРАТ'           = 'reject'
    'ВОЗВРАТЬ'          = 'reject'
    'БРАК'              = 'reject'
    'VOZVRAT'           = 'reject'
    'VOZVRATIT'         = 'reject'
    # прочие
    'PARTIAL'           = 'partial'
    'PARTIALLY'         = 'partial'
    'ЧАСТИЧНО'          = 'partial'
    'BLOCKER'           = 'blocker'
    'БЛОКЕР'            = 'blocker'
}

# Шаблоны разбора (см. эвристику в заголовке файла).
$script:ReviewHeaderPattern      = '(?m)^\[(?<stamp>[^\]]+)\]\s+(?<agent>[^\r\n]+?)\s*(?:->|\u2192|>>)\s*(?<to>[^\r\n:]+):'
$script:ReviewMarkerPattern      = '(?i)(?:VERDICT|ВЕРДИКТ|вердикт)\s*(?::|=|\u2014|-|\s)\s*\**\s*(?<tok>[A-Za-zА-Яа-я_]+)'
$script:ReviewRelayPattern       = '^\s*(?:[-*]\s+)?(?<agent>[A-Za-z][A-Za-z0-9._-]{1,40})\s*(?:\([^)\r\n]*\))?\s*[:=]\s*\**\s*(?<tok>[A-Za-zА-Яа-я_]+)'
$script:ReviewStatusFieldPattern = '(?im)^\s*STATUS\s*:\s*(?<tok>[A-Za-zА-Яа-я_]+)'
$script:ReviewTaskIdPattern      = '(?i)\btask_id\s*[:=]\s*["'']?(?<id>[A-Za-z0-9._-]{1,64})'
$script:ReviewTagPattern         = '(?<![\w-])(?:(?:TASK|US|BUG|SPR)-\d{1,4}|P\d{1,2}(?:-[A-Z0-9]{1,4})?(?:-\d{1,4})?)(?![\w-])'

# Вердикты проставляют только проверяющие; прочие "<word>: <токен>" игнорируются.
$script:ReviewReviewerAllowlist  = '^(?:qa-engineer|code-reviewer|security-auditor|senior-reviewer|team-lead)(?:-\d+)?$'

# ============================================================
# Корень репозитория: -Root > $env:AGENT_HQ_ROOT > производный от
# расположения скрипта (<root>\.agents\scripts) > текущий каталог.
# ============================================================
function Get-ReviewRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($ReviewDisagreementScriptRoot) {
        return (Split-Path (Split-Path $ReviewDisagreementScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

# ============================================================
# Путь к буферу шины (по умолчанию <root>\CONTEXT-BUFFER.md).
# ============================================================
function Get-ReviewBufferPath {
    param([string]$Root, [string]$BufferPath)

    if (-not [string]::IsNullOrWhiteSpace($BufferPath)) { return $BufferPath }
    return (Join-Path (Get-ReviewRoot -Root $Root) 'CONTEXT-BUFFER.md')
}

# ============================================================
# Токен -> категория (accept/reject/partial/blocker) или $null.
# Обрезаем обрамляющую пунктуацию (markdown-звёздочки, кавычки, запятые).
# ============================================================
function Get-ReviewVerdictCategory {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $stripChars = [char[]]@('*', [char]0x60, '"', "'", '(', ')', ',', '.', ':', ';', '!', '?', '-', [char]0x2014, [char]0x2013)
    $normalized = $Token.Trim().Trim($stripChars).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    if ($script:ReviewVerdictMap.ContainsKey($normalized)) {
        return $script:ReviewVerdictMap[$normalized]
    }
    return $null
}

# ============================================================
# Имя агента из заголовка: срезаем необязательное ведущее время
# ("[TIME] 07:58 dev-3"), роль в скобках и приводим к нижнему регистру.
# ============================================================
function Get-ReviewAgentName {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $name = $Raw.Trim()
    $name = $name -replace '^\d{1,2}:\d{2}(?::\d{2})?\s+', ''
    $parenIndex = $name.IndexOf('(')
    if ($parenIndex -ge 0) { $name = $name.Substring(0, $parenIndex) }
    return $name.Trim().ToLowerInvariant()
}

# ============================================================
# Ключ задачи: явный task_id, иначе первый тег P#/US-#/BUG-#/TASK-#.
# ============================================================
function Get-ReviewTaskKey {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $idMatch = [regex]::Match($Text, $script:ReviewTaskIdPattern)
    if ($idMatch.Success) { return $idMatch.Groups['id'].Value }

    $tagMatch = [regex]::Match($Text, $script:ReviewTagPattern)
    if ($tagMatch.Success) { return $tagMatch.Value }
    return $null
}

# ============================================================
# Метка времени из заголовка записи. Поддержаны ISO ("2026-09-14T19:00:00"),
# дата+время через пробел, "~" перед временем, только дата. "[TIME]" и любой
# неразбираемый штамп -> $null (запись остаётся видимой - доказать её давность
# нельзя, поэтому -SinceHours её НЕ скрывает).
# ============================================================
function ConvertTo-ReviewTime {
    param([string]$Stamp)

    if ([string]::IsNullOrWhiteSpace($Stamp)) { return $null }
    $m = [regex]::Match($Stamp, '(?<d>\d{4}-\d{2}-\d{2})(?:[T ]\s*~?(?<t>\d{2}:\d{2}(?::\d{2})?))?')
    if (-not $m.Success) { return $null }

    $dateStr = $m.Groups['d'].Value
    $timeStr = $m.Groups['t'].Value
    $parsed = [datetime]::MinValue

    if ($timeStr) {
        if ($timeStr.Length -eq 5) { $timeStr = "${timeStr}:00" }
        if ([datetime]::TryParseExact("$dateStr $timeStr", 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
        return $null
    }
    if ([datetime]::TryParseExact($dateStr, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# ============================================================
# Номер строки (1-based) по абсолютному смещению в тексте.
# ============================================================
function Get-ReviewLineNumber {
    param([string]$Text, [int]$Index)

    if ($Index -le 0) { return 1 }
    $prefix = $Text.Substring(0, [Math]::Min($Index, $Text.Length))
    return ([regex]::Matches($prefix, "\n").Count + 1)
}

# ============================================================
# Короткий сниппет строки для отчёта (без обрезки посередине слова-мусора).
# ============================================================
function Get-ReviewSnippet {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return '' }
    $text = $Line.Trim()
    if ($text.Length -gt 160) { return $text.Substring(0, 157) + '...' }
    return $text
}

# ============================================================
# Чтение буфера. Любая проблема (нет файла, нет доступа, бинарь) -> '' без throw.
# File.ReadAllText: UTF-8 c определением BOM; для битых байт даёт replacement-символы,
# не исключение, поэтому парсер безопасно вернёт пустой список.
# ============================================================
function Read-ReviewBufferText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return [System.IO.File]::ReadAllText($Path)
    } catch {
        return ''
    }
}

# ============================================================
# Разбор буфера в список нормализованных вердиктов.
# Возвращает массив (возможно пустой); порядок - по позиции в файле.
# Поля записи:
#   agent, task_key, verdict, raw_verdict, source, time, time_display,
#   line, snippet
# ============================================================
function Read-ReviewVerdictEntries {
    param([string]$Root = '', [string]$BufferPath = '')

    $entries = New-Object System.Collections.ArrayList
    $path = Get-ReviewBufferPath -Root $Root -BufferPath $BufferPath
    $text = Read-ReviewBufferText -Path $path
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    # Добавление записи с дедупликацией: один вердикт на (задача|агент|строка|источник).
    $addEntry = {
        param($Agent, $TaskKey, $Category, $RawVerdict, $Source, $Time, $Line, $Snippet)

        $key = '{0}|{1}|{2}|{3}' -f $TaskKey, $Agent, $Line, $Source
        if (-not $seen.Add($key)) { return }

        $timeDisplay = ''
        if ($null -ne $Time) {
            if ($Time.Hour -eq 0 -and $Time.Minute -eq 0 -and $Time.Second -eq 0) {
                $timeDisplay = $Time.ToString('yyyy-MM-dd')
            } else {
                $timeDisplay = $Time.ToString('yyyy-MM-dd HH:mm')
            }
        }

        $null = $entries.Add([PSCustomObject]@{
            agent        = $Agent
            task_key     = if ([string]::IsNullOrWhiteSpace($TaskKey)) { '' } else { $TaskKey }
            verdict      = $Category
            raw_verdict  = $RawVerdict
            source       = $Source
            time         = $Time
            time_display = $timeDisplay
            line         = $Line
            snippet      = $Snippet
        })
    }

    $headers = [regex]::Matches($text, $script:ReviewHeaderPattern)

    for ($hi = 0; $hi -lt $headers.Count; $hi++) {
        try {
            $header = $headers[$hi]
            $bodyStart = $header.Index + $header.Length
            $bodyEnd = if ($hi + 1 -lt $headers.Count) { $headers[$hi + 1].Index } else { $text.Length }
            if ($bodyEnd -lt $bodyStart) { continue }

            $body = $text.Substring($bodyStart, $bodyEnd - $bodyStart)
            $headerLine = Get-ReviewLineNumber -Text $text -Index $header.Index
            $author = Get-ReviewAgentName -Raw $header.Groups['agent'].Value
            $recordTime = ConvertTo-ReviewTime -Stamp $header.Groups['stamp'].Value

            # Ключ задачи записи: явный task_id > первый тег.
            $primaryTask = Get-ReviewTaskKey -Text $body

            # Вердикты проставляют только проверяющие (тот же allowlist, что и для
            # релей-строк): проза исполнителя ("verdict pass", "STATUS: ok" и т.п.)
            # не должна создавать "проверяющего" и ложное расхождение.
            $authorIsReviewer = ($author -match $script:ReviewReviewerAllowlist)

            # --- форма 1: маркер VERDICT/ВЕРДИКТ (автор = автор записи) ---
            if ($authorIsReviewer) {
                foreach ($marker in [regex]::Matches($body, $script:ReviewMarkerPattern)) {
                    $category = Get-ReviewVerdictCategory -Token $marker.Groups['tok'].Value
                    if ($null -eq $category) { continue }
                    $lineNo = Get-ReviewLineNumber -Text $text -Index ($bodyStart + $marker.Index)
                    $lineText = ($text -split "\r?\n")[$lineNo - 1]
                    & $addEntry $author $primaryTask $category $marker.Groups['tok'].Value 'verdict-marker' $recordTime $lineNo (Get-ReviewSnippet -Line $lineText)
                }
            }

            # --- форма 3: поле STATUS: <токен> (только известные вердикты) ---
            if ($authorIsReviewer) {
                foreach ($status in [regex]::Matches($body, $script:ReviewStatusFieldPattern)) {
                    $category = Get-ReviewVerdictCategory -Token $status.Groups['tok'].Value
                    if ($null -eq $category) { continue }
                    $lineNo = Get-ReviewLineNumber -Text $text -Index ($bodyStart + $status.Index)
                    $lineText = ($text -split "\r?\n")[$lineNo - 1]
                    & $addEntry $author $primaryTask $category $status.Groups['tok'].Value 'status-field' $recordTime $lineNo (Get-ReviewSnippet -Line $lineText)
                }
            }

            # --- форма 2: релей-строки "<reviewer>: <токен>" ---
            # Первый элемент split - остаток САМОЙ строки заголовка, поэтому
            # курсор начинается с номера заголовка (а не headerLine + 1).
            $lineCursor = $headerLine
            foreach ($line in ($body -split "\r?\n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $relay = [regex]::Match($line, $script:ReviewRelayPattern)
                    if ($relay.Success) {
                        $relayAgent = $relay.Groups['agent'].Value.ToLowerInvariant()
                        if ($relayAgent -match $script:ReviewReviewerAllowlist) {
                            $category = Get-ReviewVerdictCategory -Token $relay.Groups['tok'].Value
                            if ($null -ne $category) {
                                # Тег в самой строке точнее тега записи (релей разных задач).
                                $lineTask = Get-ReviewTaskKey -Text $line
                                if ([string]::IsNullOrWhiteSpace($lineTask)) { $lineTask = $primaryTask }
                                & $addEntry $relayAgent $lineTask $category $relay.Groups['tok'].Value 'relay-line' $recordTime $lineCursor (Get-ReviewSnippet -Line $line)
                            }
                        }
                    }
                }
                $lineCursor++
            }
        } catch {
            # Одна сломанная запись не должна рушить разбор всего буфера.
            Write-Verbose "review-disagreement: record #$hi skipped: $($_.Exception.Message)"
            continue
        }
    }

    return @($entries | Sort-Object line)
}

# ============================================================
# Get-ReviewVerdicts [-Root] [-BufferPath] [-SinceHours N] [-TaskId X]
# Нормализованные вердикты проверяющих. -SinceHours = 0 -> без фильтра по
# времени; записи без разбираемой метки ([TIME]) сохраняются всегда.
# ============================================================
function Get-ReviewVerdicts {
    param(
        [string]$Root = '',
        [string]$BufferPath = '',
        [int]$SinceHours = 0,
        [string]$TaskId = ''
    )

    $entries = @(Read-ReviewVerdictEntries -Root $Root -BufferPath $BufferPath)

    if ($SinceHours -gt 0 -and $entries.Count -gt 0) {
        $cutoff = (Get-Date).AddHours(-$SinceHours)
        $entries = @($entries | Where-Object { $null -eq $_.time -or $_.time -ge $cutoff })
    }

    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $wanted = $TaskId.Trim()
        $entries = @($entries | Where-Object { $_.task_key -eq $wanted })
    }

    return $entries
}

# ============================================================
# Find-ReviewDisagreement [-Root] [-BufferPath] [-SinceHours N] [-TaskId X]
# Задачи, где после схлопывания "последний вердикт каждого проверяющего"
# есть и accept, и reject от РАЗНЫХ агентов.
# ============================================================
function Find-ReviewDisagreement {
    param(
        [string]$Root = '',
        [string]$BufferPath = '',
        [int]$SinceHours = 0,
        [string]$TaskId = ''
    )

    $disagreements = New-Object System.Collections.ArrayList
    $verdicts = @(Get-ReviewVerdicts -Root $Root -BufferPath $BufferPath -SinceHours $SinceHours -TaskId $TaskId |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.task_key) })

    if ($verdicts.Count -eq 0) { return @() }

    foreach ($group in ($verdicts | Group-Object -Property task_key)) {
        # Последний вердикт каждого агента (позиция в append-only шине = хронология).
        $latestByAgent = @{}
        foreach ($entry in $group.Group) {
            $agent = [string]$entry.agent
            if ((-not $latestByAgent.ContainsKey($agent)) -or ([int]$entry.line -ge [int]$latestByAgent[$agent].line)) {
                $latestByAgent[$agent] = $entry
            }
        }

        $latest = @($latestByAgent.Values)
        $accepts = @($latest | Where-Object { $_.verdict -eq 'accept' })
        $rejects = @($latest | Where-Object { $_.verdict -eq 'reject' })
        if ($accepts.Count -eq 0 -or $rejects.Count -eq 0) { continue }

        $acceptDetails = @($accepts | ForEach-Object {
            [PSCustomObject]@{ agent = $_.agent; raw_verdict = $_.raw_verdict; time = $_.time_display; line = $_.line }
        })
        $rejectDetails = @($rejects | ForEach-Object {
            [PSCustomObject]@{ agent = $_.agent; raw_verdict = $_.raw_verdict; time = $_.time_display; line = $_.line }
        })

        $null = $disagreements.Add([PSCustomObject]@{
            task_key       = $group.Name
            accept_agents  = (@($accepts | ForEach-Object { $_.agent }) -join ', ')
            reject_agents  = (@($rejects | ForEach-Object { $_.agent }) -join ', ')
            accept         = $acceptDetails
            reject         = $rejectDetails
            reviewers      = (@($latest | ForEach-Object { $_.agent }) -join ', ')
            last_line      = ($latest | Measure-Object -Property line -Maximum).Maximum
            last_time      = ($latest | Sort-Object line | Select-Object -Last 1).time_display
        })
    }

    return @($disagreements | Sort-Object last_line)
}

# ============================================================
# Форматирование таблицы расхождений (для CLI).
# ============================================================
function Format-ReviewDisagreementLines {
    param([object[]]$Items)

    $lines = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        $null = $lines.Add(("  [{0}] task {1} (last verdict line {2})" -f $item.last_time, $item.task_key, $item.last_line))
        foreach ($side in @($item.accept)) {
            $null = $lines.Add(("      accept: {0,-24} [{1}] (line {2})" -f $side.agent, $side.raw_verdict, $side.line))
        }
        foreach ($side in @($item.reject)) {
            $null = $lines.Add(("      reject: {0,-24} [{1}] (line {2})" -f $side.agent, $side.raw_verdict, $side.line))
        }
    }
    return @($lines)
}

# ============================================================
# Форматирование таблицы вердиктов (для CLI -All).
# ============================================================
function Format-ReviewVerdictLines {
    param([object[]]$Items)

    $lines = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        $taskKey = if ([string]::IsNullOrWhiteSpace($item.task_key)) { '<no-tag>' } else { $item.task_key }
        $null = $lines.Add(("  {0,-24} {1,-12} {2,-9} line {3,-5} {4}" -f $item.agent, $taskKey, $item.verdict, $item.line, $item.time_display))
    }
    return @($lines)
}

# ============================================================
# JSON для CLI: пустой результат всегда "[]" (ConvertTo-Json на пустом
# массиве в PS 5.1 печатает "[\r\n\r\n]", что неудобно парсить).
# ============================================================
function ConvertTo-ReviewJson {
    param([object[]]$Items)

    $array = @($Items)
    if ($array.Count -eq 0) { return '[]' }
    return (ConvertTo-Json -InputObject $array -Depth 6)
}

# ============================================================
# CLI (только при ПРЯМОМ запуске; dot-source выполняет лишь определения).
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $buffer = Get-ReviewBufferPath -Root $ReviewRoot -BufferPath $ReviewBufferPath

        if (-not (Test-Path -LiteralPath $buffer -PathType Leaf)) {
            if ($ReviewJson) { Write-Output '[]' }
            else { Write-Host ("review-disagreement: buffer not found: " + $buffer) -ForegroundColor Yellow }
            exit $exitCode
        }

        if ($ReviewAll) {
            $items = @(Get-ReviewVerdicts -Root $ReviewRoot -BufferPath $ReviewBufferPath -SinceHours $ReviewSinceHours -TaskId $ReviewTaskId)
            if ($ReviewJson) {
                Write-Output (ConvertTo-ReviewJson -Items $items)
            } else {
                Write-Host ("=== reviewer verdicts: {0} entr(ies) [buffer: {1}] ===" -f $items.Count, $buffer) -ForegroundColor Cyan
                if ($items.Count -eq 0) { Write-Host '  no verdicts found' } else { Format-ReviewVerdictLines -Items $items }
            }
        } else {
            $items = @(Find-ReviewDisagreement -Root $ReviewRoot -BufferPath $ReviewBufferPath -SinceHours $ReviewSinceHours -TaskId $ReviewTaskId)
            if ($ReviewJson) {
                Write-Output (ConvertTo-ReviewJson -Items $items)
            } else {
                Write-Host ("=== reviewer disagreements: {0} [buffer: {1}] ===" -f $items.Count, $buffer) -ForegroundColor Cyan
                if ($items.Count -eq 0) { Write-Host '  none' } else { Format-ReviewDisagreementLines -Items $items }
            }
        }
    } catch {
        Write-Error ("review-disagreement failed: " + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
