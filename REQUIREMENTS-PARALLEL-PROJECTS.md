# REQUIREMENTS.md — Масштабирование до 5 параллельных проектов

> **Версия**: 2.0.0
> **Дата**: 2026-09-07
> **Автор**: Product Manager (Team Lead)
> **Статус**: DRAFT

---

## Обзор проекта

agent-hqCurrently supports 2 concurrent projects (news-bot, pong-advanced) with a single shared context buffer. The goal is to scale to **5 simultaneous projects** without agent conflicts, context leaks, or idle agents. This requires a multi-tenant architecture where each project gets isolated context, memory, and agent allocation — while agents remain a shared pool with dynamic routing.

---

## Текущее состояние (AS-IS)

| Компонент | Состояние | Проблема |
|-----------|-----------|----------|
| Агенты | 19 агентов (10 base + 9 copies) в `opencode.json` | Copies существуют для параллельной работы, но нет mechanism для автоматического выделения |
| Контекст | Один общий `CONTEXT-BUFFER.md` | Все проекты пишут в одну шину — конфликты, путаница |
| Memory Bank | `.memory/` общий для всех | Контекст проекта A доступен агенту проекта B |
| Projects | `opencode.json` → секция `projects` (2 проекта) | Нет изоляции, нет очереди, нет балансировки |
| Workspace | `sandbox_per_agent: true`, `merge_strategy: git-branch` | Worktree-песочницы есть, но нет project-level изоляции |

---

## User Stories

### US-011: Multi-Project Isolation — изоляция проектов

**Как** Team Lead,
**я хочу** чтобы каждый из 5 проектов имел свою изолированную область (контекст, память, агенты),
**чтобы** контекст одного проекта не утекал в другой и агенты разных проектов не конфликтовали.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 11.1 | Каждый проект имеет свою папку `projects/{name}/` с `CONTEXT-BUFFER.md`, `KNOWLEDGE-BASE.md`, `memory/` | `ls projects/*/CONTEXT-BUFFER.md` — 5 файлов |
| 11.2 | Агент проекта A не может читать/писать контекст проекта B | Попытка доступа к чужому контексту → permission denied или пустой результат |
| 11.3 | Каждый проект имеет свой git worktree или ветку | `git worktree list` — 5 изолированных рабочих пространств |
| 11.4 | Один агент может работать только в одном проекте одновременно | Мониторинг: нет дублирования agent ID в разных проектах |
| 11.5 | Конфиг проекта (`project.json`) определяет его тип, агентов, приоритет | Файл существует и валиден для каждого из 5 проектов |

---

### US-012: Dynamic Agent Pool — пул агентов с балансировкой нагрузки

**Как** Team Lead,
**я хочу** чтобы агенты распределялись между проектами динамически на основе нагрузки и потребностей,
**чтобы** агенты не простаивали и не были заблокированы в одном проекте, когда другой нуждается в них.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 12.1 | Существует `agent-registry.json` с текущим статусом каждого агента (free/busy/error) | `cat .memory/agent-registry.json` — JSON с 19 записями |
| 12.2 | При назначении задачи агент выбирается из свободных по специализации | Лог: агент назначен, статус → busy |
| 12.3 | После завершения задачи агент возвращается в пул (status → free) | Лог: агент освобождён |
| 12.4 | Если все агенты нужной специализации заняты — задача ставится в очередь (не отбрасывается) | Задача в очереди с timestamp, не lost |
| 12.5 | Load balancing: utilization > 80% при 5 проектах | Метрика из `agent-registry.json`: busy_count / total_count > 0.8 |

---

### US-013: Project Queue — очередь задач на проект с приоритетами

**Как** Team Lead,
**я хочу** чтобы у каждого проекта была очередь задач с приоритетами (critical/high/normal/low),
**чтобы** критические задачи выполнялись первыми, а очереди не блокировали другие проекты.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 13.1 | Каждый проект имеет `projects/{name}/queue.json` с массивом задач | Файл существует, валидный JSON |
| 13.2 | Задачи в очереди имеют поля: `id, title, priority, status, assigned_agent, created_at, started_at` | Schema check |
| 13.3 | Приоритеты: `critical > high > normal > low` — критические задачи берутся первыми | Лог: critical задача назначена раньше normal |
| 13.4 | Максимальное время в очереди (queue time) < 5 минут для high+ | Метрика: `started_at - created_at < 300s` для priority >= high |
| 13.5 | Задачи с deadlock (агент ждёт ресурс, который держит другой агент того же проекта) обнаруживается и resolution через timeout | Timeout → reassign |

---

### US-014: Resource Awareness — знание кто свободен/занят

