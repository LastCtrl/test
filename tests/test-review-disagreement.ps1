# test-review-disagreement.ps1 - изолированные тесты детектора расхождений
# вердиктов проверяющих (.agents\scripts\review-disagreement.ps1).
#
# Требования ТЗ:
#   (а) согласие accept+accept по одной задаче -> расхождения НЕТ;
#   (б) расхождение qa accept / code-reviewer reject по одной задаче -> найдено;
#   (в) вердикты по РАЗНЫМ задачам не путаются;
#   (г) пустой/битый/бинарный буфер -> без падения;
#   (д) нормализация статусов (PASS/ПРИНЯТО/ACCEPT/OK -> accept и т.д.).
# Дополнительно закрыты эвристики детектора: ре-ревью того же агента перекрывает
# его старый вердикт; релей-строка "<reviewer>: <вердикт>" (форма реального
# инцидента P0); CLI-режимы (-Status/-All/-Json); инварианты файла (CRLF/BOM/парсер).
#
# Каждый кейс работает в СВОЁМ временном корне через $env:AGENT_HQ_ROOT,
# библиотека подключается через dot-source (CLI не запускается).
# Exit code: 0 - все проверки прошли, 1 - есть FAIL.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Target   = Join-Path $RepoRoot ".agents\scripts\review-disagreement.ps1"
$TempBase = Join-Path $env:TEMP "agent-hq-review-disagreement-tests"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
        $script:Pass++
    } else {
        Write-Host ("    FAIL: " + $Label)
        $script:Fail++
    }
}

function New-FixtureRoot {
    # -NoBuffer: каталог без CONTEXT-BUFFER.md (проверка "буфера нет").
    # Без switch создаётся файл с -BufferText (пустая строка тоже валидна:
    # $null биндится к [string] как '', поэтому "нет файла" возможен только так).
    param([string]$BufferText, [switch]$NoBuffer)
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (-not $NoBuffer) {
        [System.IO.File]::WriteAllText((Join-Path $root "CONTEXT-BUFFER.md"), $BufferText, $Utf8NoBom)
    }
    return $root
}

function Remove-FixtureRoot {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Запись шины в каноническом виде self-report'а.
function New-Report {
    param(
        [string]$Stamp, [string]$Agent, [string]$Verdict, [string]$TaskTag,
        [string]$Status = "resolved"
    )
    return @(
        ("[{0}] {1} -> team-lead:" -f $Stamp, $Agent)
        "TYPE: update | PRIORITY: medium"
        "Project: agent-hq"
        ("CONTENT: Приёмка {0}. VERDICT: {1}. Детали проверки приложены." -f $TaskTag, $Verdict)
        "SKILLS_LOADED: [`"evidence-discipline`"]"
        "MCP_USED: [`"sequential-thinking`"]"
        "COMPLIANCE: true"
        ("STATUS: {0}" -f $Status)
        ""
    ) -join "`r`n"
}

# --- кейсы -----------------------------------------------------------------

function Test-AgreementCase {
    $buffer = (New-Report "2026-09-17 10:00" "qa-engineer"   "PASS"    "TASK-100") +
              (New-Report "2026-09-17 10:20" "code-reviewer" "APPROVE" "TASK-100")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $verdicts = @(Get-ReviewVerdicts -Root $root)
        Write-Check "a) 2 вердикта собрано" ($verdicts.Count -eq 2)
        Write-Check "a) оба нормализованы в accept" (@($verdicts | Where-Object { $_.verdict -eq 'accept' }).Count -eq 2)
        Write-Check "a) первая запись = qa-engineer/TASK-100" ($verdicts[0].agent -eq 'qa-engineer' -and $verdicts[0].task_key -eq 'TASK-100')
        Write-Check "a) согласие -> расхождений 0" (@(Find-ReviewDisagreement -Root $root).Count -eq 0)
    } finally { Remove-FixtureRoot $root }
}

