# Go-driver cut-over (M5): включение, проверка, откат

Runbook активации Go-драйвера шины (`agent-hq run-loop`) с сохранением
PowerShell-поллера как страховки. Код: `go/cmd/agent-hq/runloop.go`,
`go/internal/driver/driver.go`, `go/internal/loop/loop.go`.
Общее описание M5 — `go/README.md`, раздел «M5 cut-over».

## Как это работает

- Переключатель — файл `<repo>/.memory/driver.mode` (`go` | `ps`; файла нет =
  `ps`). Переменная `AGENT_HQ_DRIVER` перекрывает файл. Состояние —
  рантайм-машины, в git не хранится (`.gitignore`).
- Go-проход пишет liveness-файл `<repo>/.memory/driver.lock`
  (`{mode,pid,started_at,heartbeat_at,cycles}`).
- PS-поллер (`Test-GoDriverActive` в `.agents/scripts/inbox-engine.ps1`)
  пропускает цикл **только** если `driver.mode = go` И возраст heartbeat
  < 180 с.
- Прод-расписание: задача `agent-hq-go-loop` (Пн–Пт 08:00, повтор каждые
  2 мин, 9 ч, окно скрыто) запускает `go\bin\agent-hq.exe run-loop -once`
  через `.agents/scripts/run-go-loop-hidden.vbs` (cwd = корень репо).
- Каждый `-once` оставляет после себя свежий heartbeat, поэтому между двумя
  запусками расписания PS стоит. Расписание остановилось → heartbeat протух за
  180 с → PS снова ведёт работу сам.
- Задача `agent-hq-inbox-poller` НЕ удаляется и не меняется: это fallback.
- Гонки исключены арендами: SQLite-claim плюс зеркальный файловый
  `.memory/claims/<id>.claim.json` (CREATE_NEW) — одно сообщение не может быть
  выполнено дважды ни Go, ни PS.

## Включение

```powershell
# 1. Собрать бинарь в стабильный путь
cd <repo>\go
go build -o bin\agent-hq.exe ./cmd/agent-hq

# 2. Включить режим go
<repo>\go\bin\agent-hq.exe driver -set go

# 3. Зарегистрировать скрытое расписание (Пн-Пт 08:00, каждые 2 мин, 9 ч)
<repo>\.agents\scripts\register-go-loop-task.ps1
```

## Проверка

```powershell
# режим и свежесть heartbeat (go-heartbeat: true, lock-age < 180s)
<repo>\go\bin\agent-hq.exe driver

# один проход вручную; печатает processed/done/dead-letter/skipped
<repo>\go\bin\agent-hq.exe run-loop -once

# guard PS-поллера: True = PS пропускает цикл (Go ведёт)
$env:AGENT_HQ_ROOT='<repo>'
. <repo>\.agents\scripts\inbox-engine.ps1
Test-GoDriverActive

# расписание
Get-ScheduledTask -TaskName agent-hq-go-loop | Select-Object TaskName,State
Get-ScheduledTaskInfo -TaskName agent-hq-go-loop | Select-Object NextRunTime,LastRunTime,LastTaskResult
```

Ожидаемо: `driver` → `mode: go`, `go-heartbeat: true`; `Test-GoDriverActive`
→ `True`; `LastTaskResult` → `0` (0x41303 = «ещё не запускалась»).

## Откат

```powershell
# 1. Вернуть PS-драйвер (удаляет driver.mode и driver.lock)
<repo>\go\bin\agent-hq.exe driver -clear

# 2. Убрать расписание Go (любой из вариантов)
schtasks /Delete /TN agent-hq-go-loop /F
# либо
Unregister-ScheduledTask -TaskName agent-hq-go-loop -Confirm:$false
```

После `driver -clear`: `agent-hq driver` → `mode: ps`, `source: default`,
`go-heartbeat: false`; `Test-GoDriverActive` → `False`; PS-поллер ведёт задачи.
Задача `agent-hq-inbox-poller` продолжает работать всё это время.

Быстрый откат «только режим» (расписание оставить выключенным на потом):
`agent-hq driver -clear` останавливает лидерство Go, а `Disable-ScheduledTask
-TaskName agent-hq-go-loop` не даёт расписанию снова писать heartbeat.

## Границы

- `run-loop -once` работает независимо от `driver.mode` (ручной/тестовый
  прогон). Поэтому откат = `driver -clear` ПЛЮС снятие расписания; одного
  `-clear` достаточно для лидерства PS, но Go по расписанию продолжит проходы.
- Бинарь `go/bin/agent-hq.exe` не в git (`.gitignore`), пересобирается командой
  выше.
- Демон (`agent-hq run-loop` без `-once`) как прод-режим не используется:
  расписание из коротких проходов не оставляет фоновых процессов.