**Как** Team Lead,
**я хочу** видеть в реальном времени кто из агентов свободен, кто занят, и какой проект потребляет ресурсы,
**чтобы** принимать обоснованные решения о перераспределении.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 14.1 | Команда `/status` показывает таблицу: агент → статус (free/busy) → проект → задача | Вывод команды содержит эту таблицу |
| 14.2 | Дашборд utilization: % занятых агентов по проектам | `utilization_by_project` в метриках |
| 14.3 | Alert если utilization < 50% (простой) или > 90% (перегрузка) | Лог/уведомление при нарушении |
| 14.4 | История назначений (кто, когда, какой проект) — аудит-лог | Файл `agent-assignments.jsonl` растёт |

---

### US-015: Cross-Project Knowledge — обмен знаниями между проектами

**Как** Team Lead,
**я хочу** чтобы агенты проекта B могли использовать решения/паттерны из проекта A (если это применимо),
**чтобы** не изобретать велосипед и использовать накопленный опыт.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 15.1 | Существует `knowledge-index.md` — каталог паттерн/решений со ссылками на проекты | Файл существует, содержит записи |
| 15.2 | При решении задачи агент сначала проверяет knowledge-index (read-only) | Лог: knowledge-index consulted |
| 15.3 | После завершения задачи агент может предложить паттерн в knowledge-index | Запись в knowledge-index с source project |
| 15.4 | Cross-project knowledge — опционально, не блокирует задачу | Задача выполняется даже если knowledge-index пуст |

---

## Приоритизация (MoSCoW)

### Must Have (MVP) — 3 спринта

| US | Что | Почему MVP |
|----|-----|------------|
| **US-011** | Multi-Project Isolation | Без изоляции 5 проектов = хаос. Контекст утекает, агенты путаются |
| **US-012** | Dynamic Agent Pool | Без пула агенты простаивают или блокируются. utilization < 50% |
| **US-013** | Project Queue | Без очереди критические задачи ждут, пока low-priority дойдут |

### Should Have — 1 спринт после MVP

| US | Что | Почему Should |
|----|-----|---------------|
| **US-014** | Resource Awareness | Видимость нужна для контроля, но не блокирует работу. Без неё — ручной мониторинг |

### Could Have — 2 спринта после MVP

| US | Что | Почему Could |
|----|-----|--------------|
| **US-015** | Cross-Project Knowledge | Полезно для долгосрочной эффективности, но не критично для запуска 5 проектов |

### Won't Have (this release)

| Что | Почему Won't |
|-----|--------------|
| Автоматическое клонирование агентов при >5 проектах | Текущих 19 агентов достаточно для 5 проектов; масштабирование >5 — отдельная epic |
| Cross-project code sharing (импорт модулей между проектами) | Это нарушает изоляцию; knowledge sharing — только через паттерны/решения |
| ML-based load prediction | Избыточно; rule-based балансировки достаточно на этапе 5 проектов |

---

## Архитектурное решение: почему копии НЕ у всех агентов

### Текущая модель копий (как есть)

```
Агент           Копия          Зачем
─────────────   ──────────     ──────────────────────────────────
dev-1           dev-1-1        Параллельная работа над разными задачами
dev-2           dev-2-1        То же
dev-3           dev-3-1        То же
backend         backend-1      То же
code-reviewer   code-reviewer-1 Ревью двух проектов параллельно
qa-engineer     qa-engineer-1  QA двух проектов параллельно
security-auditor security-auditor-1 Аудит двух проектов
team-lead       team-lead-1/2/3 Оркестрация 3+ проектов
tech-writer     tech-writer-1  Документация двух проектов
```

**Почему НЕ у всех 19 агентов есть копии:**

| Группа агентов | Кол-во | Почему без копий |
|----------------|--------|-------------------|
| **Узкие специалисты** (db-specialist, data-engineer, mobile-dev, integration-specialist, devops) | 5 | Работают редко (раз в несколько дней). Копия простаивала бы 90% времени. Достаточно 1 экземпляра + очередь |
| **Специфичные роли** (legal-advisor, smm-strategist, skill-surgeon, product-manager) | 4 | Уникальная экспертиза, копия не даёт преимущества (один и тот же промпт/модель). Бутылочное горлышко — экспертиза, не параллелизм |
| **Вспомогательные** (tech-writer — уже есть копия) | 1 | Копия есть, хватает |

**Правило:** Копия создаётся когда:
1. Агент работает часто (>3 задач/день)
2. Задачи независимы (можно параллелить)
3. Стоимость копии (простой) < стоимость ожидания