function Test-DisagreementCase {
    $buffer = (New-Report "2026-09-17 11:00" "qa-engineer"   "PASS"   "TASK-200") +
              (New-Report "2026-09-17 11:30" "code-reviewer" "REJECT" "TASK-200")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $disagreements = @(Find-ReviewDisagreement -Root $root)
        Write-Check "b) расхождение найдено (1)" ($disagreements.Count -eq 1)
        if ($disagreements.Count -eq 1) {
            $d = $disagreements[0]
            Write-Check "b) task_key = TASK-200" ($d.task_key -eq 'TASK-200')
            Write-Check "b) accept сторона = qa-engineer" ($d.accept_agents -eq 'qa-engineer')
            Write-Check "b) reject сторона = code-reviewer" ($d.reject_agents -eq 'code-reviewer')
            Write-Check "b) стороны детализированы (raw-вердикты)" (@($d.accept)[0].raw_verdict -eq 'PASS' -and @($d.reject)[0].raw_verdict -eq 'REJECT')
            Write-Check "b) у сторон есть строки источника" (@($d.accept)[0].line -gt 0 -and @($d.reject)[0].line -gt 0)
        }
    } finally { Remove-FixtureRoot $root }
}

function Test-DifferentTasksCase {
    $buffer = (New-Report "2026-09-17 12:00" "qa-engineer"   "PASS"   "TASK-301") +
              (New-Report "2026-09-17 12:30" "code-reviewer" "REJECT" "TASK-302")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        Write-Check "c) разные задачи -> расхождений 0" (@(Find-ReviewDisagreement -Root $root).Count -eq 0)

        $onlyQa = @(Get-ReviewVerdicts -Root $root -TaskId 'TASK-301')
        Write-Check "c) -TaskId TASK-301 даёт 1 запись" ($onlyQa.Count -eq 1)
        Write-Check "c) TASK-301 принадлежит qa-engineer" ($onlyQa.Count -eq 1 -and $onlyQa[0].agent -eq 'qa-engineer' -and $onlyQa[0].verdict -eq 'accept')

        $onlyReviewer = @(Get-ReviewVerdicts -Root $root -TaskId 'TASK-302')
        Write-Check "c) TASK-302 принадлежит code-reviewer" ($onlyReviewer.Count -eq 1 -and $onlyReviewer[0].agent -eq 'code-reviewer' -and $onlyReviewer[0].verdict -eq 'reject')

        Write-Check "c) неизвестная задача -> 0 записей" (@(Get-ReviewVerdicts -Root $root -TaskId 'TASK-999').Count -eq 0)
    } finally { Remove-FixtureRoot $root }
}

