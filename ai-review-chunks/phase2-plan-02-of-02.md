# PHASE2 PLAN PART 2/2

## 12. Хранилище состояния

### Рекомендация

Перейти с нескольких изменяемых JSON/Markdown файлов на SQLite.

### Минимальные таблицы

- `projects`;
- `tasks`;
- `task_dependencies`;
- `attempts`;
- `agents`;
- `assignments`;
- `models`;
- `provider_health`;
- `evaluations`;
- `events`;
- `approvals`;
- `prompt_versions`;
- `artifacts`.

### Почему SQLite

- транзакции;
- unique constraints;
- атомарный claim;
- индексы;
- concurrent readers;
- WAL;
- простой backup;
- нет отдельного сервера;
- подходит локальной Windows-системе.

### Markdown остаётся

- project summary;
- team report;
- user-readable timeline;
- audit report.

Но генерируется из структурированных событий.

---

## 13. Безопасность

### Permission tiers

| Tier | Права |
|---|---|
| Observer | только чтение разрешённых файлов |
| Reviewer | read + безопасные статические команды |
| Developer | edit только worktree + allowlisted build/test |
| Integrator | merge/rebase с дополнительными проверками |
| Operator | ограниченные control-plane операции |
| Human-approved | опасные/необратимые операции |

### Обязательные меры

- deny-by-default;
- worktree boundary;
- запрет credential/system-policy access;
- command allowlist;
- secret redaction;
- prompt-injection boundary для внешнего контента;
- audit trail всех инструментов;
- dependency pinning;
- checksums/signatures для устанавливаемых инструментов;
- запрет автоматического отключения security controls;
- human approval для destructive actions.

---

## 14. Наблюдаемость и SLO

### Correlation

Каждое событие содержит:

```text
project_id / workflow_id / task_id / attempt_id /
assignment_id / agent_id / model_id / tool_call_id
```

### Основные метрики

- task success rate;
- first-pass acceptance rate;
- retry rate;
- false-DONE rate;
- rollback success rate;
- queue wait p50/p95;
- execution p50/p95;
- model/provider error rate;
- agent utilization;
- duplicate assignment count;
- stale lease count;
- cost/tokens per accepted task;
- human intervention rate;
- escaped defect rate.

### Начальные SLO

| Метрика | Цель v0.1 |
|---|---:|
| False DONE | 0% |
| Duplicate assignment | 0 |
| Потерянные задачи | 0 |
| Terminal task без release | 0 |
| Correlated events | 100% |
| Rollback после failed attempt | ≥99% |
| Schema-valid results | 100% |
| E2E success на тестовом workflow | ≥95% |

---

## 15. Пользовательский интерфейс

### Команда `/status`

Должна показывать:

- проекты и workflow;
- очередь;
- активные назначения;
- free/busy/error agents;
- provider health и квоты;
- текущие retry/escalation;
- предупреждения;
- estimated completion без ложной точности.

### Команда `/explain`

Объясняет:

- почему выбраны эти агенты;
- почему выбрана эта модель;
- какие альтернативы отклонены;
- почему потребовался fallback;
- какие проверки обязательны.

### Команда `/doctor`

Проверяет:

- OpenCode config schema;
- agents и permissions;
- skills discovery;
- MCP availability;
- provider credentials без раскрытия значения;
- worktree health;
- SQLite integrity;
- PowerShell/version/path prerequisites;
- test task dry run.

### Команда `/budget`

Позволяет задавать:

```text
max cost / max tokens / deadline /
quality target / allowed models / exploration policy
```

---

## 16. Дополнительные сильные функции

### 16.1 Explainable Routing

Каждое назначение сопровождается reason codes:

```text
SELECTED_BEST_BACKEND_SCORE
FALLBACK_PRIMARY_QUOTA
REQUIRES_HIGH_RISK_MODEL
PROJECT_AFFINITY
LOWEST_DAILY_LOAD
```

Это делает систему проверяемой и помогает находить ошибки routing.

### 16.2 Capability Passport модели

Автоматически поддерживаемая карточка:

- поддерживаемые языки;
- tool-call reliability;
- context limit;
- типичные сильные/слабые задачи;
- latency;
- стоимость;
- provider limits;
- последние деградации;
- confidence по каждому capability.

### 16.3 Prompt A/B Testing

- prompt получает version/hash;
- часть безопасных задач идёт на candidate prompt;
- сравниваются acceptance, retry, tokens и время;
- promotion только при статистически устойчивом улучшении;
- автоматический rollback при деградации.

### 16.4 Team Composition Optimizer

Система оценивает не только отдельные модели, но и состав команды:

```text
backend + QA
backend + reviewer
backend + QA + reviewer
```

Цель — найти минимальный состав, который даёт нужное качество для конкретного риска.

### 16.5 Reviewer Disagreement Detector

Если QA и code-reviewer дают противоположные verdict:

1. сравнить evidence;
2. запустить deterministic tests;
3. привлечь tie-breaker модель;
4. не выбирать ответ простым большинством без доказательств.

### 16.6 Failure Memory

Перед retry система ищет похожие прошлые ошибки:

- signature ошибки;
- файл/технология;
- успешный fix;
- модель, которая справилась;
- запрещённые неудачные подходы.

Это полезнее общего длинного CONTEXT-BUFFER.

### 16.7 Task Replay

Возможность детерминированно воспроизвести:

- исходный prompt;
- версии файлов;
- модель и параметры;
- tools;
- результаты;
- verdict.

Необходима для отладки и честного сравнения моделей.

### 16.8 Canary Model Rollout

Новая модель сначала получает:

1. shadow tasks;
2. 5% Low-risk;
3. 15% Normal-risk;
4. production promotion;
5. автоматический rollback по error/quality threshold.

### 16.9 Confidence-aware Automation

Система учитывает собственную неопределённость:

- low confidence classification → planner/tie-breaker;
- low confidence code result → дополнительные тесты;
- low confidence rating → exploration, но не Critical routing.

### 16.10 Dynamic Verification Depth

Чем выше риск и novelty, тем глубже проверка. Это экономит время на простых задачах без снижения безопасности важных.

### 16.11 Semantic Task Deduplication

Если два проекта поставили одинаковую research/documentation задачу, система может переиспользовать проверенный результат, не смешивая приватный контекст проектов.

### 16.12 Cost/Quality Frontier

Показывать не одного победителя, а Pareto-набор:

```text
самая быстрая
самая дешёвая
самая качественная
лучший баланс
```

Пользователь или policy выбирает нужный режим.

### 16.13 Project Autopilot Levels

| Уровень | Поведение |
|---|---|
| 0 Observe | только рекомендации |
| 1 Assist | выполнение после подтверждения |
| 2 Auto-safe | автономные обратимые Low/Normal задачи |
| 3 Auto-project | автономный workflow с checkpoints |
| 4 Full autonomy | максимум автоматизации, human только Critical |

### 16.14 Chaos Testing для агентской системы

Искусственно проверять:

- timeout модели;
- quota exhausted;
- malformed output;
- зависший worker;
- потерю heartbeat;
- конфликт worktree;
- повреждение queue/state;
- исчезновение MCP;
- contradictory reviewers.

### 16.15 Policy Simulator

До изменения permissions/routing можно прогнать исторические события и увидеть:

- какие задачи изменили бы маршрут;
- где стало бы дороже;
- какие действия были бы запрещены;
- изменился бы acceptance rate.

---

## 17. Roadmap

## Phase 0 — Baseline и воспроизводимость

**Цель:** зафиксировать реальное текущее поведение.

- [ ] Зафиксировать версию OpenCode.
- [ ] Зафиксировать актуальную schema.
- [ ] Добавить `.editorconfig` UTF-8 no BOM.
- [ ] Создать команду `doctor`.
- [ ] Создать fake OpenCode CLI для тестирования orchestration.
- [ ] Записать baseline happy/failure scenarios.

**Acceptance:** чистая Windows-машина воспроизводит smoke test по документации.

