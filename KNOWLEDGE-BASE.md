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

## Patterns

### PowerShell encoding pitfalls on Windows
- PowerShell 5.1 uses cp1251 console encoding by default
- UTF-8 without BOM: use `[System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::UTF8)` or BOM
- Set-Content -Encoding UTF8 on PS 5.1 may not produce clean UTF-8; prefer .NET methods
- Emojis (❌✅💀📂🔍🚀📄⏳) contain bytes that overlap with cp1251 special characters — always use UTF-8 BOM for scripts containing them
- Em-dash (U+2014, —) also breaks cp1251 parsing — any non-ASCII character (Cyrillic, em-dash, curly quotes) in a UTF-8-without-BOM file causes ParserError on Russian Windows PowerShell 5.1
- Rule: ALL .ps1 files in .agents/scripts/ MUST have UTF-8 BOM if they contain any non-ASCII characters
