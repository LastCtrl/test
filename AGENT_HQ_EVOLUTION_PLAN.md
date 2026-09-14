# Agent HQ — стратегический план развития автономной ИИ-команды

**Статус:** предложение для согласования  
**Дата:** 2026-09-14  
**Связанный аудит:** `PROJECT_AUDIT_2026-09-14.md`  
**Назначение:** объединить исходную идею владельца, результаты технического аудита и предложения по развитию в единый реализуемый roadmap.

> Этот документ не заменяет `MASTER_PLAN.md` и `FULL_PLAN.md` до явного решения владельца. После согласования планы следует объединить, чтобы оставить один источник истины.

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

### Итоговая оценка концепции: **8.7/10**

| Критерий | Оценка | Обоснование |
|---|---:|---|
| Практическая ценность | 9/10 | Уменьшает ручную координацию ИИ и позволяет вести несколько проектов |
| Актуальность | 9/10 | Routing, evaluation и agent orchestration — ключевые задачи прикладных ИИ-систем |
| Масштабируемость идеи | 9/10 | Общий пул и временные команды естественно масштабируются |
| Техническая реализуемость | 8/10 | Реализуемо, но требует строгой state machine и транзакционного состояния |
| Уникальность комбинации | 8/10 | Отдельные элементы известны, но сочетание Windows/OpenCode/30 ролей/оценки полезно |
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

#### Control Plane

- проекты;
- задачи и зависимости;
- registry агентов;
- scheduler;
- policies;
- model catalog;
- approvals;
- состояние workflow.

#### Data Plane

- OpenCode sessions;
- worktrees;
- MCP tools;
- выполнение команд;
- тесты;
- создание артефактов.

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
- финальный score рассчитывается после независимого verdict;
- для High/Critical verifier желательно использовать другую модель или deterministic tests.

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