## Phase 1 — Исправление критического runtime

**Цель:** убрать ложную автоматизацию.

- [ ] Исправить `agent` config и убрать неизвестные OpenCode keys.
- [ ] Исправить `sync-agents.ps1`.
- [ ] Настроить task allowlist orchestrator.
- [ ] Добавить frontmatter всем skills.
- [ ] Исправить poller native exit code.
- [ ] Сделать structured worker result.
- [ ] Заменить fail-open compliance.
- [ ] Исправить false DONE.

**Acceptance:** ошибки agent/permission/tool/timeout попадают в failed/dead-letter, а не done.

## Phase 2 — Единый scheduler

**Цель:** замкнуть существующие registry, queue и inbox.

- [ ] Ввести scheduler service/command.
- [ ] Связать task ID со всеми состояниями.
- [ ] Реализовать atomic acquire.
- [ ] Реализовать lease/heartbeat.
- [ ] Связать terminal state с release.
- [ ] Связать stale/dead с release/reassignment.
- [ ] Автоматически писать assignment audit.
- [ ] Разрешить параллельных workers без глобального bottleneck mutex.

**Acceptance:** два проекта одновременно получают разные допустимые команды без duplicate assignment.

## Phase 3 — Транзакционное состояние

**Цель:** убрать гонки и drift.

- [ ] Ввести SQLite schema.
- [ ] Мигрировать registry.
- [ ] Мигрировать project queues.
- [ ] Ввести event log.
- [ ] Добавить idempotency keys.
- [ ] Сделать JSON/Markdown export.
- [ ] Добавить backup/integrity recovery.

**Acceptance:** concurrency tests с 20 workers не теряют задачи и назначения.

## Phase 4 — Verification и безопасность

**Цель:** подтверждать качество и ограничивать blast radius.

- [ ] Policy engine по task type/risk.
- [ ] Structured verdict.
- [ ] Granular permissions.
- [ ] Worktree boundary tests.
- [ ] Rollback proof.
- [ ] Security/dependency scans.
- [ ] Human approval gates.

**Acceptance:** High-risk workflow нельзя завершить без обязательных проверок.

## Phase 5 — Evaluation v1

**Цель:** получать честные показатели.

- [ ] Новая evaluation schema.
- [ ] Разделить model/agent/prompt/provider metrics.
- [ ] Ввести task type/complexity/risk.
- [ ] Вычислять confidence/sample count.
- [ ] Исключать infra errors из capability score.
- [ ] Создать dashboard leaderboard по категориям.
- [ ] Версионировать prompts.

**Acceptance:** для каждого accepted task объяснимо рассчитывается score и confidence.

## Phase 6 — Adaptive Model Router

**Цель:** автоматически выбирать оптимальную модель.

- [ ] Capability matrix.
- [ ] Provider health/quota tracking.
- [ ] Dynamic fallback ladder.
- [ ] Circuit breaker.
- [ ] Cost/quality policies.
- [ ] Controlled exploration.
- [ ] Shadow evaluation.

**Acceptance:** router выбирает разные модели для разных классов задач и объясняет решение.

## Phase 7 — Многопроектная эксплуатация

**Цель:** подтвердить исходную идею пула 30 агентов.

- [ ] 2 проекта / 5 активных агентов.
- [ ] 5 проектов / динамические команды.
- [ ] Fair scheduling.
- [ ] Project quotas/priorities.
- [ ] No context leakage tests.
- [ ] Utilization/queue SLO.
- [ ] Recovery drills.

**Acceptance:** пять проектов выполняют workflow одновременно без двойных назначений и утечки контекста.

## Phase 8 — Self-optimization

**Цель:** улучшать систему безопасно.

- [ ] Prompt A/B tests.
- [ ] Team composition optimizer.
- [ ] Routing policy replay.
- [ ] Canary models.
- [ ] Failure memory.
- [ ] Автоматические рекомендации, но не бесконтрольное self-modification.

**Acceptance:** любое автоизменение проходит experiment, verification и имеет rollback.

---

