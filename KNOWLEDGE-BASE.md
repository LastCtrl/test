# Knowledge Base — agent-hq

## Bugs & Solutions

### BUG-001: PowerShell `-or` возвращает Boolean вместо строки
- **Date**: 2026-08-25
- **Severity**: critical
- **File**: .agents/scripts/inbox-poller.ps1
- **Lines**: 97-103
- **Symptom**: Outbox/archive файлы названы `True.json` и `True-test-poller-task.json` вместо `test-poller-001.json` и `qa-engineer-test-poller-task.json`. Все мета-поля (id, from, to, type, priority, payload) содержат Boolean `$true` вместо строк.
- **Root cause**: PowerShell `-or` — логический оператор, возвращает `[bool]` (`$true`/`$false`), а не первый truthy operand (как JS `||`). Выражение `$msg.to -or ""` → `$true` (потому что `$msg.to = "qa-engineer"` truthy), а НЕ `"qa-engineer"`.
- **Fix**:
  ```powershell
  # BAD (returns Boolean):
  $messageId = $msg.id -or $fileName
  $from = $msg.from -or ""
  $to = $msg.to -or ""

  # GOOD (returns string value):
  $messageId = if ($msg.id) { $msg.id } else { $fileName }
  $from = if ($msg.from) { $msg.from } else { "" }
  $to = if ($msg.to) { $msg.to } else { "" }
  $type = if ($msg.type) { $msg.type } else { "" }
  $priority = if ($msg.priority) { $msg.priority } else { "normal" }
  $payload = if ($msg.payload) { $msg.payload } else { "" }
  $created = if ($msg.created) { $msg.created } else { (Format-DateTime) }
  ```
- **Affected lines**: 97, 98, 99, 100, 101, 102, 103 (all field extractions)
- **Discovered by**: qa-engineer E2E test, 2026-08-25

### BUG-002: opencode ошибки не распознаются как failure
- **Date**: 2026-08-25
- **Severity**: major
- **File**: .agents/scripts/inbox-poller.ps1
- **Lines**: 152-157
- **Symptom**: Outbox содержит status:"done" с полным выводом ошибок opencode в response.
- **Root cause**: `opencode run` возвращает RC=0 даже при внутренних ошибках (agent not found, edit failures). `2>&1` захватывает stderr в `$result`, поэтому `$result` всегда непустой. Условие `if ($exitCode -eq 0 -and $result)` проходит.
- **Fix**: Добавить проверку `$result` на паттерны ошибок или использовать отдельный захват stderr через `$result = & opencode ... 2>$null; $err = & opencode ... 1>$null`.
- **Discovered by**: qa-engineer E2E test, 2026-08-25

### BUG-003: prompt-gate.ps1 — ParserError из-за отсутствия UTF-8 BOM + em-dash
- **Date**: 2026-08-25
- **Severity**: critical
- **File**: .agents/scripts/prompt-gate.ps1
- **Lines**: 79, 202, 210 (каскадная ошибка парсера)
- **Symptom**: Скрипт падает с ParserError «Непредвиденный токен "team-lead")» на строке 79. Отчёт не формируется, exit code = 1.
- **Root cause**: Файл без UTF-8 BOM (первые байты: 0x23 0x21 0x2F = `#!/`). Содержит 4 символа em-dash (U+2014) на строках 2, 24, 202, 205. PowerShell 5.1 на русской Windows читает файл как cp1251 → байт em-dash (0xE2 0x80 0x94) интерпретируется какcp1251-символ → ломает парсер строк → каскадный сбой.
- **Fix**: Добавить UTF-8 BOM (EF BB BF) в начало файла:
  ```powershell
  # Fix: read as UTF-8, write with BOM
  $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($path, $content, $utf8Bom)
  ```
- **Secondary issue**: Параметр `-Mode` объявлен Mandatory, но нигде не проверяется в логике — скрипт всегда делает одно и то же.
- **Discovered by**: qa-engineer независимая приёмка, 2026-08-25
- **Known同类 bug**: Тот же паттерн что BUG-001 в inbox-poller.ps1 (исправлен 2026-08-25 добавлением BOM)

### BUG-004: result_симкарты_бд (v2).xlsx — «Только в БД» первая колонка dst_host вместо src_host
- **Date**: 2026-09-01
- **Severity**: critical
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Только в БД»
- **Lines**: A1 (header), all data rows
- **Symptom**: Лист «Только в БД» начинается с колонки `[БД] dst_host` (IP назначения), а должен быть `[БД] src_host` (IP источника — тот, что сопоставляется с 1С).
- **Root cause**: В report_build_v2.js при формировании листа «Только в БД» использован неверный порядок колонок / неверное поле для первой позиции.
- **Fix**: Перенести `[БД] src_host` в первую позицию (колонка A), остальные сдвинуть.
- **Discovered by**: qa-engineer приёмка v2, 2026-09-01

