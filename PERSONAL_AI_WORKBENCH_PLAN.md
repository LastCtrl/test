# Personal AI Workbench — практический план развития

**Статус:** основной план ближайшей реализации для личного использования
**Дата:** 2026-09-14
**Стратегический горизонт:** `AGENT_HQ_EVOLUTION_PLAN.md`

## 1. Цель ближайшей версии

Не строить сразу универсальную платформу. Сначала убрать реальные ручные действия владельца при ежедневной работе с AI:

```text
сформулировал задачу
→ система запустила OpenCode в отдельном worktree
→ сохранила состояние
→ обнаружила зависание/сбой
→ восстановила CNTLM/API/session
→ продолжила с checkpoint
→ запустила проверки
→ вернула подтверждённый результат или честный blocker
```

Главная метрика — не число агентов и функций, а снижение ручных вмешательств и времени до принятого результата.

## 2. Архитектурное решение

### Сейчас

```text
CLI
 │
 ▼
Один Go binary
├── Control service
├── SQLite state
├── Scheduler: максимум 2–3 активные задачи
├── Supervisor
├── OpenCode Executor adapter
├── Git Worktree manager
├── Verification runner
└── Event log / status
```

### В будущем

```text
CLI / Telegram / Web / IDE
             │
             ▼
      Go Control Plane
 API · RBAC · Scheduler · Policy · Audit
             │
      Executor interface
   ┌─────────┼──────────┬────────────┐
   ▼         ▼          ▼            ▼
OpenCode  Claude Code  Codex   Native executor?
             │
      Model/provider layer
             │
 Evaluation · routing · budgets · telemetry
```

OpenCode является первым исполнителем, но не источником истины. Задача, attempt, checkpoint и итоговый verdict принадлежат Go + SQLite.

Полный native runtime на Go не входит в ближайшие версии. Возможность его добавить сохраняется через стабильный интерфейс `Executor`.

## 3. Что сознательно не делаем сейчас

- не активируем все 30 ролей одновременно;
- не строим сложный multi-agent planner;
- не делаем model leaderboard и Bayesian routing;
- не реализуем shadow runs, A/B prompts и team optimizer;
- не создаём Web UI;
- не добавляем полноценный multi-user RBAC;
- не пишем собственные MCP/tool loop/provider protocols;
- не упаковываем SaaS и не оптимизируем под продажи;
- не переносим в Go код, который не нужен ближайшему E2E.

30 агентов остаются registry специализаций. В обычной задаче используется один исполнитель, при необходимости — один независимый reviewer.

## 4. Future-proof контракты

Минимальная версия остаётся расширяемой, если с начала соблюдать следующие границы.

### 4.1. Executor

```go
type Executor interface {
    Capabilities(ctx context.Context) (Capabilities, error)
    Start(ctx context.Context, req StartRequest) (RunHandle, error)
    Events(ctx context.Context, runID string, after Cursor) (<-chan Event, error)
    Cancel(ctx context.Context, runID string) error
    Resume(ctx context.Context, req ResumeRequest) (RunHandle, error)
    Inspect(ctx context.Context, runID string) (RunState, error)
}
```

OpenCode-specific session IDs, event payloads и команды не выходят за пределы adapter package.

### 4.2. Store

Бизнес-логика зависит от интерфейса repository/store, а не от SQL-запросов внутри handlers. SQLite остаётся authoritative store, migrations версионируются и имеют backup/rollback procedure.

### 4.3. Verification

Executor сообщает, что он сделал. Отдельный verifier формирует machine-generated evidence и verdict. Self-report модели не переводит задачу в `DONE`.

### 4.4. Events

Все существенные изменения создают versioned event:

```text
project_id / task_id / attempt_id / run_id /
executor_id / event_type / occurred_at / schema_version
```

В будущем эти события смогут использовать Telegram, Web UI, OpenTelemetry и evaluation без чтения внутренних таблиц.

### 4.5. Configuration

- пользовательская локальная конфигурация отделена от `opencode.json`;
- secrets не хранятся в Git и не попадают в события;
- provider, executor и project paths задаются конфигурацией;
- абсолютные пути не зашиваются в код;
- все внешние процессы запускаются через единый process runner.

## 5. Минимальная state machine

```text
QUEUED
  → STARTING
  → RUNNING
      ├── progress → RUNNING
      ├── no progress → PROBING
      ├── recoverable failure → RECOVERING
      ├── result → VERIFYING
      └── cancel → CANCELLING

PROBING
  ├── progress → RUNNING
  └── timeout → RECOVERING

RECOVERING
  ├── resume/restart succeeded → RUNNING
  └── retry budget exhausted → BLOCKED

VERIFYING
  ├── pass → DONE
  └── reject → QUEUED retry / BLOCKED
```

