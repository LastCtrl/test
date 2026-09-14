# Agent HQ — стратегический план развития автономной ИИ-команды

**Статус:** canonical proposal; архитектурное решение Go Hybrid принято для roadmap
**Дата:** 2026-09-14  
**Связанный аудит:** `PROJECT_AUDIT_2026-09-14.md`  
**Назначение:** объединить исходную идею владельца, результаты технического аудита и предложения по развитию в единый реализуемый roadmap.
**Ближайший personal-first план:** `PERSONAL_AI_WORKBENCH_PLAN.md`

> Этот документ задаёт стратегический горизонт. Ближайшая реализация должна идти по сокращённому personal-first плану и расширяться только после подтверждённой пользы. Документ не заменяет `MASTER_PLAN.md` и `FULL_PLAN.md` до явного решения владельца; после согласования планы следует объединить, чтобы оставить один источник истины.
>
> **Название `Agent HQ` является рабочим.** Перед публичным выпуском нужен новый бренд и отдельная проверка названия, доменов и товарных знаков: GitHub уже использует обозначение Agent HQ для собственной платформы управления coding agents.

---

## 1. Видение продукта

**Agent HQ** — полностью автоматизированная система управления командой ИИ-агентов, способная одновременно вести несколько программных проектов, динамически распределять задачи, выбирать наиболее эффективные модели, независимо проверять результаты, восстанавливаться после сбоев и улучшать собственную маршрутизацию на основании объективных измерений.

### Ключевая формулировка

> Пользователь описывает результат, а Agent HQ самостоятельно формирует временную команду из общего пула агентов, выбирает модель для каждой подзадачи, выполняет работу в изолированной среде, проверяет качество, исправляет ошибки и возвращает подтверждённый результат вместе с прозрачным отчётом.

### Что значит «работает без проблем»

Абсолютное отсутствие внешних ошибок невозможно: модели, API, сеть, квоты и инструменты могут отказывать. Целевое свойство системы:

> Ни одна существенная ошибка не остаётся незамеченной, не записывается как успешный результат и не требует ручного вмешательства, пока не исчерпаны безопасные автоматические способы восстановления.

---

## 2. Оценка идеи

### Итоговая оценка концепции как инженерного/internal продукта: **8.7/10**

Это не оценка рыночной уникальности и не гарантия продаж. Как generic-идея продукт не уникален; ценность должна быть доказана надёжной эксплуатацией, удобным развёртыванием и внутренним кейсом с несколькими пользователями.

| Критерий | Оценка | Обоснование |
|---|---:|---|
| Практическая ценность | 9/10 | Уменьшает ручную координацию ИИ и позволяет вести несколько проектов |
| Актуальность | 9/10 | Routing, evaluation и agent orchestration — ключевые задачи прикладных ИИ-систем |
| Масштабируемость идеи | 9/10 | Общий пул и временные команды естественно масштабируются |
| Техническая реализуемость | 8/10 | Реализуемо, но требует строгой state machine и транзакционного состояния |
| Уникальность идеи | 3/10 | Оркестрация coding agents, routing, checkpoints и observability уже представлены отдельными продуктами |
| Уникальность целостной реализации | 6.5/10 | Ценность может дать единый локальный Go control plane: durable tasks, self-healing, доступы и заменяемые executors |
| Потенциал самооптимизации | 9/10 | История задач позволяет обучать routing без обучения самих моделей |
| Сложность эксплуатации | 6/10 | Много внешних компонентов, моделей, prompts и failure modes |
| Текущая зрелость реализации | 3.5/10 | Каркас богатый, но главный автоматический цикл пока не замкнут |

### Почему идея сильная

1. **Пул агентов лучше статичной команды.** Разные проекты получают только нужные роли.
2. **Model routing экономит ресурсы.** Сильная модель не тратится на механические задачи.
3. **Оценка по реальным результатам полезнее рекламных benchmark.** Система узнаёт, какая модель лучше именно для ваших задач.
4. **Разделение исполнения и проверки снижает ложные успехи.** Исполнитель не принимает собственную работу.
5. **Многопроектность повышает загрузку системы.** Пока один проект ожидает внешнее действие, агенты работают над другим.
6. **История позволяет улучшать решения.** Можно оптимизировать routing, prompts, размер команды и retry-политику.

### Главный риск идеи

Система может стать сложнее проектов, которыми она управляет. Поэтому автоматизация должна развиваться слоями: сначала надёжность одного workflow, затем многопроектность, затем рейтинг, и только потом самооптимизация.

---

## 3. Принципы системы

1. **30 агентов — общий пул, а не обязательная команда каждой задачи.**
2. **Минимальная достаточная команда.** Не запускать роль без измеримой пользы.
3. **Один агент — одна активная задача.** Исключение возможно только для read-only batch operations после нагрузочных тестов.
4. **Один project/task ID проходит через все компоненты.**
5. **Fail closed.** Неясный результат считается ошибкой, а не успехом.
6. **Исполнитель не оценивает сам себя.**
7. **Дешёвая модель по умолчанию, сильная — по необходимости.**
8. **Риск важнее сложности.** Короткая security-задача может требовать сильнейшей модели.
9. **Любой retry ограничен и объясним.**
10. **Любое изменение состояния атомарно и идемпотентно.**
11. **Markdown — представление для человека, а не база данных.**
12. **Наблюдаемость встроена в workflow, а не добавляется после сбоя.**
13. **Никакой тихой деградации.** Fallback всегда фиксируется.
14. **Автоматическое улучшение только через контролируемый эксперимент и возможность отката.**

---

## 4. Целевая архитектура

