# agent-hq Go CLI (этап G1)

Read-only CLI для инспекции состояния agent-hq. Это фундамент Go-фазы из
`AUDIT-CONSOLIDATED-2026-09-14.md` (P1 «Go foundation»): сначала безопасный
читатель состояния, потом — запись (SQLite, claims, daemon).

## Границы G1 (что сознательно НЕ сделано)

Реализовано: чтение и вывод состояния.

Не реализовано (следующие этапы, не входит в G1):

- любые записи на диск (CLI строго read-only);
- SQLite / `tasks` / `attempts` / `events` / `checkpoints`;
- атомарный claim, lease/heartbeat, release, stale-sweep;
- daemon, worker pool, watchdog/checkpoint/restart;
- сеть, MCP, внешние Go-модули (только стандартная библиотека);
- запись и миграции состояния — по-прежнему на PowerShell-скриптах.

## Требования

- Go 1.27+ (проверено на `go1.27.1 windows/amd64`).
- Внешние зависимости не нужны: модуль использует только stdlib.

## Сборка и проверки

Из каталога `go/`:

```powershell
go build ./...
go vet ./...
go test ./...
go build -o bin/agent-hq.exe ./cmd/agent-hq
```

`go test -cover ./...` даёт ~86% покрытия пакета `internal/state`.
Каталог `go/bin/` добавлен в `.gitignore`.

## Запуск

```powershell
go\bin\agent-hq.exe status
go\bin\agent-hq.exe status -json
go\bin\agent-hq.exe tasks -status queued
go\bin\agent-hq.exe leases -ttl 600 -stale
go\bin\agent-hq.exe evidence a1b2c3
go\bin\agent-hq.exe doctor
```

## Определение корня (root)

Приоритет:

1. переменная окружения `AGENT_HQ_ROOT`;
2. флаг `-root <path>`;
3. текущий рабочий каталог.

Флаги `-root` и `-json` можно ставить до или после подкоманды.

## Команды

| Команда | Назначение | Флаги |
|---------|-----------|-------|
| `status` | счётчики (evidence, claims, inbox/outbox/dead-letter, queue, projects) и лента последних активностей | `-limit N` |
| `tasks` | задачи из `projects/*/queue.json` плюс evidence-документы | `-agent <имя>`, `-status <статус>` |
| `leases` | аренды (claim) и их состояние по TTL | `-ttl <секунды>`, `-stale` |
| `evidence <id>` | детали одного evidence-документа (попытки, exit code, длительности, длины и SHA256 stdout/stderr) | — |
| `doctor` | здоровье каталогов и конфигов, версия CLI | — |
| `version` | версия CLI | — |

Все команды поддерживают `-json`.

Коды выхода: `0` — успех; `1` — проблемы (не найден evidence-документ,
нездоровый `doctor`); `2` — ошибка использования CLI.

## Форматы состояния (что читает CLI)

Источник форматов — действующие PowerShell-скрипты в `.agents/scripts/`.

- evidence: `.memory/evidence/<identifier>.json` —
  `{ "task_id", "attempts": [ { attempt_id, agent, exit_code, stdout_sha256,
  stdout_length, stderr_sha256, stderr_length, started_at, finished_at,
  duration_ms, status, reason, git_head, git_diff_sha256, host, pid } ] }`.
- claims: `.memory/claims/<name>.claim.json` —
  `{ task_id, agent, claimed_at, heartbeat_at, lease_seconds, attempt }`.
  TTL: `lease_seconds` (по умолчанию 900), stale = heartbeat старше TTL;
  неразбираемый heartbeat считается stale (как в PowerShell-скане).
- очереди: `projects/<project>/queue.json` —
  `{ "tasks": [ { id, title, priority, status, assigned_agent, project,
  worktree, created_at, started_at, completed_at, retries } ] }`.
- шина: `.memory/inbox/<agent>/<name>.json`, `.memory/outbox/*.json`,
  `.memory/dead-letter/*.json` —
  `{ id, from, to, type, priority, payload, status, startedAt, finishedAt,
  response, evidence, created_at }`. Поле `payload` встречается и строкой, и
  объектом — CLI поддерживает оба варианта.

## Устойчивость к повреждённому состоянию

- отсутствующий каталог → пустой результат, без ошибки;
- нечитаемый или битый JSON → строка в `warnings`, файл пропускается; CLI не
  падает;
- UTF-8 BOM в начале файла снимается (легаси-сообщения шины записаны с BOM,
  PowerShell `Get-Content` его не показывает);
- для небезопасных идентификаторов имя файла claim может быть хешем — CLI
  считает авторитетным поле `task_id` внутри файла.

## Структура модуля

```
go/
  go.mod                    module agent-hq (без внешних зависимостей)
  cmd/agent-hq/main.go      CLI: подкоманды, флаги, вывод (text/JSON)
  internal/state/
    root.go                 корень, пути, листинг JSON-файлов, снятие BOM
    time.go                 разбор/форматирование времени, возраст
    evidence.go             документы machine evidence
    claim.go                аренды и оценка TTL
    queue.go                очереди проектов
    message.go              сообщения шины (inbox/outbox/dead-letter)
    snapshot.go             единая сводка + лента активностей
    doctor.go               проверки окружения
    state_test.go           юнит-тесты парсеров
  README.md
  bin/                      собранные бинарники (в .gitignore)
```

## Ответственность пакетов

- `internal/state` — только разбор и агрегация. Никакого вывода в консоль.
- `cmd/agent-hq` — только CLI: разбор аргументов, форматирование, коды
  выхода.