### BUG-005: result_симкарты_бд (v2).xlsx — «Сводка» ИТОГО по некорректным пусто
- **Date**: 2026-09-01
- **Severity**: critical
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Сводка»
- **Lines**: Row 47 (ИТОГО)
- **Symptom**: В таблице филиалов строка ИТОГО показывает `39567 | 15199 | ` (пусто в колонке «Некорректные»), должно быть `39568 | 15199 | 8321`.
- **Root cause**: Формула/расчёт ИТОГО для колонки «Некорректные» не прописан или ссылается на пустой диапазон.
- **Fix**: Добавить SUM по колонке «Некорректные» (строки 28-46) в ячейку ИТОГО.
- **Discovered by**: qa-engineer приёмка v2, 2026-09-01

### BUG-006: filials/*.xlsx — лишняя колонка [1С] Raw в «Некорректные IP (1С)»
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/filials/*.xlsx (16 файлов)
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: Column S (19-я), header `[1С] Raw`
- **Symptom**: В главном файле лист «Некорректные IP (1С)» имеет 18 колонок (без Raw), в филиалах — 19 колонок с `[1С] Raw` в конце.
- **Root cause**: filials_build.js копирует структуру без удаления Raw-колонки, хотя ТЗ требует «Без Raw».
- **Fix**: В filials_build.js при формировании листа исключать колонку Raw (брать только первые 18 колонок как в главном файле).
- **Discovered by**: qa-engineer приёмка v2, 2026-09-01

### BUG-007: filials/*.xlsx — неверный формат причин в «Некорректные IP (1С)»
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/filials/*.xlsx (16 файлов)
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: Column R (`[1С] Причина`)
- **Symptom**: Главный файл использует `пусто` / `некорректный формат` (lowercase, без деталей). Филиалы используют `Пустое значение` / `Невалидный формат: <детали>` (capitalized, с деталями). Это ломает единообразие фильтров и сводок.
- **Root cause**: filials_build.js использует свою функцию simplifyReason (или не использует её), отличную от report_build_v2.js.
- **Fix**: Вынести simplifyReason в общий модуль и использовать в обоих скриптах. Формат: `пусто` / `некорректный формат`.
- **Discovered by**: qa-engineer приёмка v2, 2026-09-01

### BUG-008: filials/*.xlsx — название колонки [БД] src_host вместо src_host
- **Date**: 2026-09-01
- **Severity**: minor
- **File**: projects/симкарты+бд/filials/*.xlsx (16 файлов)
- **Sheet**: «Совпадения (сгруппированные)»
- **Lines**: A1 (header)
- **Symptom**: Главный файл: `src_host`. Филиалы: `[БД] src_host`. Несоответствие именования.
- **Root cause**: filials_build.js добавляет префикс `[БД]` при формировании заголовка.
- **Fix**: Использовать просто `src_host` как в главном файле.
- **Discovered by**: qa-engineer приёмка v2, 2026-09-01

### BUG-009: result_симкарты_бд (v2).xlsx — «Совпадения» src_host не первая колонка
- **Date**: 2026-09-01
- **Severity**: critical
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Совпадения»
- **Lines**: A1 (header), all data rows
- **Symptom**: Лист «Совпадения» начинается с `[1С] АйПиАдрес` (колонка 1), `src_host` из БД находится на колонке 26 как `[БД] src_host`. ТЗ требует `src_host` первой колонкой.
- **Root cause**: В report_build_v2.js при формировании листа «Совпадения» 1С-колонки идут первыми, затем БД-колонки с префиксом `[БД]`. Не выполнена перестановка `src_host` в начало.
- **Fix**: Переставить колонки: 1) `src_host` (без префикса), 2) остальные 1С-поля, 3) БД-поля (можно с префиксом `[БД]` или без).
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-010: result_симкарты_бд (v2).xlsx — «Только в 1С» первая колонка с префиксом [1С]
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Только в 1С»
- **Lines**: A1 (header)
- **Symptom**: Первая колонка `[1С] АйПиАдрес`, должна быть `src_host` / `АйПиАдрес` без префикса.
- **Root cause**: Аналогично BUG-009, префиксы добавляются ко всем 1С-колонкам без исключения ключевой.
- **Fix**: Первую колонку переименовать в `src_host` (или `АйПиАдрес`) без префикса.
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-011: result_симкарты_бд (v2).xlsx — Сводка: отсутствуют breakdown некорректных IP
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Сводка»
- **Lines**: Rows 50-80 (раздел «=== Некорректные IP (по фильтрам) ===»)
- **Symptom**: Для корректных IP есть 3 breakdown-таблицы (по ОператорСвязи, ВидТелефона, СпособНазначенияАйПи). Для некорректных — только по ОператорСвязи. Отсутствуют: по ВидТелефона, по СпособНазначенияАйПи, по причинам (пусто/некорректный формат).
- **Root cause**: Функция addBreakdownTable вызывается только для корректных данных. Для некорректных — частичная реализация.
- **Fix**: Расширить addBreakdownTable для генерации всех 4 breakdown-таблиц для некорректных IP (3 по полям + 1 по причинам).
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-012: result_симкарты_бд (v2).xlsx — «Некорректные IP (1С)»: Причина содержит 60+ значений вместо 2
- **Date**: 2026-09-01
- **Severity**: critical
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: Column R (18-я), header `[1С] Причина_некорректности`
- **Symptom**: Колонка Причина содержит 60+ уникальных значений: модели устройств (Cinterion, GPS, GSM), мусор (`<некорректный IP> (hash)`), даты, пустые строки. ТЗ требует только `пусто` / `некорректный формат`.
- **Root cause**: Функция simplifyReason не применяется или работает некорректно. Фильтр passesIncorrectFilter не нормализует причины.
- **Fix**: Применить simplifyReason ко всем строкам: если IP пустой/пробелы → `пусто`, иначе → `некорректный формат`. Убрать детализацию по типам устройств.
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-013: result_симкарты_бд (v2).xlsx — «Некорректные IP (1С)»: СпособНазначенияАйПи и ОператорСвязи содержат мусор
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/result_симкарты_бд (v2).xlsx
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: Columns K (СпособНазначенияАйПи), L (ОператорСвязи)
- **Symptom**: 
  - СпособНазначенияАйПи: 16 значений включая названия филиалов (`Филиал "Минские тепловые сети"`, `Филиал "ТЭЦ-5"`), пусто, `Статический`. Должно быть только `Статический` / `пусто`.
  - ОператорСвязи: 2529 уникальных значений — филиалы, даты, модели устройств, пусто. Должны быть только операторы связи (МТС, А1, life:) + пусто.
- **Root cause**: При формировании листа берутся сырые значения из 1С без нормализации/маппинга на справочники.
- **Fix**: Добавить нормализацию: маппинг значений 1С на допустимые enum'ы перед записью в Excel.
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-014: filials/*.xlsx — «Некорректные IP (1С)»: 18 колонок с префиксами [1С] вместо 3 групп
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/filials/*.xlsx (16 файлов)
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: All columns (1-18)
- **Symptom**: ТЗ требует структуру: `АйПиАдрес | Причина простая | 1С поля` (без Raw, без префиксов). Фактически: 18 колонок все с префиксом `[1С]`, последняя — `[1С] Причина` (не упрощённая).
- **Root cause**: filials_build.js копирует структуру главного файла без трансформации под ТЗ филиалов.
- **Fix**: Перепроектировать формирование листа: 1) `АйПиАдрес` (без префикса), 2) `Причина простая` (пусто/некорректный формат), 3) выбранные 1С-поля (без префиксов, без Raw).
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-015: filials/*.xlsx — «Некорректные IP (1С)»: Причина не упрощена (аналогично главному файлу)
- **Date**: 2026-09-01
- **Severity**: major
- **File**: projects/симкарты+бд/filials/*.xlsx (16 файлов)
- **Sheet**: «Некорректные IP (1С)»
- **Lines**: Column R (`[1С] Причина`)
- **Symptom**: Те же 60+ значений что и в главном файле. Нет упрощения до `пусто` / `некорректный формат`.
- **Root cause**: Общая функция simplifyReason не используется или сломана в обоих скриптах.
- **Fix**: Вынести simplifyReason в shared модуль, использовать в report_build_v2.js и filials_build.js.
- **Discovered by**: qa-engineer финальная приёмка v2, 2026-09-01

### BUG-016: compliance-gate обнаруживает исторические self-report без SKILLS_LOADED
- **Date**: 2026-09-15
- **Severity**: minor (non-blocker)
- **File**: .agents/scripts/compliance-gate.ps1; CONTEXT-BUFFER.md
- **Lines**: compliance-gate.ps1:67-82
- **Symptom**: default-запуск завершается с `Passed: 19`, `Failed: 5`; пять исторических записей имеют `SKILLS_LOADED empty`.
- **Root cause**: compliance-gate корректно применяет fail-closed правило для исторических self-report, в которых поле `SKILLS_LOADED` пустое; это состояние данных, а не падение валидатора.
- **Fix**: для строгого compliance обновить исторические записи или явно принять baseline; код compliance-gate менять не требуется.
- **Discovered by**: qa-engineer read-only QA, 2026-09-15

### BUG-017: pong-advanced — XSS через hostName в LAN room-list (произвольный JS)
- **Date**: 2026-09-15
- **Severity**: critical
- **File**: D:\Тест\pong-advanced\src\server\index.ts:214 (валидация), :351 (createRoom), :979 (buildRoomInfo); D:\Тест\pong-advanced\src\client\App.ts:597 (renderRoomList)
- **Lines**: index.ts:214 (`hostName: z.string().optional()` — без лимитов/санитизации); App.ts:593-605 (`item.innerHTML` с `${room.hostName}` без экранирования)
- **Symptom**: Любой LAN-клиент создаёт комнату с hostName `<img src=x onerror=...>`; другие клиенты при просмотре списка комнат исполняют произвольный JS в своём браузере.
- **Root cause**: hostName принимается сервером как сырая строка без ограничений (z.string().optional()), передаётся в room-list без экранирования и вставляется в innerHTML.
- **Proof (live)**: инъекция `<img src=x onerror="window.__xss=1">` → сервер вернул hostName как есть, img инжектился в DOM, onerror СРАБОТАЛ (window.__xss=1) — подтверждено Playwright-тестом на :3335.
- **Fix**: 1) сервер: ограничить hostName (длина ≤32, запрет `<>&"'` или экранирование); 2) клиент: использовать textContent вместо innerHTML для hostName (или экранировать HTML-сущности).
- **Discovered by**: qa-engineer независимая приёмка P3-D/P3-E, 2026-09-15
- **Status**: FIXED (2026-09-15) — сервер: `sanitizeHostName()` (whitelist `[\p{L}\p{N} _.-]`, ≤20, fallback 'Host', zod-transform + второй слой в createRoom); клиент: `renderRoomList` переписан на DOM API/textContent. QA re-check: 9 payload'ов → 'Host', `window.__xss` не установлен, onerror=0; кириллица/`Ping-Pong.1_2` сохранены.

### BUG-018: pong-advanced — покупка косметики без транзакции (UPDATE xp + INSERT user_cosmetics)
- **Date**: 2026-09-15
- **Severity**: major (латентный; в текущей архитектуре смягчён)
- **File**: D:\Тест\pong-advanced\src\server\index.ts:1568-1576 (+ level update :1585)
- **Lines**: 1568 (`UPDATE users SET xp = xp - ?`), 1573 (`INSERT INTO user_cosmetics`), 1585 (`UPDATE users SET level = ?`) — без BEGIN/COMMIT
- **Symptom**: При жёстком краше процесса между UPDATE и INSERT пользователь теряет XP без получения косметики (нарушение атомарности).
- **Root cause**: Два связанных write выполняются без транзакции; sql.js поддерживает `db.run('BEGIN')`/`db.run('COMMIT')`, но они не используются.
- **Mitigation (текущая архитектура)**: БД = sql.js in-memory, saveDatabase вызывается ТОЛЬКО при graceful shutdown (index.ts:1954). При жёстком краше теряется вся in-memory БД целиком — разрыв между UPDATE и INSERT неотличим от полного отката. Конкурентный запрос не может наблюдать промежуточное состояние (синхронный однопоточный sql.js). Риск станет реальным при добавлении периодического save на диск или переходе на файловую SQLite.
- **Fix**: обернуть UPDATE+INSERT(+level) в BEGIN/COMMIT (дёшево, закрывает латентный риск).
- **Discovered by**: qa-engineer независимая приёмка P3-D/P3-E, 2026-09-15
- **Status**: FIXED (2026-09-15) — `applyCosmeticPurchase()` обёрнут в BEGIN→UPDATE xp→INSERT→level→COMMIT, catch→ROLLBACK; unit-тест с PK-конфликтом INSERT подтверждает, что XP не списывается; QA HTTP-проверка: XP консистентен при 200/400/409.

## Patterns

### PowerShell encoding pitfalls on Windows
- PowerShell 5.1 uses cp1251 console encoding by default
- UTF-8 without BOM: use `[System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::UTF8)` or BOM
- Set-Content -Encoding UTF8 on PS 5.1 may not produce clean UTF-8; prefer .NET methods
- Emojis (❌✅💀📂🔍🚀📄⏳) contain bytes that overlap with cp1251 special characters — always use UTF-8 BOM for scripts containing them
- Em-dash (U+2014, —) also breaks cp1251 parsing — any non-ASCII character (Cyrillic, em-dash, curly quotes) in a UTF-8-without-BOM file causes ParserError on Russian Windows PowerShell 5.1
- Rule: ALL .ps1 files in .agents/scripts/ MUST have UTF-8 BOM if they contain any non-ASCII characters