```text
┌──────────────────────────────────────────────────────────────┐
│                       User / Project API                     │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Intake + Task Classifier                                     │
│ project, type, complexity, risk, skills, acceptance criteria │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Workflow Planner                                             │
│ роли, зависимости, параллельные ветки, QA/security policy    │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Scheduler + Agent Pool                                       │
│ acquire, reserve, lease, heartbeat, release, fairness        │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Model Router                                                 │
│ качество + тип + риск + цена + latency + квота + доступность │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Isolated Worker                                              │
│ worktree, bounded tools, timeout, structured result          │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Verification Pipeline                                       │
│ tests → review → security → acceptance criteria              │
└────────────────────┬───────────────────────┬─────────────────┘
                     │ PASS                  │ FAIL
                     ▼                       ▼
             Complete + Release      Retry / Escalate /
                     │               Other agent / Rollback
                     └───────────────┬──────────────────────────
                                     ▼
┌──────────────────────────────────────────────────────────────┐
│ Evaluator + Learning                                         │
│ model score, agent score, prompt score, routing outcomes     │
└─────────────────────────────┬────────────────────────────────┘
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Result + Explainability Report                               │
└──────────────────────────────────────────────────────────────┘
```

### Компоненты

#### Control Plane — самостоятельный Go-сервис

Go является владельцем жизненного цикла задачи, а не тонкой оболочкой вокруг CLI:

- API/CLI и в дальнейшем dashboard/Telegram adapters;
- проекты, пользователи, роли и доступы;
- задачи, зависимости и durable state machine;
- registry агентов и executor capabilities;
- scheduler, leases, heartbeat и recovery;
- policies, budgets и model catalog;
- approvals, audit и состояние workflow;
- SQLite migrations, backup и integrity checks.

PowerShell после миграции остаётся только для Windows bootstrap/admin-задач. Он не должен владеть очередью, scheduler или authoritative state.

#### Data Plane — заменяемые Executor adapters

Первым production adapter остаётся OpenCode. Контракт не должен зависеть от его внутреннего формата настолько, чтобы нельзя было добавить Claude Code, Codex, OpenHands или direct-provider executor:

- запуск/отмена/resume OpenCode sessions;
- нормализация streaming events и exit/result;
- worktrees и filesystem boundaries;
- MCP/tools и выполнение allowlisted команд;
- тесты и machine-generated evidence;
- создание артефактов и checkpoint/handoff.

OpenCode — worker, а не источник истины. Падение или зависание его процесса не должно терять задачу. Собственный native agent runtime на Go не входит в ближайший roadmap; его допустимо начинать только после измеримого доказательства, что adapters ограничивают надёжность или продукт.

#### Evaluation Plane

- независимые проверки;
- metrics/events;
- model/agent/prompt ratings;
- benchmark jobs;
- рекомендации routing.

---

## 5. Общий пул из 30 агентов

### Модель использования

```text
Общий пул: 30 зарегистрированных агентов

Project A → backend, db-specialist, qa-engineer
Project B → frontend, dev-1, code-reviewer
Project C → legal-advisor
Project D → ожидает свободного security-auditor
Остальные → free
```

### Жизненный цикл агента

```text
FREE
  │ acquire(task_id, project_id, lease)
  ▼
RESERVED
  │ worker started
  ▼
BUSY
  ├── heartbeat ──────────────┐
  ├── success → VERIFYING     │
  ├── failure → RETRYING      │
  └── lease expired → STALE ──┘

VERIFYING
  ├── pass → FREE
  └── reject → RETRYING / FREE

ERROR
  └── recovery/health pass → FREE
```

### Обязательные поля назначения

```json
{
  "assignment_id": "as-uuid",
  "project_id": "project-a",
  "task_id": "tq-001",
  "attempt_id": "attempt-001",
  "agent_id": "backend",
  "model_id": "provider/model",
  "status": "busy",
  "lease_until": "2026-09-14T15:30:00Z",
  "heartbeat_at": "2026-09-14T15:20:00Z"
}
```

### Правила scheduler

1. Фильтр по `status=free`.
2. Обязательное совпадение нужной специализации.
3. Проверка tool/skill/platform capabilities.
4. Учёт project affinity без нарушения fairness.
5. Минимизация daily load и queue waiting time.
6. Учёт рейтинга агента для данного task type.
7. Атомарное резервирование.
8. Lease вместо вечного `busy`.
9. Автоматическое освобождение на всех terminal states.
10. Защита от двойного назначения unique constraint.

---

## 6. Классификация задач

### Размер

| Класс | Характеристика | Типичный workflow |
|---|---|---|
| XS | Документ/формат/1–2 строки | исполнитель → lightweight check |
| S | Одна простая функция или конфиг | исполнитель → QA |
| M | Несколько файлов, обычная feature | planner → 1–3 исполнителя → QA/review |
| L | Архитектура или сложная интеграция | planner + specialists → QA/review/security |
| XL | Несколько подсистем/проектов | hierarchy of workflows + checkpoints |

### Риск

| Риск | Пример | Минимальные требования |
|---|---|---|
| Low | README, форматирование | дешёвая модель, smoke check |
| Normal | feature без чувствительных данных | QA + review по политике |
| High | auth, миграция, concurrency | сильная модель + tests + security |
| Critical | production, финансы, удаление данных | strongest approved model + human approval |

### Независимые признаки

- task type;
- complexity;
- risk;
- novelty;
- reversibility;
- blast radius;
- required tools;
- required skills;
- external dependencies;
- acceptance-test availability.

---

## 7. Model Router

### Цель

Выбирать не «лучшую модель вообще», а лучшую доступную модель для конкретного сочетания:

```text
task_type + complexity + risk + agent_role + tools + language
```

### Факторы routing