function Test-BrokenBufferCase {
    # Пустой буфер.
    $emptyRoot = New-FixtureRoot -BufferText ""
    try {
        Write-Check "г) пустой буфер: вердиктов 0" (@(Get-ReviewVerdicts -Root $emptyRoot).Count -eq 0)
        Write-Check "г) пустой буфер: расхождений 0" (@(Find-ReviewDisagreement -Root $emptyRoot).Count -eq 0)
    } finally { Remove-FixtureRoot $emptyRoot }

    # Буфера нет вовсе.
    $missingRoot = New-FixtureRoot -NoBuffer
    try {
        Write-Check "г) буфер отсутствует: вердиктов 0" (@(Get-ReviewVerdicts -Root $missingRoot).Count -eq 0)
        Write-Check "г) буфер отсутствует: расхождений 0" (@(Find-ReviewDisagreement -Root $missingRoot).Count -eq 0)
    } finally { Remove-FixtureRoot $missingRoot }

    # Битый текст: обрывки заголовков, стрелка без агента, пустые скобки, мусор.
    $garbage = @(
        "[broken"
        "-> :"
        "[2026-09-17 13:00]  -> team-lead:"
        ")(" 
        "[2026-09-17 13:10] ghost -> team-lead:"
        "CONTENT: VERDICT:"
        "STATUS:"
        "[2026-09-17] dev-1 -> team-lead:"
        "CONTENT: без векторов и меток"
        ""
    ) -join "`r`n"
    $garbageRoot = New-FixtureRoot -BufferText $garbage
    try {
        $ok = $true
        try {
            $v = @(Get-ReviewVerdicts -Root $garbageRoot)
            $d = @(Find-ReviewDisagreement -Root $garbageRoot)
        } catch { $ok = $false }
        Write-Check "г) битый текст: разбор не бросает исключение" $ok
        Write-Check "г) битый текст: мусор не даёт вердиктов" ($ok -and $v.Count -eq 0 -and $d.Count -eq 0)
    } finally { Remove-FixtureRoot $garbageRoot }

    # Бинарный буфер.
    $binaryRoot = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $binaryRoot -Force | Out-Null
    try {
        $bytes = New-Object byte[] 512
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte](($i * 37) % 256) }
        [System.IO.File]::WriteAllBytes((Join-Path $binaryRoot "CONTEXT-BUFFER.md"), $bytes)
        $ok = $true
        try {
            $v = @(Get-ReviewVerdicts -Root $binaryRoot)
            $d = @(Find-ReviewDisagreement -Root $binaryRoot)
        } catch { $ok = $false }
        Write-Check "г) бинарный буфер: не бросает исключение" $ok
        Write-Check "г) бинарный буфер: вердиктов 0" ($ok -and $v.Count -eq 0 -and $d.Count -eq 0)
    } finally { Remove-FixtureRoot $binaryRoot }
}

function Test-NormalizationCase {
    # (д) прямая проверка нормализации токенов.
    $acceptTokens = @('PASS', 'ПРИНЯТО', 'ACCEPT', 'ACCEPTED', 'OK', 'APPROVE', 'APPROVED', 'PRINJATO', '**PASS**', 'ПРИНЯТО,')
    foreach ($token in $acceptTokens) {
        Write-Check ("д) '" + $token + "' -> accept") ((Get-ReviewVerdictCategory -Token $token) -eq 'accept')
    }

    $rejectTokens = @('REJECT', 'ВОЗВРАТЬ', 'ВОЗВРАТ', 'FAIL', 'FAILED', 'REQUEST_CHANGES', 'VOZVRAT')
    foreach ($token in $rejectTokens) {
        Write-Check ("д) '" + $token + "' -> reject") ((Get-ReviewVerdictCategory -Token $token) -eq 'reject')
    }

    Write-Check "д) 'ЧАСТИЧНО' -> partial" ((Get-ReviewVerdictCategory -Token 'ЧАСТИЧНО') -eq 'partial')
    Write-Check "д) 'BLOCKER' -> blocker" ((Get-ReviewVerdictCategory -Token 'BLOCKER') -eq 'blocker')
    Write-Check "д) 'resolved' -> не вердикт" ($null -eq (Get-ReviewVerdictCategory -Token 'resolved'))
    Write-Check "д) 'P1-4' -> не вердикт" ($null -eq (Get-ReviewVerdictCategory -Token 'P1-4'))
    Write-Check "д) пустой токен -> не вердикт" ($null -eq (Get-ReviewVerdictCategory -Token ''))

    # (д) интеграционно: STATUS-поле с вердиктом и markdown-обёртка в маркере.
    $buffer = @(
        "[2026-09-17 14:00] qa-engineer -> team-lead:"
        "TYPE: update"
        "CONTENT: Приёмка TASK-400. Вердикт: **PASS** (10/10)."
        "STATUS: resolved"
        ""
        "[2026-09-17 14:10] code-reviewer -> team-lead:"
        "TYPE: update"
        "CONTENT: Разбор TASK-400."
        "STATUS: REJECT"
        ""
    ) -join "`r`n"
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $verdicts = @(Get-ReviewVerdicts -Root $root)
        Write-Check "д) маркер с markdown -> accept" (@($verdicts | Where-Object { $_.raw_verdict -eq 'PASS' -and $_.verdict -eq 'accept' }).Count -eq 1)
        Write-Check "д) STATUS: REJECT -> reject" (@($verdicts | Where-Object { $_.source -eq 'status-field' -and $_.verdict -eq 'reject' }).Count -eq 1)
        Write-Check "д) mixed-формы дают расхождение" (@(Find-ReviewDisagreement -Root $root).Count -eq 1)
    } finally { Remove-FixtureRoot $root }
}

