# agent-hq Go CLI (этапы G1-G3)

Go-фаза control plane из `AUDIT-CONSOLIDATED-2026-09-14.md`: G1 — read-only
инспекция состояния, G2 — SQLite-индекс, G3-M1 — версионируемый Executor и
durable write-path (claim/attempt/event в SQLite), G3-M2 — устойчивость к
падениям (heartbeat, watchdog/recovery, checkpoint), G3-M3 — сетевое
самовосстановление (проба CNTLM/провайдера, `net-check`, retry через прокси,
fallback-модель, метка session-invalid). Движок на PowerShell остаётся
основным: Go-путь сосуществует с ним и не изменяет PS-скрипты.

## Parity PS↔Go (эталон — PowerShell)

Правила поведения задаёт PowerShell; Go обязан им соответствовать, а не
наоборот.

- **Эталон (источник истины):** `.agents/scripts/inbox-engine.ps1`
  (классификация результата, формат evidence/шины) и
  `.agents/scripts/project-worktree.ps1` (валидация имени проекта, layout
  worktree/branch).
- **Зеркало (Go):** `internal/bus/classify.go` (успех/провал попытки,
  benign-предупреждения, `LimitText`/`Truncate`/`FormatAttemptReport`) и
  `internal/worktree/name.go` (`ValidateName` = `Test-ProjectName`, `Branch`).
  Меняя правило, правь ОБА места: иначе один и тот же вход два драйвера
  классифицируют по-разному.
- **Защита:** `cmd/agent-hq/runloop_parity_test.go` прогоняет один вход через Go
  `run-loop` и настоящий `inbox-poller.ps1` и сверяет артефакты (папка, имя,
  поля сообщения, статус, evidence). Красный parity-тест = зеркало разошлось с
  эталоном: исправляй Go (или синхронно оба), а не «подгоняй» тест.

## Границы этапов

Реализовано:

- G1: чтение состояния (evidence, claims, очереди проектов, шина);
- G2: SQLite-индекс `.memory/agent-hq.db` (схема v1) с freshness-фолбэком;
- G3-M1: версионируемый `Executor`, команда `run`, durable write-path
  (`run_claims`, `runs`, `run_attempts`, `run_events`, схема v2);
- G3-M2: heartbeat-петля во время `run`, `agent-hq recover` (watchdog: stale
  running-attempts → `stale`/`queued`, освобождение аренды, идемпотентно),
  `agent-hq checkpoint` (durable handoff), схема v3;
- G3-M3: пакет `internal/net` (проба прокси по TCP, чтение
  `.memory/model-health.json`, классификация `OK/PROXY_DOWN/PROVIDER_RATE_LIMIT/
  PROVIDER_DEAD/SESSION_INVALID/TIMEOUT/UNKNOWN`), команда `agent-hq net-check`,
  self-heal в `run` (retry через прокси → fallback-модель из паспорта, события
  `provider.retry`/`model.fallback`/`session.invalid`), метки session-invalid в
  SQLite (схема v4), net-секция в `doctor`/`recover`.

Сознательно НЕ сделано (следующие этапы):

- автоматический restart/резюм самого воркера из checkpoint (M2 хранит
  состояние для продолжения, но не перезапускает OpenCode-сессию);
- daemon, worker pool, scheduler, RBAC;
- запись файлового состояния — по-прежнему на PowerShell-скриптах; PS-движок
  остаётся основным, Go-путь его не заменяет и не изменяет.

## Требования

- Go 1.27+ (проверено на `go1.27.1 windows/amd64`).
- Единственная внешняя зависимость: `modernc.org/sqlite` (чистый Go-драйвер,
  G2/G3). Сеть в рантайме нужна только probe-командам (`net-check`, `doctor`,
  `recover -net`) и self-heal-циклу `run`.

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
| `doctor` | здоровье каталогов и конфигов + net-секция (`net-proxy`, `model-health`, warn-only), версия CLI | — |
| `net-check` | проба CNTLM/прокси, отчёт о `.memory/model-health.json` и рекомендации; `-model` показывает fallback | `-proxy <host:port>`, `-timeout <сек>`, `-model <имя>` |
| `run <agent> <text>` | claim в SQLite, запуск через Executor, heartbeat аренды, durable-запись результата, self-heal провайдера | `-executor opencode\|fake`, `-id <id>`, `-model <имя>`, `-lease <секунд>` |
| `recover` | watchdog: stale running-attempts → `stale` (или `queued`), освобождение аренды, события; учёт session-invalid; `-net` добавляет пробу прокси; идемпотентно | `-requeue`/`-Requeue`, `-ttl <секунды>`, `-net` |
| `checkpoint save\|list\|latest <run-id>` | durable handoff-точки задачи | `-state <текст>`, `-path <артефакт>` |
| `shadow` | read-only план: что Go-планировщик сделал бы с текущими inbox/queue (без claim и без запуска) | `-once` (одиночный проход, по умолчанию), `-summary` |
| `version` | версия CLI | — |