| Фактор | Пример |
|---|---|
| Историческая корректность | QA pass rate для backend |
| Надёжность | доля timeout/provider errors |
| Цена | стоимость токенов/запроса |
| Latency | p50/p95 выполнения |
| Контекст | достаточен ли context window |
| Квота | остаток дневного/минутного лимита |
| Инструменты | поддержка tool calling/MCP |
| Язык | качество русского/BSL/кода |
| Риск | разрешена ли модель для Critical |
| Confidence | достаточно ли исторических примеров |

### Базовая политика

```text
XS/S + Low risk       → быстрая/слабая модель
M + Normal risk       → лучшая value-модель по task type
L/High risk           → сильная модель
Critical              → strongest approved + independent verifier
Provider degradation  → fallback с обязательной записью причины
```

### Fallback ladder

Fallback должен формироваться динамически, а не быть захардкоженной строкой:

```json
{
  "task_profile": "backend:L:high",
  "candidates": [
    {"model": "A", "score": 8.7, "available": false, "reason": "quota"},
    {"model": "B", "score": 8.2, "available": true},
    {"model": "C", "score": 7.5, "available": true}
  ],
  "selected": "B",
  "fallback_from": "A"
}
```

### Circuit breaker

Если модель/provider за короткое окно превышает лимит ошибок:

1. статус `degraded`;
2. новые задачи временно не назначаются;
3. выполняется probe;
4. после cooldown — half-open;
5. успешные probes возвращают provider в healthy.

---

## 8. Система оценки

### Что оценивается отдельно

1. **Model score** — способность модели решать данный тип задач.
2. **Agent score** — качество роли, инструкций и дисциплины агента.
3. **Model × Agent score** — эффективность конкретной комбинации.
4. **Prompt version score** — влияние версии prompt.
5. **Workflow score** — эффективность состава команды и проверок.

Нельзя смешивать всё в одно число: иначе непонятно, что улучшать.

### Событие оценки

```json
{
  "evaluation_id": "ev-uuid",
  "project_id": "project-a",
  "task_id": "tq-001",
  "attempt_id": "attempt-002",
  "task_type": "backend",
  "complexity": "L",
  "risk": "high",
  "agent_id": "backend",
  "agent_prompt_version": "sha256:...",
  "model_id": "provider/model",
  "correctness": 0.92,
  "requirements_coverage": 0.88,
  "qa_pass": true,
  "review_pass": true,
  "security_pass": true,
  "first_pass": false,
  "retries": 1,
  "duration_ms": 185000,
  "input_tokens": 7200,
  "output_tokens": 2100,
  "cost_usd": 0,
  "infra_error": false,
  "final_score": 8.1,
  "evaluator": "automated+review"
}
```

### Предлагаемая формула v1

| Метрика | Вес |
|---|---:|
| Корректность по тестам/критериям | 35% |
| Вердикты QA/review/security | 20% |
| Покрытие требований | 15% |
| First-pass/retry efficiency | 10% |
| Скорость относительно класса задачи | 8% |
| Token efficiency | 7% |
| Стоимость | 5% |

### Важные правила

- Infrastructure/provider error не снижает capability score модели, но снижает reliability score provider.
- Отсутствие тестов уменьшает confidence, а не автоматически даёт высокий балл.
- Пользовательская оценка хранится отдельно от автоматической.
- Сравниваются задачи одного типа и близкой сложности.
- Публикуются `sample_count`, среднее, медиана, dispersion и confidence.
- После изменения prompt создаётся новая версия статистики.
- Reviewer не должен знать имя модели при benchmark, если это возможно.

### Bayesian confidence / cold start

Новая модель не должна становиться лидером после одной удачной задачи. Начальная оценка притягивается к среднему до накопления достаточного числа результатов.

Минимальное отображение:

```text
Model A / backend: 8.3, n=42, confidence=high
Model B / backend: 9.1, n=2, confidence=very low
```

Для production routing временно предпочтительнее A.

---

## 9. Exploration и benchmark

### Почему это необходимо

Если всегда назначать текущего лидера, новые модели никогда не наберут статистику.

### Политика

- 85–90% обычных задач → лучший известный вариант;
- 10–15% Low/Normal задач → безопасное исследование альтернатив;
- High/Critical не используются для случайного эксперимента;
- exploration можно отключить на конкретном проекте;
- эксперимент не должен ухудшать пользовательский SLA.

### Shadow evaluation

Новая модель выполняет копию задачи без права изменять рабочую ветку. Её результат сравнивается с production result, но пользователю не мешает.

Преимущества:

- безопасная оценка новой модели;
- сравнение reasoning/patch/test plan;
- отсутствие риска для production;
- возможность строить benchmark из реальных задач.

### Golden task suite

Нужен небольшой стабильный набор:

- Python/backend;
- JavaScript/frontend;
- PowerShell;
- 1С/BSL;
- security review;
- debugging;
- документация;
- архитектура;
- тестирование.

Golden answers не обязаны быть одним текстом: основой должны быть executable tests и rubric.

---

## 10. Проверка результата

### Verification policy engine

Проверки выбираются по типу и риску:

```text
README change          → links/spelling/diff check
Backend feature        → unit + integration + code review
Authentication         → tests + review + security audit
DB migration           → migration test + rollback test + approval
PowerShell orchestration → Pester + Windows integration + concurrency
```

### Структурированный verdict

```json
{
  "verdict": "reject",
  "blocking": [
    {"code": "TEST_FAIL", "file": "...", "evidence": "..."}
  ],
  "non_blocking": [],
  "requirements_checked": ["AC-1", "AC-2"],
  "requirements_missing": ["AC-3"],
  "recommended_action": "retry_same_agent"
}
```

### Запрет самооценки