function Test-LatestVerdictWinsCase {
    # Ре-ревью того же проверяющего перекрывает его старый ВОЗВРАТ -> расхождения нет.
    $buffer = (New-Report "2026-09-17 15:00" "qa-engineer" "ВОЗВРАТЬ" "P1-4") +
              (New-Report "2026-09-17 15:40" "qa-engineer" "ПРИНЯТО"  "P1-4")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $verdicts = @(Get-ReviewVerdicts -Root $root)
        Write-Check "e) сохранены оба вердикта агента (2)" ($verdicts.Count -eq 2)
        Write-Check "e) ре-ревью того же агента -> расхождений 0" (@(Find-ReviewDisagreement -Root $root).Count -eq 0)
    } finally { Remove-FixtureRoot $root }
}

function Test-RelayLineCase {
    # Форма реального инцидента P0: тимлид релеит вердикты двух проверяющих.
    $buffer = @(
        "[2026-09-15] team-lead -> bus: вердикты приёмки P0 (расхождение)"
        "TYPE: update | PRIORITY: high"
        "qa-engineer (opencode/ling-3.0-flash-fin-free): ПРИНЯТО, 0 дефектов. 8/8 проверок OK"
        "code-reviewer (aihubmix/gpt-5.5-free): ВОЗВРАТЬ, 2 major:"
        "  1) Portability: sync-agents.ps1:182 root не из AGENT_HQ_ROOT."
        "Итог: ВОЗВРАТЬ -> фикс у dev-3."
        "STATUS: resolved"
        ""
    ) -join "`r`n"
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $relay = @(Get-ReviewVerdicts -Root $root | Where-Object { $_.source -eq 'relay-line' })
        Write-Check "релей: 2 вердикта из строк от проверяющих" ($relay.Count -eq 2)
        Write-Check "релей: 'Итог:' не создаёт вердикт третьего агента" (@($relay | Where-Object { $_.agent -eq 'итог' }).Count -eq 0)
        $d = @(Find-ReviewDisagreement -Root $root)
        Write-Check "релей: расхождение P0 найдено" ($d.Count -eq 1 -and $d[0].task_key -eq 'P0')
    } finally { Remove-FixtureRoot $root }
}