Все команды поддерживают `-json`.

Коды выхода: `0` — успех; `1` — проблемы (не найден evidence-документ,
нездоровый `doctor`, неуспешный/пропущенный `run`, нет чекпоинтов у
`checkpoint latest`); `2` — ошибка использования CLI. `recover` без stale-записей
завершается `0`.

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

Watchdog/heartbeat-петля и checkpoint — этап M2 (ниже).

## G3-M2: устойчивость к падениям (heartbeat, watchdog, checkpoint)

Цель M2 — задача не теряется и не «залипает», если воркер упал, завис или был
убит. Все механизмы работают только с собственной БД root (`agent-hq.db`) и не
пишут в файлы, которыми владеет PowerShell.

### Heartbeat

Пока `Executor.Execute` выполняется, горутина-тикер обновляет `run_claims.heartbeat_at`
(owner-guarded `UPDATE`). Интервал = треть аренды (`lease_seconds/3`), минимум
1 с; при `-lease 300` это каждые 100 с. Аренда по умолчанию — 900 с. Ошибки
heartbeat пишутся событием `heartbeat.error` (не глотаются). Тикер
останавливается через `defer` до освобождения аренды, поэтому после завершения
run ничего не «дозванивается».

### Watchdog / recovery

```
agent-hq recover [-requeue] [-ttl <секунды>] [-json] [-root <path>]
```

`recover` находит `run_attempts` со статусом `running`, у которых heartbeat
старше аренды (LEFT JOIN к `run_claims` по `task_id`; нет claim — берётся
`started_at` и аренда по умолчанию). Возраст считается в Go по тем же правилам,
что и файловый sweep (`state.EvaluateClaims`): неразбираемый heartbeat = stale.
Для каждого такого attempt в одной транзакции:

1. `run_attempts.status = 'stale'`, `finished_at`, `error = <reason>`;
2. аренда удаляется, только если её всё ещё держит тот же owner (`DELETE ... WHERE owner = ?`);
3. `runs.status = 'stale'` (или `'queued'` при `-requeue`, payload сохраняется);
4. события `attempt.stale` и `run.stale` (или `recover.requeued`).

Операция идемпотентна: апдейт защищён `WHERE status = 'running'`, повторный
прогон возвращает `recovered: 0` и не добавляет событий. `-ttl N` заменяет
аренду для всех записей (окно watchdog без правки claim). `-requeue` —
**только БД**: run помечается `queued`, payload остаётся; файлы inbox/queue не
трогаются (их ведёт PowerShell), повторный запуск — за будущим scheduler.

### Checkpoint

```
agent-hq checkpoint save <run-id> [-state <текст>] [-path <артефакт>] [-json]
agent-hq checkpoint list <run-id> [-json]
agent-hq checkpoint latest <run-id> [-json]
```

Формат `run_checkpoints` зафиксирован (append-only):

| Поле | Тип | Смысл |
|------|-----|-------|
| `run_id` | TEXT | id задачи/run (natural key) |
| `seq` | INTEGER | 1-based, монотонно на `run_id`, назначает store |
| `path` | TEXT | артефакт последнего шага (может быть пустым) |
| `state` | TEXT | свободный текст handoff-состояния (store его не разбирает) |
| `created_at` | TEXT | UTC RFC3339Nano (назначается, если пусто) |

Повторный `save` с тем же `path`+`state`, что у последнего чекпоинта, не
добавляет дубликат (возвращает `seq` существующего). Другой state всегда
добавляется.

### Хранилище

Схема SQLite поднята до версии 3 (append-only миграции v1→v2→v3): v2 добавила
`run_claims`, `runs`, `run_attempts`, `run_events`; v3 — `run_checkpoints`.
Все v3-операторы — `CREATE ... IF NOT EXISTS`, поэтому прерванную миграцию
можно безопасно повторить (ALTER TABLE сознательно не используется: heartbeat
attempt выводится из аренды задачи). Таблицы авторитетны и не входят в
full-resync `agent-hq index`, поэтому переиндексация файлов историю запусков
не затирает. Индекс G2 (`projects/tasks/evidence/claims/messages`) не изменён.

## G3-M3: сетевое/провайдерское/сессионное самовосстановление