- исполнитель может приложить self-report;
- self-report не является приёмкой;
- существование названного файла само по себе не является доказательством корректности;
- финальный score рассчитывается после независимого verdict;
- для High/Critical verifier желательно использовать другую модель или deterministic tests.

### Machine-generated evidence

Runtime, а не модель, формирует доказательства и связывает их с конкретной попыткой:

```json
{
  "task_id": "tq-001",
  "attempt_id": "attempt-002",
  "tool_call_id": "tool-uuid",
  "artifact": "src/file.py",
  "sha256_before": "...",
  "sha256_after": "...",
  "git_diff_id": "...",
  "command": "pytest",
  "exit_code": 0,
  "stdout_hash": "...",
  "started_at": "...",
  "finished_at": "..."
}
```

Compliance parser проверяет структурированный формат и fail-closed при отсутствии записи. На следующем уровне self-report сопоставляется с runtime trace по `session_id/task_id/attempt_id/tool_call_id`; текст, написанный моделью, не доказывает вызов skill, MCP, теста или создание артефакта.

---

## 11. Retry, escalation и recovery

### Классификация ошибки

| Класс | Действие |
|---|---|
| Validation error | вернуть исполнителю точные замечания |
| Weak result | усилить prompt или модель |
| Tool error | повторить безопасную операцию |
| Provider error | fallback provider/model |
| Timeout | остановить worker, проверить partial changes |
| Permission denied | не обходить; исправить policy или запросить approval |
| Conflict | rollback/rebase/новый worktree |
| Repeated logic failure | другой агент + более сильная модель |
| Irreversible risk | human approval |

### Retry budget

Retry должен ограничиваться не только числом попыток, но и бюджетом:

```text
max attempts
max total time
max tokens
max cost
max model escalations
```

### Rollback

До запуска сохраняются:

- base commit;
- dirty state;
- worktree path;
- разрешённые файлы;
- expected outputs.

После failed attempt система должна доказать, что рабочее состояние либо принято, либо полностью откатилось.

---

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

**Цель:** зафиксировать реальное текущее поведение и версии источников.

- [ ] Зафиксировать версию OpenCode и актуальную JSON Schema.
- [ ] Для runtime-находок записывать `observed_at`, environment, команду и hash/ссылку на raw output.
- [ ] Для внешних планов/аудитов указывать source branch, commit SHA и file path.
- [ ] Добавить `.editorconfig` UTF-8 no BOM.
- [ ] Создать команду `doctor`.
- [ ] Создать fake OpenCode/provider/CNTLM для тестирования orchestration.
- [ ] Записать baseline happy/failure scenarios и rollback tests.

**Acceptance:** чистая Windows-машина воспроизводит smoke test по документации; утверждения о runtime и CI воспроизводимы.

## Phase 1 — Критические контракты до миграции

**Цель:** убрать ложную автоматизацию и определить стабильные контракты для Go.

### P0-A — Runtime configuration

- [ ] Мигрировать `opencode.json`: `agent`, а не `agents`; удалить неизвестные keys.
- [ ] Вынести metadata Agent HQ в отдельный `agent-hq.json`.
- [ ] Добавить schema validation и CI fail при неизвестном ключе.
- [ ] Доказать обнаружение всех 30 зарегистрированных агентов.
- [ ] Добавить корректный frontmatter всем skills; проверить unique names, directory/name и registry references.
- [ ] Доказать native skill discovery через автоматический test.

### P0-B — Исполнение

- [ ] Передавать настоящий process exit code.
- [ ] Ввести versioned structured worker result.
- [ ] Убрать Team Lead self-recursion.
- [ ] Ввести deny-by-default task allowlist: orchestrators могут делегировать только разрешённым ролям, leaf workers — нет.
- [ ] Отделить granular command policy от task permissions.
- [ ] Запускать worker только в assignment worktree и проверять filesystem boundary.
- [ ] Устранить False DONE на всех terminal paths.

### P0-C — Проверка

- [ ] Исправить compliance parser и отсутствие ожидаемой записи считать FAIL.
- [ ] Отдельно сопоставлять self-report с runtime trace; не доверять модельным полям.
- [ ] Ввести machine-generated evidence с hashes, exit code и correlation IDs.
- [ ] Исправить health verdict и проверить fake CLI fixtures.
- [ ] Добавить intentional rejection E2E: QA/reviewer реально блокирует неверный результат.

### P0-D — Безопасность и переносимость

- [ ] Исправить и автоматически устанавливать secret hook.
- [ ] Убрать абсолютные пользовательские пути.
- [ ] Ограничить external directories и доступ к чужим проектам.
- [ ] Redact payload/stdout/stderr и секреты.
- [ ] Закрепить внешние зависимости по версии/SHA.
- [ ] Добавить rollback tests для config/state migrations.

**Acceptance:** config и skills обнаруживаются автоматически; поддельный self-report не проходит gate; ошибки agent/permission/tool/timeout попадают в failed/dead-letter, а не done.

## Phase 2 — Go Control Plane и transactional state

**Цель:** ввести новый authoritative core по strangler-подходу, не переписывая agent runtime.

- [ ] Создать один Go binary с versioned config и migrations.
- [ ] Ввести SQLite schema: projects, users, tasks, attempts, assignments, events, approvals, artifacts.
- [ ] Реализовать transactional API/CLI, idempotency keys и append-only audit events.
- [ ] Мигрировать registry и project queues с dry-run и rollback.
- [ ] Реализовать JSON/Markdown export, backup и integrity recovery.
- [ ] Зафиксировать versioned интерфейс `Executor` независимо от OpenCode internals.
- [ ] Реализовать fake executor как reference conformance test.

**Acceptance:** Go/SQLite переживает restart без потери или двойного claim; миграция обратима и проверена.

## Phase 3 — Scheduler, OpenCode adapter и supervisor

