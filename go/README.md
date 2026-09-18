# agent-hq Go CLI (этапы G1-G3)

Go-фаза control plane из `AUDIT-CONSOLIDATED-2026-09-14.md`: G1 — read-only
инспекция состояния, G2 — SQLite-индекс, G3-M1 — версионируемый Executor и
durable write-path (claim/attempt/event в SQLite). Движок на PowerShell
остаётся основным: Go-путь сосуществует с ним и не изменяет PS-скрипты.

## Границы этапов

Реализовано:

- G1: чтение состояния (evidence, claims, очереди проектов, шина);
- G2: SQLite-индекс `.memory/agent-hq.db` (схема v1) с freshness-фолбэком;
- G3-M1: версионируемый `Executor`, команда `run`, durable write-path
  (`run_claims`, `runs`, `run_attempts`, `run_events`, схема v2).

Сознательно НЕ сделано (следующие этапы):

- watchdog, heartbeat-петля, checkpoint/handoff и restart (M2);
- daemon, worker pool, scheduler, RBAC;
- stale-sweep durable-аренд (в M1 аренда освобождается в `defer`);
- запись файлового состояния — по-прежнему на PowerShell-скриптах; PS-движок
  остаётся основным, Go-путь его не заменяет и не изменяет.

## Требования

- Go 1.27+ (проверено на `go1.27.1 windows/amd64`).
- Единственная внешняя зависимость: `modernc.org/sqlite` (чистый Go-драйвер,
  G2/G3). Сеть в рантайме не нужна.

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
| `run <agent> <text>` | claim в SQLite, запуск через Executor, durable-запись результата | `-executor opencode\|fake`, `-id <id>`, `-model <имя>`, `-lease <секунд>` |
| `version` | версия CLI | — |

Все команды поддерживают `-json`.

Коды выхода: `0` — успех; `1` — проблемы (не найден evidence-документ,
нездоровый `doctor`, неуспешный/пропущенный `run`); `2` — ошибка
использования CLI.

## G3-M1: Executor и write-path

Цель M1 — научить Go control plane запускать работу через версионируемый
интерфейс и надёжно фиксировать результат, не ломая PowerShell-движок.

### Интерфейс `internal/executor`

- `Executor` — `Version() int`, `Name() string`, `Execute(ctx, TaskSpec) (Result, error)`.
  `InterfaceVersion = 1` фиксирует контракт.
- `TaskSpec` — `ID`, `Agent`, `Payload`, `Model` (опционально, только
  фиксируется, в CLI не форвардится), `AttemptID`.
- `Result` — `Status` (`success|failed|timeout|error`), `ExitCode`, `Stdout`,
  `Stderr`, `Duration`, `Error`.
- `Classify(exitCode, stdout, stderr)` — единое правило успеха, зеркало
  `inbox-engine.ps1`: exit 0 + непустой stdout + маркер `STATUS: resolved|done|completed`
  + отсутствие error-маркера (`Error:`, `permission denied`, `not found`,
  `auto-rejecting`, `rejected permission`).
- `OpenCodeExecutor` — запускает `opencode run --agent <agent> <prompt>`:
  - CLI резолвится как в PS: `AGENT_HQ_OPENCODE` (raw, обходит vault),
    `AGENT_HQ_OPENCODE_PATH`, npm-shim, затем PATH;
  - при наличии vault и ключей провайдера запуск идёт через
    `run-with-secrets.ps1` (секреты только в env дочернего процесса, значения
    не печатаются и не логируются);
  - env-хуки `AGENT_HQ_TASK_ID`, `AGENT_HQ_ATTEMPT_ID`, `AGENT_HQ_AGENT`,
    `AGENT_HQ_MODEL`;
  - таймаут `AGENT_HQ_JOB_TIMEOUT` (по умолчанию 900 с), выход по таймауту —
    `timeout`/exit 124, как в PS.
- `FakeExecutor` — режимы `success|fail|timeout|empty` для тестов;
  `AGENT_HQ_FAKE_MODE`, `AGENT_HQ_FAKE_DELAY_MS`, `AGENT_HQ_FAKE_TIMEOUT_MS`.

### Команда `run`

```
agent-hq run <agent> "текст" [-executor opencode|fake] [-id <id>] [-json]
```

Порядок durable-операций (crash-safe «до/после»):

1. атомарный claim в SQLite (`run_claims`): один `INSERT ... ON CONFLICT DO
   UPDATE ... WHERE <lease истёк>`, победитель один; проигравший выходит со
   статусом `skipped`/`already-claimed`;
2. запись `runs` и `run_attempts` со статусом `running` ДО запуска;
3. `Executor.Execute`;
4. запись результата ПОСЛЕ: статус, exit code, duration, длины и SHA256
   stdout/stderr (сырой вывод в БД не пишется);
5. release аренды в `defer` (owner-guarded).

События `run_events` (append-only): `claim.acquired`, `claim.conflict`,
`attempt.started`, `attempt.finished`, `run.finished`, `claim.released` —
задел для M2 (watchdog/recovery). Повторный `run` с тем же
`-id` не теряет прошлые попытки: `run_attempts` только дополняется.

Watchdog/heartbeat-петля и checkpoint — вне M1.

### Хранилище

Схема SQLite поднята до версии 2 (append-only миграция v1→v2): добавлены
`run_claims`, `runs`, `run_attempts`, `run_events`. Они авторитетны и не
входят в full-resync `agent-hq index`, поэтому переиндексация файлов историю
запусков не затирает. Индекс G2 (`projects/tasks/evidence/claims/messages`)
не изменён.

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
  go.mod                    module agent-hq (SQLite через modernc.org/sqlite)
  cmd/agent-hq/main.go      CLI: подкоманды, флаги, вывод (text/JSON)
  cmd/agent-hq/run.go       команда run: claim, durable-запись, Executor
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
  internal/store/
    store.go                открытие/миграции SQLite (schema v2)
    schema.go               схема индекса (v1) и write-path (v2)
    index.go                full-resync индекса из файлов
    query.go                чтение индекса
    fingerprint.go          fingerprint состояния для freshness
    run.go                  durable claim/run/attempt/event
    *_test.go               тесты индекса и write-path
  internal/executor/
    executor.go             интерфейс Executor, TaskSpec, Result, Classify
    opencode.go             OpenCodeExecutor через vault-враппер
    fake.go                 FakeExecutor для тестов
    executor_test.go        тесты классификации и планирования запуска
  README.md
  bin/                      собранные бинарники (в .gitignore)
```

## Ответственность пакетов

- `internal/state` — только разбор и агрегация. Никакого вывода в консоль.
- `internal/store` — SQLite: индекс G2 и durable write-path G3-M1.
- `internal/executor` — версионируемый запуск работы; не знает про БД.
- `cmd/agent-hq` — CLI: разбор аргументов, оркестрация claim/run/release,
  форматирование, коды выхода.