**Для 5 проектов нужно добавить копии:**
- `dev-1-2`, `dev-2-2`, `dev-3-2` — ещё по 1 копии каждого dev (итого 3 dev × 3 копии = 9 dev-слотов)
- `backend-2` — 2-й backend (нужен для 3+ проектов с бэкендом)
- `qa-engineer-2` — 2-й QA (бутылочное горлышко приёмки)
- `code-reviewer-2` — 2-й ревьюер

**Итого:** 19 base + 12 copies = 31 агент-слот. Достаточно для 5 проектов с 4-6 агентами каждый.

---

## Delegation Routing: как работает назначение агентов

### Текущая модель (AS-IS)

```
Пользователь → Team Lead (primary build-агент)
    ↓
    task tool (вызов по имени агента)
    ↓
    Subagent выполняет → пишет в CONTEXT-BUFFER.md
    ↓
    Team Lead читает результат → следующий шаг
```

**Проблема:** Team Lead сам выбирает агента вручную. Нет awareness кто свободен.

### Целевая модель (TO-BE): Project-Aware Delegation

```
┌─────────────────────────────────────────────────────┐
│                   TEAM LEAD (оркестратор)            │
│                                                      │
│  1. Получает задачу из очереди проекта               │
│  2. Читает project.json проекта (тип, required_skills)│
│  3. Запрашивает agent-registry: кто свободен?         │
│  4. Выбирает агента по: specialization + availability │
│  5. Назначает: agent.status = busy, project = X       │
│  6. Вызывает task tool с agent name                   │
│  7. Агент работает в isolated project context         │
│  8. По завершении: agent.status = free                 │
│  9. Следующая задача из очереди (или другой проект)   │
└─────────────────────────────────────────────────────┘
```

### Delegation Routing — алгоритм

```
function assignAgent(task, project):
    # 1. Определяем required_specialization из task.type
    required = task.required_skills  # ["backend", "api"]

    # 2. Ищем свободных агентов нужной специализации
    candidates = agentRegistry.filter(
        specialization IN required
        AND status == "free"
        AND current_project == null OR current_project == task.project
    )

    # 3. Сортируем по приоритету
    #    a) Тот же проект (уже знаком с контекстом)
    #    b) Наименьшая загрузка за день
    #    c) Лучший рейтинг (.memory/ratings.jsonl)
    candidates.sort(by: [same_project, daily_load, rating])

    # 4. Если нет свободных — в очередь ожидания
    if candidates.empty:
        task.status = "queued"
        task.queued_at = now()
        return null

    # 5. Назначаем лучшего кандидата
    agent = candidates[0]
    agent.status = "busy"
    agent.current_project = task.project
    agent.current_task = task.id
    task.assigned_agent = agent.name
    task.status = "assigned"
    task.started_at = now()

    return agent
```

### Specialization Matrix (кто что может)

| Агент | Специализация | Может в проекте |
|-------|---------------|-----------------|
| dev-1/2/3 | general-code | Любой |
| backend | api, server | Backend-heavy |
| frontend | ui, css, react | Frontend-heavy |
| db-specialist | sql, schema, migrations | Data-heavy |
| devops | docker, ci, infra | Any (infrastructure) |
| qa-engineer | testing, bugs | Any (quality) |
| code-reviewer | review | Any (quality) |
| security-auditor | security | Any (quality) |
| tech-writer | docs | Any (documentation) |
| data-engineer | etl, analytics | Data pipelines |
| integration-specialist | api-integration | Integration-heavy |
| mobile-dev | react-native, flutter | Mobile |
| legal-advisor | legal | Legal-specific |
| smm-strategist | marketing | Marketing-specific |
| skill-surgeon | skills | Skills management |
| product-manager | requirements | Requirements |
| team-lead | orchestration | Meta (управление) |

---

## Нефункциональные требования

| Категория | Требование | Метрика |
|-----------|-----------|---------|
| **Производительность** | Назначение агента на задачу < 2 сек | Время от `task.created` до `task.started` |
| **Производительность** | Queue time < 5 мин для high+ priority | `started_at - created_at < 300s` |
| **Изоляция** | Контекст проекта A недоступен агенту проекта B | Security test: попытка доступа → fail |
| **Масштабируемость** | 5 проектов × 6 агентов = 30 concurrent tasks без деградации | Utilization > 80%, queue time < 5 мин |
| **Надёжность** | Агент не "застревает" — timeout 15 мин на задачу | Timeout → reassign → dead-letter |
| **Аудит** | Каждое назначение логируется | `agent-assignments.jsonl` |
| **Обратная совместимость** | Текущие 2 проекта продолжают работать без изменений | news-bot, pong-advanced — PASS |