**Цель:** превратить OpenCode из интерактивной сессии в управляемый worker.

- [ ] Реализовать OpenCode executor adapter: start, events, cancel, resume, terminal result.
- [ ] Реализовать atomic acquire, lease, heartbeat, release и reassignment.
- [ ] Разрешить параллельных workers без глобального bottleneck mutex.
- [ ] Связать project/task/attempt/session/tool IDs.
- [ ] Реализовать progress watchdog, checkpoint/handoff и bounded restart.
- [ ] Реализовать CNTLM/API probes, provider circuit breaker и model failover.
- [ ] Реализовать token preflight и snapshot-lock reconciliation.
- [ ] Добавить chaos scenarios: kill OpenCode, stop CNTLM, timeout provider, corrupt session.

**Acceptance:** два проекта работают параллельно; убийство OpenCode или остановка CNTLM не теряет задачу, recovery завершается без ручного «продолжай» либо выдаёт честный blocker после исчерпания budget.

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

### P0 — закрыть до переноса orchestration в Go

1. OpenCode schema migration и отделение `agent-hq.json`.
2. Миграция frontmatter/discovery всех skills.
3. Настоящий process exit code и structured worker result.
4. Self-recursion fix, task allowlist и worktree boundary.
5. Fail-closed compliance parser.
6. Runtime-generated evidence и trace correlation.
7. Secret hook, redaction, dependency pinning и portable paths.
8. Fake CLI/provider tests, intentional rejection E2E и migration rollback.

### P1 — Go foundation

9. Go binary и versioned configuration.
10. SQLite migrations и transactional state machine.
11. Executor interface + fake conformance suite.
12. OpenCode adapter.
13. Scheduler: acquire/lease/heartbeat/release.
14. Supervisor: watchdog/checkpoint/restart.
15. CNTLM/provider recovery и token preflight.
16. RBAC/audit foundations для внутреннего multi-user rollout.

### P2 — надёжная внутренняя эксплуатация

17. Verification policy и machine evidence gates.
18. 2–5 коллег, отдельные проекты/credentials/workspaces.
19. Quotas, approvals и emergency stop.
20. Telegram observe-only, затем безопасные control commands.
21. Soak/chaos tests и SLO dashboard.
22. Evaluation schema и provider/model separation.

### P3 — после подтверждённой пользы

23. Adaptive model router.
24. Benchmark/shadow mode.
25. Prompt versioning/A-B/canary.
26. Team optimizer и failure memory.
27. Дополнительные executor adapters.
28. Платный пилот только после измеримого внутреннего кейса.

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
- Не писать собственный native Go agent runtime, MCP/tool loop и provider protocols до измеримого доказательства ограничений adapter-подхода.
- Не строить generic SaaS до успешного внутреннего rollout и интервью с потенциальными B2B-пользователями.

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
- Go scheduler автоматически связывает queue, registry и worker;
- Go + SQLite владеют транзакционным состоянием;
- OpenCode подключён через versioned Executor adapter;
- worker возвращает настоящий exit code и structured result;
- QA может реально отклонить результат на основании machine-generated evidence;
- все terminal paths освобождают агента;
- watchdog восстанавливает хотя бы OpenCode process failure и CNTLM failure без ручного «продолжай»;
- есть Windows CI E2E и failure drills;
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

## 23. Operational Self-Healing — восстановление CNTLM, API, модели и сессии

### 23.1. Проблема из реальной эксплуатации

В текущей системе наблюдаются повторяющиеся классы сбоев:

| Сигнатура | Фактическое ручное действие | Требуемое автоматическое действие |
|---|---|---|
| `Cannot connect to API: Unable to connect` | остановить запрос, перезапустить CNTLM, повторить задачу | определить слой отказа, восстановить proxy, проверить API, безопасно перезапустить attempt |
| `Busy: FileSystem.writeFile (...snapshot...info/exclude)` | отменить/подождать/написать «продолжай» | распознать lock conflict, применить jitter/backoff, исключить конкурентный доступ, возобновить с checkpoint |
| `cache-only admission rejected a cold, unavailable, or overloaded request` | вручную `/compact` | proactive token budget, compact/checkpoint до лимита, новый session attempt при необходимости |
| `BackendAdmissionRejected ... incoming_uncached_tokens=256224 ... max=200000` | повторять `/compact` | не отправлять oversized cold request; создать компактный handoff и новую сессию |
| Агент/субагент остановился без terminal result | вручную написать «продолжай» | heartbeat + progress watchdog + probe + checkpoint + restart/resume |
| Требуется сменить модель | вручную отменить запрос и повторить | сохранить task checkpoint, завершить старый attempt, создать новый attempt на резервной модели |

Персональные заметки пользователя, не являющиеся системной ошибкой (например, напоминание о враче), не должны попадать в failure classifier.

### 23.2. Главный архитектурный принцип

**Supervisor работает вне OpenCode и вне ИИ-сессии.**

```text
Windows service / user-space supervisor
        │
        ├── CNTLM process + port + proxy probe
        ├── Internet/upstream probe
        ├── Provider/API health
        ├── OpenCode process/session health
        ├── Worker heartbeat/progress
        ├── Task lease/checkpoint
        └── Telegram notifications/control
```

Если recovery реализован только prompt-инструкцией агента, он не сработает именно тогда, когда агент, модель или OpenCode зависли.

### 23.3. Иерархия диагностики

Нельзя при любой сетевой ошибке сразу перезапускать CNTLM. Supervisor проверяет слои снизу вверх:

1. **Process:** существует ли ожидаемый PID CNTLM.
2. **Port:** слушается ли `127.0.0.1:3128`.
3. **Proxy handshake:** проходит ли тестовый HTTP CONNECT/HTTPS-запрос через CNTLM.
4. **Network/DNS:** доступен ли внешний контрольный endpoint.
5. **Provider:** отвечает ли конкретный API; код 401/403/429/5xx/timeout.
6. **Model:** доступна ли выбранная модель и принимает ли cold request.
7. **OpenCode:** жив ли процесс и обновляются ли session events.
8. **Agent attempt:** есть ли heartbeat/tool progress/terminal result.

Recovery выполняется на первом сломанном слое. Смена модели не исправляет упавший локальный proxy, а перезапуск CNTLM не исправляет oversized context.

### 23.4. CNTLM Supervisor

#### Health check

Проверки должны быть сильнее одного `netstat`:

- процесс запущен из разрешённого пути;
- PID соответствует процессу, которым управляет Agent HQ;
- порт 3128 слушается;
- реальный HTTPS probe через proxy завершается успешно;
- latency и серия ошибок записываются в telemetry.

#### Recovery sequence

```text
HEALTHY
  └── N последовательных ошибок
          ▼
      DEGRADED
          ├── probe success → HEALTHY
          └── probe failed → RESTARTING
                                ├── graceful stop owned PID
                                ├── timeout
                                ├── forced kill only owned cntlm PID
                                ├── start known executable + known config
                                ├── wait for port
                                ├── HTTPS proxy probe
                                └── success → HEALTHY / fail → OPEN CIRCUIT
```

#### Ограничения безопасности

- Не выполнять `taskkill /IM cntlm.exe /F` без проверки владельца/PID: команда может остановить чужой экземпляр.
- Хранить canonical executable/config paths в локальном gitignored config.
- Не логировать proxy credentials и содержимое `cntlm.ini`.
- Ограничить число рестартов, например 3 за 10 минут.
- После превышения лимита открыть circuit и уведомить пользователя вместо бесконечного restart loop.
- Предпочтительный production-вариант — Windows service с recovery policy, если это разрешено корпоративной средой и явно одобрено пользователем.
- Без прав администратора использовать отдельный user-space supervisor process.

### 23.5. Provider и API Failover

Provider health хранится отдельно от model capability:

```json
{
  "provider": "tokenrouter",
  "state": "degraded",
  "last_success_at": "...",
  "consecutive_failures": 3,
  "http_429_rate": 0.25,
  "http_5xx_rate": 0.10,
  "timeout_rate": 0.15,
  "circuit_open_until": "..."
}
```

#### Политика

- `401/403` → не retry; credential/config blocker.
- `429` → учитывать `Retry-After`, quota и переключать provider/model по policy.
- `5xx/timeout` → bounded retry с exponential backoff + jitter, затем fallback.
- локальный proxy down → сначала восстановить proxy, не штрафовать provider/model.
- все fallback фиксируются с reason code.
- резервный API должен быть заранее настроен и проверен командой `/doctor`; нельзя впервые настраивать его во время аварии.
- обход корпоративного proxy прямым соединением запрещён, если это нарушает сетевую policy.

### 23.6. Agent/Session Watchdog

#### Heartbeat недостаточен сам по себе

Долгий reasoning не всегда означает зависание. Watchdog учитывает:

- session event timestamp;
- tool activity;
- provider streaming/progress;
- CPU/process state, если доступно;
- task-class expected duration;
- отсутствие terminal structured result.

#### Состояния

```text
RUNNING
  ├── progress → RUNNING
  ├── soft timeout → PROBING
  ├── provider failure → FAILOVER
  └── hard timeout → CANCELLING

PROBING
  ├── response/progress → RUNNING
  └── no response → CANCELLING

CANCELLING
  ├── stop old request/process
  ├── reconcile worktree
  ├── save checkpoint
  └── RESTARTING
```

Автоматическое сообщение «продолжай» допускается только как один **soft probe**, если API поддерживает продолжение и session ещё здорова. Оно не является универсальным recovery: при сломанном proxy, lock или переполненном контексте такой prompt только создаёт дополнительную нагрузку.

### 23.7. Checkpoint и перезапуск сессии

Не следует пытаться переносить всю непрозрачную историю старой сессии. На границе attempt создаётся структурированный handoff:

```json
{
  "project_id": "...",
  "task_id": "...",
  "attempt_id": "old-attempt",
  "goal": "...",
  "acceptance_criteria": ["..."],
  "completed_steps": ["..."],
  "pending_steps": ["..."],
  "files_changed": ["..."],
  "base_commit": "...",
  "worktree": "...",
  "commands_run": [{"command":"...","exit_code":0}],
  "known_failures": ["..."],
  "last_verified_state": "...",
  "token_budget_summary": "..."
}
```

При смене модели:

1. остановить или признать потерянным старый request;
2. пометить старый attempt terminal state `failed/replaced`;
3. проверить и при необходимости откатить worktree к last verified state;
4. создать новый attempt ID;
5. выбрать резервную модель/provider;
6. передать компактный checkpoint;
7. продолжить в том же безопасном worktree либо создать новый attempt worktree;
8. не выполнять два attempt одной задачи одновременно без специального shadow-mode.

### 23.8. Context Budget и Admission Rejection

Ошибка с `incoming_uncached_tokens=256224` при лимите `200000` должна предотвращаться до API-вызова.

#### Политика token budget

- soft threshold, например 60–70% допустимого cold context;
- proactive summary/checkpoint;
- удаление устаревших tool outputs из нового handoff;
- сохранение ссылок на artifacts вместо вставки полного содержимого;
- оценка размера **до** запроса;
- hard reject oversized request на стороне Agent HQ;
- новая сессия с compact handoff вместо повторного `/compact` вслепую.

`/compact` остаётся инструментом, но не основной recovery-стратегией.

### 23.9. Snapshot/FileSystem lock

