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

## Patterns

### PowerShell encoding pitfalls on Windows
- PowerShell 5.1 uses cp1251 console encoding by default
- UTF-8 without BOM: use `[System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::UTF8)` or BOM
- Set-Content -Encoding UTF8 on PS 5.1 may not produce clean UTF-8; prefer .NET methods
- Emojis (❌✅💀📂🔍🚀📄⏳) contain bytes that overlap with cp1251 special characters — always use UTF-8 BOM for scripts containing them