Каждый переход транзакционный и идемпотентный. После restart Go-сервиса ни одна незавершённая задача не должна бесследно исчезать или автоматически становиться `DONE`.

## 6. Минимальные данные SQLite

### Обязательно

- `projects`;
- `tasks`;
- `attempts`;
- `executor_runs`;
- `checkpoints`;
- `events`;
- `artifacts`;
- `verification_results`;
- `dependency_health`.

### Отложено

- users/groups/RBAC;
- model ratings;
- prompt experiments;
- billing;
- organization/tenant hierarchy;
- advanced workflow DAG.

Схема должна позволять добавить эти сущности migrations без изменения идентичности существующих tasks/attempts/events.

## 7. Milestone 0 — исправить фундамент текущей конфигурации

Перед Go orchestration закрыть только ошибки, мешающие надёжному adapter:

- [ ] `opencode.json` проходит актуальную schema;
- [ ] используется `agent`, неизвестные metadata вынесены в `agent-hq.json`;
- [ ] OpenCode обнаруживает зарегистрированных агентов;
- [ ] skills имеют корректный frontmatter и проходят discovery test;
- [ ] получаем настоящий process exit code;
- [ ] есть fake OpenCode CLI для автоматических тестов;
- [ ] текущие runtime-находки зафиксированы с command/environment/time.

**DoD:** один smoke task стабильно запускается из автоматического harness, а malformed config ломает CI.

## 8. Milestone 1 — Go runner, который не теряет процесс

Реализовать:

- [ ] Go CLI `workbench run <project> <task>`;
- [ ] единый process runner для OpenCode;
- [ ] stdout/stderr/event capture с redaction;
- [ ] cancel с graceful timeout и kill только принадлежащего процесса;
- [ ] timeout и настоящий exit status;
- [ ] минимальный OpenCode adapter;
- [ ] команды `status`, `logs`, `cancel`;
- [ ] correlation `task_id/attempt_id/run_id`.

**DoD:** принудительное убийство OpenCode определяется автоматически; задача не становится `DONE`, процесс не остаётся orphan.

## 9. Milestone 2 — durable task и автоматический recovery

Реализовать:

- [ ] SQLite migrations;
- [ ] persistent queue;
- [ ] state machine;
- [ ] checkpoint/handoff перед новым attempt;
- [ ] progress watchdog, soft probe и hard timeout;
- [ ] bounded retry budget;
- [ ] restart той же session, если это безопасно;
- [ ] новая session из compact checkpoint, если resume невозможно;
- [ ] startup reconciliation после restart Go process.

**DoD:** во время задачи убить OpenCode и перезапустить Go-сервис. После запуска система находит незавершённую задачу, восстанавливает её и завершает либо выдаёт объяснимый `BLOCKED` без ручного «продолжай».

## 10. Milestone 3 — CNTLM/provider/session self-healing

Реализовать:

- [ ] независимые process/port/proxy/provider probes;
- [ ] безопасный CNTLM restart только для owned PID;
- [ ] restart budget и circuit breaker;
- [ ] provider errors: auth, quota, timeout, 5xx;
- [ ] заранее проверенный fallback provider/model;
- [ ] token/context preflight;
- [ ] snapshot-lock backoff и reconciliation;
- [ ] failure classification без снижения model score за infra failure.

**DoD:** тесты с остановкой CNTLM, timeout provider и snapshot lock восстанавливаются автоматически либо заканчиваются честным blocker после исчерпания policy.

## 11. Milestone 4 — worktrees и доказуемая приёмка

Реализовать:

- [ ] отдельный worktree на production attempt;
- [ ] filesystem boundary;
- [ ] base commit и dirty-state preflight;
- [ ] allowlisted build/test commands;
- [ ] machine-generated hashes, diff identity, exit code и output hash;
- [ ] verification policy по типу проекта;
- [ ] reviewer только при риске или отсутствии достаточных deterministic checks;
- [ ] rollback/reconciliation failed attempt;
- [ ] False DONE gate.

**DoD:** намеренно ложное сообщение `tests passed/DONE` не принимается; только реальный успешный verification переводит task в `DONE`.

## 12. Milestone 5 — полезный личный daily driver

Добавить только удобство, подтверждённое собственной эксплуатацией:

- [ ] одновременно максимум 2–3 задачи;
- [ ] приоритеты и pause/resume;
- [ ] короткий `status` по проектам;
- [ ] desktop/Telegram notifications только на важные события;
- [ ] простой выбор executor/model;
- [ ] отчёт: результат, diff, tests, retries, blocker;
- [ ] installer/update/backup для своей Windows-машины.

### Dogfood-период

Использовать систему на реальных задачах и записывать:

- ручные вмешательства на задачу;
- число потерянных/повторённых задач;
- recovery success rate;
- false DONE;
- accepted tasks с первой попытки;
- время до accepted result;
- стоимость/token usage;
- время, потраченное на разработку самого workbench.

**DoD:** инструмент устойчиво экономит время по сравнению с прямым ручным использованием OpenCode. Если экономия не доказана, новые platform-функции замораживаются, а UX/reliability упрощаются.

## 13. Milestone 6 — один коллега, затем малая команда

Начинать только после успешного личного dogfood.

### Один коллега

- [ ] отдельная identity;
- [ ] allowlist доступных проектов;
- [ ] отдельные workspaces;
- [ ] скрытые credentials;
- [ ] read-only/Low-risk режим по умолчанию;
- [ ] audit действий;
- [ ] quota и emergency stop.

### 2–5 коллег

- [ ] роли `viewer/developer/operator/approver/admin`;
- [ ] project-level permissions;
- [ ] per-user/project budgets;
- [ ] approvals для merge и destructive operations;
- [ ] backup/restore;
- [ ] revoke access;
- [ ] no-context-leakage tests.

**DoD:** пользователь не может увидеть чужие проекты, логи, worktrees или secrets; сбой одной задачи не останавливает остальные.

## 14. Путь к потенциальной архитектуре «10/10»

«10/10» — не отдельный rewrite, а последовательное расширение проверенного core.

### Уровень A — надёжный личный инструмент

- один пользователь;
- OpenCode adapter;
- 2–3 задачи;
- durable recovery;
- worktrees;
- verification.

### Уровень B — командный control plane

- RBAC;
- несколько executors;
- quotas/approvals;
- Telegram/Web;
- centralized deployment;
- audit и SLO.

### Уровень C — интеллектуальная платформа

- разделённые model/provider/agent/prompt metrics;
- adaptive routing;
- confidence и cold start;
- shadow evaluation;
- canary models/prompts;
- failure memory;
- dynamic verification depth.

### Уровень D — enterprise/product hardening

- SSO и organization boundaries;
- policy packs;
- signed updates;
- HA/external database только при доказанной необходимости;
- OpenTelemetry integrations;
- installation profiles;
- supportability и upgrade guarantees.

### Уровень E — optional native executor

Начинать только если adapters доказанно ограничивают:

- cancel/resume/recovery;
- sandbox/permissions;
- machine evidence;
- latency/cost;
- обязательный customer use case.

Native executor добавляется за существующим интерфейсом и не требует переписывать scheduler, state, API, RBAC или evaluation.

## 15. Правила против переусложнения

1. Новая функция появляется только из наблюдаемой проблемы или измеримой экономии.
2. Один исполнитель по умолчанию; reviewer/команда добавляются по риску.
3. Не строить универсальность до второго реального executor.
4. Не оптимизировать routing без достаточной истории задач.
5. Не создавать UI поверх нестабильной state machine.
6. Не добавлять distributed infrastructure для одной машины.
7. Не смешивать личный MVP и требования гипотетического enterprise-клиента.
8. Каждая фаза обязана улучшать ежедневный workflow или создавать необходимую архитектурную границу.
9. Приоритет reliability выше количества функций.
10. Возможность будущего расширения обеспечивается контрактами и migrations, а не реализацией всех функций заранее.

## 16. Приоритеты

### NOW

1. OpenCode config/skills discovery.
2. Fake OpenCode и process runner.
3. Go CLI + OpenCode adapter.
4. SQLite task/attempt/event state.
5. Watchdog + checkpoint + restart.
6. CNTLM/provider recovery.
7. Worktree + verification + False DONE gate.

### NEXT — только после личного dogfood

8. Удобный status/notifications.
9. 2–3 параллельные задачи.
10. Один коллега с ограниченными доступами.
11. Minimal RBAC/audit/quotas.
12. Второй executor adapter.

### LATER — только при накопленных данных

13. Model evaluation/router.
14. Telegram control и Web UI.
15. Advanced multi-agent workflows.
16. Team/prompt optimization.
17. Внешний платный pilot.

### NOT NOW

18. Полный native Go agent runtime.
19. Generic SaaS.
20. Kubernetes/microservices/distributed database.
21. Все 30 агентов в каждом workflow.

## 17. Итоговый критерий успеха

Первая версия успешна, если владелец может дать обычную задачу и уйти, а система без присмотра:

1. запускает её в правильном проекте и worktree;
2. не теряет состояние при падении OpenCode/Go/CNTLM/API;
3. сама выполняет допустимое восстановление;
4. не принимает выдуманный результат;
5. возвращает проверенный diff либо честный blocker;
6. требует заметно меньше ручных действий, чем прямая работа в OpenCode.

Только после доказательства этого сценария начинается расширение в командный и потенциально коммерческий продукт.