Цель M3 — Go control plane сам определяет сетевой или провайдерский сбой и
пытается его починить, не теряя задачу и не выдумывая успех. Все действия
durable: каждое — отдельная attempt-запись плюс append-only событие.

### `internal/net`

- `Classify(exitCode, stdout, stderr, timedOut)` → `OK | PROXY_DOWN |
  PROVIDER_RATE_LIMIT | PROVIDER_DEAD | SESSION_INVALID | TIMEOUT | UNKNOWN`.
  Сигнатуры повторяют `Get-ProbeStatus` из `model-router.ps1` (rate limit,
  `no available channel`, credit) и добавляют proxy/session-случаи. Ничего не
  распознавшее считается `UNKNOWN` и **не** запускает self-heal (обычный провал
  задачи не превращается в retry-шторм).
- `Prober.ProbeProxy(ctx, addr)` — bounded TCP-connect (по умолчанию
  `127.0.0.1:3128`, бюджет 2 с); dialer инъектируется, поэтому тесты работают
  без сокетов. `TIMEOUT` при исчерпании бюджета, `PROXY_DOWN` при отказе.
- `ReadModelHealthFile` читает `.memory/model-health.json` (BOM-устойчиво,
  breaker `open_until` оценивается в Go) — те же данные, что у PS-роутера.
- `ReadPassportModels` читает `.agents/config/capability-passport.json`
  (read-only) и сортирует модели по cost tier; `SelectFallback` пропускает
  текущую модель и модели с открытым breaker'ом.
- `Recommend` печатает рекомендации как `model-router.ps1 -Status`.

### `agent-hq net-check`

```
agent-hq net-check [-proxy <host:port>] [-timeout <секунды>] [-model <имя>] [-json]
```

Read-only: TCP-проба прокси + чтение health/паспорта. Exit 0 — прокси поднят,
exit 1 — прокси недоступен (данные health на это не влияют). `-model` добавляет
решение о fallback.

### Self-heal в `run`

После попытки результат классифицируется. При provider-классе (rate limit /
dead / timeout / proxy):

1. проба прокси; если он отвечает — одна повторная попытка **через прокси**
   (`HTTPS_PROXY`/`HTTP_PROXY` задаются только на эту attempt, событие
   `provider.retry`);
2. если провайдер всё ещё мёртв — **fallback-модель** из паспорта (или
   встроенной лестницы), пропуская открытые breaker'ы (событие
   `model.fallback`);
3. `SESSION_INVALID` не ретраится: задача получает durable-метку
   `session_marks.status='invalid'` и событие `session.invalid`.

Heartbeat аренды охватывает весь цикл (не только первую попытку), поэтому retry
не оставляет висящий claim. В `runs`/`run_attempts` попадают все попытки, а
fault пишется в `error` attempt'а (`PROVIDER_DEAD: ...`). Флаг `-model` (или
модель из конфига) — это «текущая» модель для выбора fallback.

### Хранилище M3

Схема поднята до версии 4 (append-only v1→v2→v3→v4): добавлена
`session_marks(task_id PK, agent, status, reason, marked_at, cleared_at)`.
Все операторы — `CREATE ... IF NOT EXISTS`, прерванную миграцию можно
повторять. Таблица авторитетна и не входит в G2 full-resync.

### Net-секция в doctor/recover

`doctor` добавляет `net-proxy` и `model-health` — оба **warn-only**, поэтому
offline-машина остаётся здоровой. `recover` всегда печатает счётчик
session-invalid и метки, а с `-net` — ещё и пробу прокси с рекомендациями.
Сеть нужна только `net-check`/`doctor`/`recover -net` и self-heal; остальные
команды работают офлайн.

## M5 shadow (read-only)

Цель M5-«тень» — доказать, что Go-путь умеет планировать ту же работу, что и
PowerShell, ничего не ломая: Go читает те же `inbox`/`projects/*/queue.json` и
только **логирует**, что он сделал бы.

```
agent-hq shadow [-once] [-summary] [-json] [-root <path>]
```

- Строго read-only: не claim'ит аренду, не запускает opencode, не пишет в
  `inbox`/`outbox`/`dead-letter`. Единственный создаваемый путь —
  `.memory/shadow/<UTC-таймстамп>.json`.
- План по каждому элементу: `source` (inbox/queue), `task_id`, `agent`,
  `model`, `executor` (`opencode`), `route` (`direct`/`folder`/
  `assigned`/`unassigned`), `action` (`would-run`/`would-skip`).
- Модель агента берётся из `opencode.json` (блок `agent`), с фолбэком на
  `.opencode/agents/*.json`.