Для `Busy: FileSystem.writeFile (...snapshot...info/exclude)`:

1. классифицировать как локальный lock conflict, а не model failure;
2. не снижать рейтинг агента/модели;
3. применить bounded exponential backoff с jitter;
4. проверить, не работают ли две сессии с одним worktree/session storage;
5. сериализовать snapshot operation для одного worktree;
6. при превышении timeout отменить старую session operation;
7. создать новый attempt/checkpoint только после reconciliation;
8. не запускать бесконечные копии team-lead, использующие тот же конфликтующий ресурс.

### 23.10. Recovery decision table

| Failure class | Retry same session | Restart session | Restart CNTLM | Switch API/model | Human |
|---|---:|---:|---:|---:|---:|
| CNTLM process/port/probe failed | нет | после proxy recovery | да | нет, пока proxy общий | после restart budget |
| Provider 429 | после Retry-After | возможно | нет | да | при отсутствии резерва |
| Provider 5xx/timeout | bounded | возможно | только если proxy probe fail | да | после budget |
| Oversized/cold admission | нет | да, compact checkpoint | нет | только если другой backend имеет лимит | если нельзя сократить |
| Snapshot lock | после backoff | после reconciliation | нет | нет | при постоянном lock |
| Agent no-progress | один probe | да | только если network layer fail | возможно | после attempt budget |
| Permission denied | нет | нет | нет | нет | policy fix/approval |
| Invalid credentials | нет | нет | нет | резервный заранее настроенный provider | да |

### 23.11. SLO self-healing

- false recovery success: 0%;
- потерянные задачи при restart: 0;
- два активных production-attempt одной задачи: 0;
- CNTLM auto-recovery success: целевое ≥95% после накопления статистики;
- provider failover без потери task state: ≥99%;
- terminal attempt без checkpoint/result: 0;
- restart storm: 0;
- mean time to detect proxy failure: <30 секунд;
- mean time to recover обычный proxy failure: <2 минут;
- oversized request, отправленный provider: 0 после внедрения preflight.

### 23.12. Roadmap operational resilience

#### OR-P0 — классификация и наблюдаемость

- structured failure taxonomy;
- настоящий process exit code;
- proxy/API/session probes;
- correlation IDs;
- token preflight;
- реальные failure fixtures из этого раздела;
- fake provider/CNTLM/OpenCode test harness.

#### OR-P1 — безопасное восстановление

- CNTLM supervisor с restart budget;
- provider circuit breaker;
- session watchdog;
- checkpoint/handoff;
- restart attempt на той же модели;
- model/provider fallback;
- snapshot-lock backoff/reconciliation.

#### OR-P2 — production hardening

- Windows service recovery или user supervisor;
- chaos tests;
- soak tests;
- Telegram alerts;
- runbooks;
- dashboard SLO;
- human approval paths.

---

## 24. Telegram Bridge — мониторинг и безопасное управление

### 24.1. Назначение

Telegram-мост является адаптером к control plane, а не отдельным оркестратором. Он показывает состояние и отправляет ограниченные команды в тот же transactional API, которым пользуются CLI/dashboard.

```text
Telegram Bot
     │ authenticated command
     ▼
Agent HQ Control API
     │ transaction + audit
     ▼
Scheduler / Supervisor / Approval Queue
```

Telegram bot не должен напрямую запускать shell-команды или редактировать state-файлы.

### 24.2. Команды MVP

| Команда | Назначение |
|---|---|
| `/status` | здоровье CNTLM/API/OpenCode, активные проекты и задачи |
| `/projects` | проекты, очереди, прогресс, blockers |
| `/agents` | free/busy/stale/error и текущие назначения |
| `/providers` | provider/model health, circuit state, quota warnings |
| `/task <id>` | timeline, attempt, agent, model, last checkpoint |
| `/pause <project|task>` | безопасно остановить новые назначения |
| `/resume <project|task>` | продолжить scheduler |
| `/cancel <task>` | запросить отмену с подтверждением и rollback policy |
| `/retry <task>` | создать новый attempt по policy |
| `/approve <id>` | подтвердить ожидающее действие |
| `/reject <id>` | отклонить действие |
| `/logs <task> [N]` | последние redacted события, не полный сырой лог |
| `/doctor` | запустить безопасные read-only probes |
| `/help` | доступные команды текущей роли пользователя |

### 24.3. Уведомления

Bot отправляет события, а не поток каждого tool call:

- task started/completed/rejected;
- retry/model switch/provider failover;
- CNTLM degraded/restarted/circuit open;
- agent stale/recovered;
- запрос human approval;
- budget/quota threshold;
- Critical blocker;
- итог проекта/релиза.

Нужны grouping и cooldown, чтобы авария не создала сотни сообщений.

### 24.4. Безопасность Telegram

- allowlist Telegram user/chat IDs;
- роли `viewer/operator/approver/admin`;
- токен только из vault/environment, никогда в Git/логах;
- webhook secret либо безопасный long polling;
- anti-replay/idempotency key для команд;
- подтверждение destructive/high-risk действий;
- запрет произвольного shell через Telegram;
- redaction secrets/paths/payload;
- audit: кто, когда, из какого chat ID выполнил команду;
- возможность мгновенно отключить control commands, оставив read-only monitoring;
- rate limits;
- TTL для approval request;
- Critical действия желательно подтверждать вторым фактором/локально, если позволяет среда.

### 24.5. Переход от существующего FastAPI к Go API

Текущий `api/main.py` с `/health` можно временно сохранить как compatibility adapter или использовать для проверки API-контрактов, но он не должен становиться вторым authoritative control plane. Целевые endpoints реализуются в Go:

- `/health/live` — процесс жив;
- `/health/ready` — DB/scheduler готовы;
- `/health/dependencies` — redacted состояние CNTLM/providers/OpenCode;
- read API для projects/tasks/agents/events;
- command API с auth/RBAC/idempotency;
- Telegram adapter вызывает этот API;
- dashboard в будущем использует тот же API.

Во время миграции FastAPI не записывает состояние в обход Go API/SQLite. После переноса клиентов compatibility adapter удаляется. Mutation endpoints нельзя добавлять без аутентификации, RBAC, audit и idempotency.

### 24.6. Telegram rollout

1. **Observe-only:** `/status`, `/projects`, `/agents`, alerts.
2. **Safe operations:** pause/resume/retry через policy.
3. **Approvals:** approve/reject с TTL и аудитом.
4. **Advanced control:** cancel/rollback только после надёжного scheduler.
5. **Никогда:** произвольный удалённый shell.

### 24.7. DoD Telegram MVP

- неизвестный chat ID не получает данные;
- viewer не может выполнить mutation;
- повтор одного update не создаёт две команды;
- секреты не попадают в сообщения;
- Telegram outage не влияет на scheduler;
- команда проходит через transactional control API;
- каждое действие имеет audit event;
- bot показывает proxy/provider/session failures раздельно;
- `/retry` создаёт новый attempt, а не дублирует текущий;
- integration tests используют fake Telegram API.

---

## 25. Архитектурное решение: Go Hybrid, а не полный rewrite

### Решение

Целевая архитектура ближайших версий:

```text
Users / CLI / Telegram / future UI
                 │
                 ▼
       Go Control Plane + SQLite
 API · RBAC · scheduler · supervisor · audit
                 │
       versioned Executor interface
        ┌────────┼─────────┐
        ▼        ▼         ▼
    OpenCode   future     fake
    adapter    adapters   executor
```

### Почему

- проблема ручного `Stop → restart → продолжай` находится над OpenCode и решается durable supervisor;
- замена OpenCode целиком потребует заново реализовать provider streaming, tool loop, MCP, context/session management, permissions и sandbox;
- adapter сохраняет скорость разработки и позволяет заменить executor позже;
- Go получает только те обязанности, которыми система должна владеть независимо от выбранного coding agent.

### Граница продукта

Это не попытка создать ещё один coding agent. Продуктовый core — единый self-hosted слой над разными исполнителями:

- durable multi-project tasks;
- автоматическое восстановление process/session/proxy/provider failures;
- изоляция пользователей, проектов и credentials;
- доказуемая приёмка вместо self-report;
- routing моделей и executors по результатам;
- единый audit/control API.

Отдельные аналоги покрывают части этой схемы, поэтому сам список функций не является преимуществом. Преимущество считается доказанным только после воспроизводимого внутреннего rollout, где система требует меньше ручного вмешательства, чем прямое использование OpenCode/другого executor.

### Build vs buy

| Область | Решение сейчас |
|---|---|
| Durable task state, scheduler, recovery, RBAC | строить в Go: это core продукта |
| Coding agent/tool loop | использовать OpenCode через adapter |
| Provider transport/gateway | использовать готовый слой, если он удовлетворяет policy; не делать differentiator из retry API |
| Telemetry protocol | OpenTelemetry-compatible export вместо собственного закрытого формата |
| UI | сначала CLI/Telegram/API, dashboard после подтверждения workflow |
| Native Go executor | отложить до отдельного ADR с benchmark и подтверждёнными ограничениями |

### Exit criteria для начала native executor

Достаточно хотя бы одного подтверждённого условия:

1. OpenCode adapter систематически не может безопасно resume/cancel/reconcile задачи.
2. Невозможно обеспечить требуемую изоляцию или machine evidence.
3. Стоимость/latency adapter существенно хуже direct runtime и это доказано benchmark.
4. Ключевой customer requirement невозможно выполнить через доступные executors.

До этого полный rewrite считается неоправданным scope.

---

## 26. Внутренний multi-user rollout и проверка продукта

Первый реальный рынок — собственная команда. Развёртывание коллегам является не финальным enterprise-релизом, а контролируемым pilot.

### Обязательная изоляция

- отдельные user identities и роли `viewer/developer/operator/approver/admin`;
- allowlist проектов и репозиториев на пользователя/группу;
- отдельные worktrees/workspaces и запрет чтения соседних проектов;
- credentials хранятся сервером и никогда не выдаются агенту/пользователю без необходимости;
- provider/model allowlist и budget/quota на пользователя/проект;
- approvals для merge, destructive commands и изменения policies;
- immutable audit событий пользователя, агента и runtime;
- emergency pause/cancel без прямого shell-доступа;
- backup/restore и процедура удаления доступа сотрудника.

### Последовательность rollout

1. Владелец: один пользователь, один проект, failure drills.
2. Один доверенный коллега: read-only/Low-risk задачи.
3. 2–5 коллег: раздельные проекты, quotas и approvals.
4. Командный pilot: измерение экономии времени и числа ручных вмешательств.
5. Только после этого — решение о внешних платных пилотах.

### Product validation gates

Продукт готов к внутреннему pilot, когда:

- E2E `task → worktree → executor → tests → review → accept/reject` воспроизводим;
- kill OpenCode/CNTLM/provider failure восстанавливаются без ручного «продолжай»;
- пользователь не видит чужой проект, логи или credentials;
- false DONE, потерянные tasks и duplicate production attempts равны нулю в test suite;
- установка и обновление воспроизводимы на чистой Windows-машине.

Внешний платный pilot рассматривается, когда внутренние пользователи регулярно применяют систему и есть измеримый результат: сокращение ручных вмешательств, времени выполнения или стоимости accepted task. Само наличие большого пула агентов не является доказательством ценности.