function Test-CliCase {
    # CLI в ДОЧЕРНЕМ процессе (изоляция exit-кода и stdout).
    $buffer = (New-Report "2026-09-17 16:00" "qa-engineer"   "PASS"   "TASK-500") +
              (New-Report "2026-09-17 16:30" "code-reviewer" "REJECT" "TASK-500")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $jsonText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Status -Json -Root $root 2>&1 | Out-String
        $cliExit = $LASTEXITCODE
        $parsed = $null
        $parseOk = $true
        try { $parsed = $jsonText | ConvertFrom-Json } catch { $parseOk = $false }
        Write-Check "CLI -Status -Json: exit 0" ($cliExit -eq 0)
        Write-Check "CLI -Status -Json: валидный JSON" $parseOk
        Write-Check "CLI -Status -Json: 1 расхождение по TASK-500" ($parseOk -and @($parsed).Count -eq 1 -and @($parsed)[0].task_key -eq 'TASK-500')

        $allText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -All -Root $root 2>&1 | Out-String
        Write-Check "CLI -All: exit 0" ($LASTEXITCODE -eq 0)
        Write-Check "CLI -All: печатает обе записи" ($allText -match 'qa-engineer' -and $allText -match 'code-reviewer')
    } finally { Remove-FixtureRoot $root }

    # Пустой корень: CLI не падает и не выдумывает расхождений.
    $emptyRoot = New-FixtureRoot -NoBuffer
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Status -Json -Root $emptyRoot 2>&1 | Out-String
        Write-Check "CLI нет буфера: exit 0" ($LASTEXITCODE -eq 0)
        Write-Check "CLI нет буфера: JSON-массив пуст" (($out.Trim()) -eq '[]')
    } finally { Remove-FixtureRoot $emptyRoot }

    # Буфер есть, но вердиктов нет: пустой JSON тоже должен быть "[]".
    $verdictlessRoot = New-FixtureRoot -BufferText ("[2026-09-17 17:00] dev-1 -> team-lead:`r`nTYPE: update`r`nCONTENT: без вердиктов`r`nSTATUS: resolved`r`n")
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Status -Json -Root $verdictlessRoot 2>&1 | Out-String
        Write-Check "CLI без вердиктов: exit 0" ($LASTEXITCODE -eq 0)
        Write-Check "CLI без вердиктов: JSON-массив пуст" (($out.Trim()) -eq '[]')
    } finally { Remove-FixtureRoot $verdictlessRoot }
}

function Test-FileInvariantsCase {
    Write-Check "инвариант: review-disagreement.ps1 существует" (Test-Path -LiteralPath $Target -PathType Leaf)

    $bytes = [System.IO.File]::ReadAllBytes($Target)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Check "инвариант: UTF-8 BOM (кириллица в шаблонах)" $hasBom

    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
    }
    Write-Check "инвариант: CRLF (lone LF = 0)" (($lf - $crlf) -eq 0 -and $crlf -gt 0)

    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Target -Raw), [ref]$errors)
    Write-Check "инвариант: PSParser 0 ошибок" ($errors.Count -eq 0)
}

function Test-ProseVerdictNotReviewerCase {
    # Проза исполнителя ("verdict pass", автономная строка "STATUS: ok") НЕ должна
    # создавать "проверяющего": иначе accept исполнителя спорит с reject реального
    # проверяющего и рождается ложное расхождение.
    $buffer = @(
        "[2026-09-17 18:00] dev-3 -> team-lead:"
        "TYPE: update | PRIORITY: low"
        "Project: agent-hq"
        "CONTENT: Фикс P2-1 готов, локально verdict pass, прошу приёмку."
        "STATUS: ok"
        ""
        "[2026-09-17 18:10] qa-engineer -> team-lead:"
        "TYPE: update | PRIORITY: medium"
        "CONTENT: Приёмка P2-1. VERDICT: REJECT. Найден дефект."
        "STATUS: resolved"
        ""
    ) -join "`r`n"
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $verdicts = @(Get-ReviewVerdicts -Root $root)
        Write-Check "п) проза исполнителя не создаёт вердикта" (@($verdicts | Where-Object { $_.agent -eq 'dev-3' }).Count -eq 0)
        Write-Check "п) остался только вердикт проверяющего" ($verdicts.Count -eq 1 -and $verdicts[0].agent -eq 'qa-engineer' -and $verdicts[0].verdict -eq 'reject')
        Write-Check "п) ложного расхождения нет" (@(Find-ReviewDisagreement -Root $root).Count -eq 0)
    } finally { Remove-FixtureRoot $root }

    # Парный контроль: настоящие accept/reject от РАЗНЫХ проверяющих -> расхождение есть.
    $buffer = (New-Report "2026-09-17 19:00" "qa-engineer"   "PASS"   "P2-1") +
              (New-Report "2026-09-17 19:10" "code-reviewer" "REJECT" "P2-1")
    $root = New-FixtureRoot -BufferText $buffer
    try {
        $d = @(Find-ReviewDisagreement -Root $root)
        Write-Check "п) реальные accept+reject -> расхождение найдено" ($d.Count -eq 1 -and $d[0].task_key -eq 'P2-1')
    } finally { Remove-FixtureRoot $root }
}