---

## Рекомендуемый Tech Stack

| Компонент | Технология | Обоснование |
|-----------|-----------|-------------|
| **Project Isolation** | Директории `projects/{name}/` + git worktree | Простота, нативная git изоляция, Windows-совместимость |
| **Agent Registry** | JSON файл `.memory/agent-registry.json` + PowerShell/Node скрипты | Консистентно с текущей архитектурой (JSON-based memory) |
| **Task Queue** | JSON файлы `projects/{name}/queue.json` + скрипт `project-queue.ps1` | Простота, нет внешних зависимостей, версионируется в git |
| **Load Balancing** | Rule-based (specialization + availability + rating) | Достаточно для 5 проектов; ML — избыточно |
| **Monitoring** | Расширенный `/status` + `agent-utilization.ps1` | Консистентно с текущими командами |
| **Knowledge Index** | `knowledge-index.md` (markdown с frontmatter) | Читаемо людьми и агентами, версионируется в git |

---

## Риски и зависимости

| Риск | Описание | Митигация |
|------|----------|-----------|
| **R1: Дедлоки** | Агент A ждёт агента B в том же проекте, B ждёт A | Timeout 15 мин → reassign → dead-letter. Мониторинг цепочек ожидания |
| **R2: Бутылочное горлышко** | Все 5 проектов хотят backend одновременно | Очередь с приоритетами; dynamic priority boost для waiters |
| **R3: Context leak** | Агент случайно читает контекст другого проекта | Permission check в delegation script; isolation в prompts |
| **R4: Простой агентов** | При Uneven load одни проекты простаивают | Load balancing: если utilization < 50% — перераспределяем |
| **R5: Сложность** | Дополнительные скрипты и файлы | Минимум new files; расширение существующих |
| **Зависимость D1** | opencode.json重大项目 → перезапуск TUI | Hot-reload не поддерживается; команда `/sync` для обновления |
| **Зависимость D2** | 19 агентов + copies = 31 слот в opencode.json | Проверить лимит opencode (тестировать с 31 агентом) |

---

## Roadmap

### Sprint 1 (MVP Foundation) — 10 дней

**US-011: Multi-Project Isolation**

| День | Задача | Кто |
|------|--------|-----|
| 1-2 | Создать `projects/{name}/` структуру для 5 проектов (шаблон) | dev-1 |
| 3-4 | Изолированный CONTEXT-BUFFER.md для каждого проекта | tech-writer |
| 5-6 | Git worktree для каждого проекта | devops |
| 7-8 | Permission boundaries: агент не видит чужой контекст | security-auditor |
| 9-10 | Тест изоляции: 2 проекта параллельно, проверка на leak | qa-engineer |

### Sprint 2 (Dynamic Pool + Queue) — 10 дней

**US-012: Dynamic Agent Pool + US-013: Project Queue**

| День | Задача | Кто |
|------|--------|-----|
| 1-3 | `agent-registry.json` + скрипт обновления статусов | dev-2 |
| 4-6 | `project-queue.ps1`: создание/чтение/назначение из очереди | dev-3 |
| 7-8 | Delegation routing: алгоритм выбора агента | backend |
| 9-10 | Интеграция: Team Lead использует delegation при назначении | team-lead |

### Sprint 3 (Monitoring + Polish) — 7 дней

**US-014: Resource Awareness**

| День | Задача | Кто |
|------|--------|-----|
| 1-3 | Расширенный `/status` с таблицей агентов | dev-1 |
| 4-5 | `agent-utilization.ps1`: метрики по проектам | data-engineer |
| 6-7 | Alerts: utilization < 50% / > 90% | devops |

### Sprint 4 (Knowledge) — 5 дней (Could Have)

**US-015: Cross-Project Knowledge**

| День | Задача | Кто |
|------|--------|-----|
| 1-2 | `knowledge-index.md` структура + шаблон | tech-writer |
| 3-4 | Интеграция в delegation: проверка index перед решением | backend |
| 5 | Тест: агент проекта B использует паттерн проекта A | qa-engineer |

---

## Definition of Done

- [ ] 5 проектов работают одновременно без конфликтов контекста
- [ ] Агенты не простаивают — utilization > 80%
- [ ] Queue time < 5 мин для high+ priority задач
- [ ] Контекст проекта A недоступен агенту проекта B (проверено security-тестом)
- [ ] `/status` показывает таблицу агентов по проектам
- [ ] Все существующие проекты (news-bot, pong-advanced) продолжают работать
- [ ] agent-registry.json содержит актуальные статусы всех агентов
- [ ] Documentation обновлена (AGENTS.md, README.md)