## 18. Приоритетный backlog

### P0 — делать сейчас

1. OpenCode schema/config.
2. Orchestrator task permissions.
3. Skill discovery/frontmatter.
4. Poller exit/result correctness.
5. Structured compliance.
6. Сквозной project/task/attempt ID.
7. E2E happy path и intentional failure.

### P1 — сразу после P0

8. Scheduler integration.
9. Atomic acquire/release.
10. Stale/dead release.
11. Parallel worker design.
12. SQLite state.
13. Permission hardening.
14. Structured telemetry.

### P2 — после надёжности

15. Evaluation schema.
16. Model router.
17. Provider health/quota.
18. Benchmark/shadow mode.
19. Dashboard/explainability.
20. Prompt versioning.

### P3 — продвинутые функции

21. Team optimizer.
22. A/B prompts.
23. Canary models.
24. Failure memory.
25. Chaos testing.
26. Policy simulation.

---

## 19. Что не следует делать пока

- Не добавлять новых агентов только ради количества.
- Не удалять существующий пул 30 агентов без данных об использовании.
- Не строить сложное ML-обучение router до накопления чистой статистики.
- Не разрешать системе напрямую переписывать собственные production policies.
- Не считать скорость единственным показателем качества.
- Не принимать self-report за независимую проверку.
- Не увеличивать retry без общего бюджета.
- Не выдавать отсутствие распознанных данных за PASS.
- Не гарантировать `$0`, если provider policy не контролируется системой.
- Не проводить model experiment на Critical задачах.

---

## 20. Критерии успеха продукта

Система считается достигшей основной идеи, когда пользователь может одновременно дать несколько задач разным проектам, после чего Agent HQ без ручного распределения:

1. классифицирует каждую задачу;
2. создаёт план и acceptance criteria;
3. формирует минимальную команду из пула 30 агентов;
4. атомарно резервирует агентов;
5. выбирает модели по измеримым данным и policy;
6. выполняет независимые ветки параллельно;
7. обнаруживает provider/tool/agent failures;
8. не создаёт false DONE;
9. безопасно выполняет retry/escalation/rollback;
10. проверяет результат;
11. освобождает всех агентов;
12. обновляет раздельные рейтинги;
13. объясняет принятые решения;
14. сохраняет воспроизводимый audit trail;
15. возвращает пользователю только подтверждённый результат либо честный blocker.

---

## 21. Предлагаемый первый milestone

### `v0.1 — Reliable Autonomous Loop`

**Состав:**

- общий registry из 30 агентов сохраняется;
- используются 3–5 агентов в тестовом workflow;
- один orchestrator имеет ограниченное право делегации;
- scheduler автоматически связывает queue, registry и worker;
- состояние транзакционно;
- worker возвращает настоящий exit code и structured result;
- QA может реально отклонить результат;
- все terminal paths освобождают агента;
- есть Windows CI E2E;
- false DONE = 0.

### Демонстрационный сценарий

```text
Пользователь: «Добавь endpoint и тесты в Project A,
а в Project B обнови документацию».

Agent HQ:
1. создаёт две независимые workflow;
2. назначает backend + QA проекту A;
3. назначает tech-writer проекту B;
4. выбирает разные модели по сложности;
5. выполняет задачи параллельно;
6. отклоняет намеренно ошибочный первый backend result;
7. выполняет retry;
8. принимает исправленный результат;
9. освобождает трёх агентов;
10. обновляет ratings;
11. показывает explain report.
```

Если этот сценарий воспроизводимо проходит, фундамент исходной идеи доказан.

---

## 22. Решение после согласования

После утверждения документа рекомендуется:

1. объединить актуальные части `MASTER_PLAN.md`, `FULL_PLAN.md` и этого документа;
2. оставить один canonical plan;
3. старые планы переместить в документированный archive только отдельным согласованным изменением;
4. создать задачи GitHub по Phase 0–2;
5. начинать реализацию с P0, не смешивая её с advanced features.


---
PHASE2 END. Выполни критическое сравнение и выдай итоговый объединённый план.