function Test-StructuralContinuationCase {
    # Продолжение свободного текста после CONTENT — не структурное поле: строка
    # "PRIORITY: ..." не должна распознаваться как поле вердикта. Статус-поле
    # принимается только в структурной части записи (до CONTENT / канонический хвост).
    $buffer = @(
        "[2026-09-17 20:00] qa-engineer -> team-lead:"
        "TYPE: update | PRIORITY: medium"
        "CONTENT: Приёмка P2-7. Ниже — цитата self-report'а исполнителя."
        "PRIORITY: critical"
        "STATUS: ok"
        ""
    ) -join "`r`n"
    $root = New-FixtureRoot -BufferText $buffer
    try {
        Write-Check "с) continuation PRIORITY/STATUS не даёт вердикта" (@(Get-ReviewVerdicts -Root $root).Count -eq 0)
        Write-Check "с) relay-шаблон не признаёт PRIORITY полем вердикта" (-not ([regex]::Match('PRIORITY: PASS', $script:ReviewRelayPattern).Success))
    } finally { Remove-FixtureRoot $root }

    # Буквально: продолжение, начинающееся ровно с "PRIORITY: <вердикт>".
    $buffer2 = @(
        "[2026-09-17 20:10] qa-engineer -> team-lead:"
        "TYPE: update | PRIORITY: medium"
        "CONTENT: Приёмка P2-8. Продолжение текста:"
        "PRIORITY: PASS"
        "STATUS: resolved"
        ""
    ) -join "`r`n"
    $root2 = New-FixtureRoot -BufferText $buffer2
    try {
        Write-Check "с) свободный 'PRIORITY: PASS' не даёт вердикта" (@(Get-ReviewVerdicts -Root $root2).Count -eq 0)
    } finally { Remove-FixtureRoot $root2 }

    # Положительный контроль: канонический STATUS: REJECT в структурном хвосте.
    $buffer3 = @(
        "[2026-09-17 20:20] code-reviewer -> team-lead:"
        "TYPE: update | PRIORITY: medium"
        "Project: agent-hq"
        "CONTENT: Разбор P2-9 без отдельного маркера."
        "COMPLIANCE: true"
        "STATUS: REJECT"
        ""
    ) -join "`r`n"
    $root3 = New-FixtureRoot -BufferText $buffer3
    try {
        $verdicts3 = @(Get-ReviewVerdicts -Root $root3)
        Write-Check "с) канонический STATUS: REJECT распознан" (@($verdicts3 | Where-Object { $_.source -eq 'status-field' -and $_.verdict -eq 'reject' }).Count -eq 1)
    } finally { Remove-FixtureRoot $root3 }
}

# --- runner ----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
    Write-Host ("FATAL: target script not found: " + $Target)
    exit 1
}

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

# Библиотека подключается dot-source'ом: функции доступны, CLI не выполняется.
. $Target

$originalRoot = $env:AGENT_HQ_ROOT
try {
    Write-Host "=== review-disagreement detector tests ==="

    Test-AgreementCase
    Test-DisagreementCase
    Test-DifferentTasksCase
    Test-BrokenBufferCase
    Test-NormalizationCase
    Test-LatestVerdictWinsCase
    Test-RelayLineCase
    Test-ProseVerdictNotReviewerCase
    Test-StructuralContinuationCase
    Test-CliCase
    Test-FileInvariantsCase
} finally {
    if ([string]::IsNullOrWhiteSpace($originalRoot)) {
        Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_ROOT = $originalRoot
    }
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