- `processed_by_ps: true` — элемент уже обработан PowerShell (сообщение есть в
  `outbox`/`dead-letter`; задача `done`/`dead` или с успешным evidence).
- `-summary` печатает только сводку; `-json` — полный отчёт. Одиночный проход,
  без фонового демона.

## M5 cut-over: `run-loop` (Go ведёт задачи) + `driver`

Go-драйвер умеет вести ту же шину, что `inbox-engine.ps1`, и включается
переключателем. **По умолчанию выключен** (`ps`): пока нет файла режима, всё
работает как раньше, а `run-loop` в демон-режиме просто ничего не делает.
Режим — рантайм-состояние машины (`<root>/.memory/driver.mode`, в git не
хранится): на этой машине он включён (`go`) и зарегистрирована задача
`agent-hq-go-loop`.

```
agent-hq run-loop [-root <path>] [-once] [-max N] [-interval <sec>]
                  [-executor opencode|fake] [-queue=false] [-json]
agent-hq driver [-root <path>] [-set go|ps] [-clear] [-json]
```

Что делает `run-loop` (как PowerShell-движок, но на Go):

- сканирует `.memory/inbox/<agent>/*.json` и очереди `projects/*/queue.json`
  (`-queue=false` отключает очереди), элементы обрабатываются в порядке
  приоритета/FIFO;
- claim **атомарно в SQLite** (`run_claims`, `INSERT ... ON CONFLICT ... WHERE
  heartbeat истёк`) и параллельно зеркалит аренду в файл
  `.memory/claims/<id>.claim.json` (CREATE_NEW) — так Go и PS никогда не
  выполнят одно сообщение дважды в момент переключения;
- heartbeat обеих аренд раз в 30 с во время длинного запуска (плюс heartbeat
  liveness-файла драйвера);
- исполняет через `OpenCodeExecutor` (opencode, при наличии ключей в vault — через
  `run-with-secrets.ps1`); `-executor fake` — детерминированный воркер для тестов;
- классифицирует результат как PowerShell: `exit 0` + непустой stdout + нет
  error-marker (+ `STATUS:` для структурных задач; для `source=run|reply`/
  `from=telegram` маркер необязателен). Benign-предупреждение
  `agent "X" not found. Falling back...` вырезается и ошибкой НЕ считается;
- до 2 попыток; успех → `.memory/outbox/<id>.json` + архивация inbox в
  `.memory/archive/<agent>-<файл>`; провал → `.memory/dead-letter/<id>.json`
  (payload/response редактируются `Redact`, как `redact.ps1`);
- битый JSON → файл переносится в `dead-letter` без изменения (как PS); пустой
  payload → `dead-letter` с `Empty payload — no task to process`;
- пишет машинное evidence в тот же формат (`stdout_sha256`, длины, статус,
  `git_head`, `git_diff_sha256`, host, pid);
- очередь: `queued|assigned` → `in_progress` → `done` (или `dead` с
  `dead_reason`/`dead_at`); задача с успешным evidence не запускается повторно, а
  сверяется в `done`. Неизвестные поля очереди сохраняются (документ правится как
  JSON-объект, не как структура); перед записью создаётся `.bak`;
- stale-восстановление: running-попытки без heartbeat → `stale`
  (`store.RecoverAttempt`), истёкшие файловые аренды отзываются (TTL 900 с, как
  `Revoke-StaleClaimSweep`);
- `-max N` ограничивает работу одного прохода, `-once` — ровно один проход,
  `-interval` — пауза между проходами демона; логи идут в stderr и в
  `.memory/traces/run-loop.log`.

Переключатель (`driver`):

- файл `<root>/.memory/driver.mode` со строкой `go` или `ps`; переменная
  `AGENT_HQ_DRIVER` перекрывает файл; дефолт (файла нет) — `ps`;
- `driver -set go` включает Go-драйвер, `driver -clear` возвращает дефолт и
  заодно удаляет liveness-файл (откат одной командой, без остаточного
  heartbeat);
- пока Go-цикл работает, он держит liveness-файл `.memory/driver.lock`
  (`{mode,pid,started_at,heartbeat_at,cycles}`) и обновляет heartbeat;
- в режиме `-once` (расписание — см. ниже) liveness-файл **не** удаляется после
  прохода: каждый проход оставляет свежий heartbeat, поэтому PS-поллер стоит
  между двумя запусками расписания. Heartbeat протухает сам (180 с), если
  расписание перестало срабатывать. Демон, наоборот, удаляет файл при чистом
  завершении, сразу возвращая шину PowerShell;
- **fallback**: PowerShell-поллер (`Test-GoDriverActive` в `inbox-engine.ps1`)
  пропускает цикл только когда `driver.mode = go` И heartbeat свежий (< 180 с).
  Go-цикл упал/не стартовал → heartbeat протух → PS продолжает работать как
  раньше;
- schtasks переключается только наличием задачи `agent-hq-go-loop` (см. ниже),
  сам режим переключается файлом.

Проверка переключения:

```
agent-hq driver                 # mode, источник, свежесть heartbeat
agent-hq run-loop -once         # один проход независимо от режима (тест/ручная)
agent-hq run-loop               # демон: только при driver.mode=go
```

### Активация прод (Go ведёт, PS страхует)

Прод-режим — не демон, а задача планировщика каждые 2 минуты (процесс живёт
секунды и не остаётся в фоне):

```
schtasks -> agent-hq-go-loop: wscript.exe //B run-go-loop-hidden.vbs
Пн-Пт 08:00, повтор каждые 2 мин, длительность 9 ч, окно скрыто
(внутри VBS: cwd = корень репо, `go\bin\agent-hq.exe run-loop -once`)
```

Порядок включения и полный откат — `.agents/docs/go-driver-cutover.md`.
Коротко:

```
go\bin\agent-hq.exe driver -set go            # включить Go-драйвер
.agents\scripts\register-go-loop-task.ps1     # зарегистрировать расписание

go\bin\agent-hq.exe driver -clear             # ОТКАТ (PS снова ведёт)
schtasks /Delete /TN agent-hq-go-loop /F      # убрать расписание
```

Задача `agent-hq-inbox-poller` (PS) не удаляется: пока `driver.mode = go` и
heartbeat свежий, PS пропускает цикл, а при протухшем heartbeat автоматически
берёт работу на себя.

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
  cmd/agent-hq/run.go       команда run: claim, heartbeat, durable-запись, self-heal, Executor
  cmd/agent-hq/recover.go   команда recover: watchdog stale-attempts + session-учёт
  cmd/agent-hq/checkpoint.go команда checkpoint: durable handoff
  cmd/agent-hq/shadow.go    команда shadow: read-only план inbox/queue (M5)
  cmd/agent-hq/netcheck.go  net-check + net-секция doctor: проба прокси, health, рекомендации
  cmd/agent-hq/runloop.go   run-loop (Go ведёт шину) + driver (переключатель режима)
  internal/bus/
    bus.go, claim.go, ...   PS-совместимая шина: envelope/archive/dead-letter/evidence/redact/lease
  internal/driver/
    driver.go               режим (driver.mode/AGENT_HQ_DRIVER) и liveness (driver.lock)
  internal/loop/
    loop.go                 ядро run-loop: claim, попытки, outbox/dead-letter, окно очереди
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
    store.go                открытие/миграции SQLite (schema v3)
    schema.go               схема индекса (v1), write-path (v2), recovery (v3)
    index.go                full-resync индекса из файлов
    query.go                чтение индекса
    fingerprint.go          fingerprint состояния для freshness
    run.go                  durable claim/run/attempt/event
    recover.go              stale-attempts и атомарный recover
    checkpoint.go           run_checkpoints: save/list/latest
    session.go              session_marks: invalid/cleared метки M3
    *_test.go               тесты индекса, write-path, recovery, checkpoint, сессий
  internal/net/
    net.go                  статусы и классификатор провайдерских/сессионных сбоев
    probe.go                bounded TCP-проба прокси с инъектируемым dialer
    health.go               чтение .memory/model-health.json, рекомендации
    fallback.go             кандидаты из паспорта/лестницы и выбор fallback
    *_test.go               тесты классификации, проб, health и fallback
  internal/executor/
    executor.go             интерфейс Executor, TaskSpec, Result, Classify
    opencode.go             OpenCodeExecutor через vault-враппер
    fake.go                 FakeExecutor для тестов
    executor_test.go        тесты классификации и планирования запуска
  internal/shadow/
    plan.go                 read-only планировщик inbox/queue + отчёт M5
    plan_test.go            тесты плана, processed_by_ps, битых входов, read-only
  README.md
  bin/                      собранные бинарники (в .gitignore)
```

## Ответственность пакетов

- `internal/state` — только разбор и агрегация. Никакого вывода в консоль.
- `internal/store` — SQLite: индекс G2 и durable write-path G3-M1.
- `internal/executor` — версионируемый запуск работы; не знает про БД.
- `cmd/agent-hq` — CLI: разбор аргументов, оркестрация claim/run/release,
  форматирование, коды выхода.
