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

### US-016: Telegram-мост — удалённый мониторинг и управление (monitoring-first)

**Как** пользователь,
**я хочу** видеть все открытые сессии opencode (и всё, что делает моя агентская система) в Telegram с телефона,
**чтобы** удалённо контролировать работу и взаимодействовать с ней без доступа к консоли рабочего компа.

**Глобальная архитектура:**
- Стек: Python 3 + aiogram 3.29 (УЖЕ установлена, новых пакетов НЕ ставить) через корпоративный прокси cntlm `127.0.0.1:3128`.
- Расположение: `projects/telegram-bridge/` (внутри agent-hq — покрыто исключениями ЦКБ).
- Режим работы: schtasks-задача `agent-hq-telegram-bridge` (короткий прогон 5-15 сек каждые 1-2 мин: getUpdates + push-детектор + выход). Регистрация задачи — ТОЛЬКО с явного ОК пользователя (§10). Аргументы безопасности: та же форма, что работающий без детектов `agent-hq-inbox-poller`; никаких Stop-Process/скрытых окон/реестра/schtasks-записей из кода бота.
- Источники (read-only): SQLite opencode (`opencode.db`, режим readonly — список сессий/директорий/последней активности), `.memory/agent-registry.json` (free/busy), `.memory/{inbox,outbox,dead-letter}`, `projects/*/queue.json`, хвост `CONTEXT-BUFFER.md`.

**Acceptance Criteria (MVP — только чтение):**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 16.1 | `/sessions` — список открытых сессий opencode: директория (pong / 1c-buh / news и т.п. — тег, не полный путь), время последней активности. Из списка — просмотр деталей сессии: цепочка делегаций (от главного к исполнителям: агент → статус → краткое ТЗ одной строкой). Механизм навигации — на уточнении у пользователя (отложено) | Сообщение ≤ 4096 симв (сегментация) |
| 16.2 | `/agents` — free/busy → проект → задача (из agent-registry) | Соответствует registry на момент тика |
| 16.3 | `/queue` — глубина очередей всех проектов | Числа = содержимому queue.json |
| 16.4 | `/tasks` — последние inbox/outbox/dead-letter сообщения шины | Соответствует файлам шины |
| 16.5 | `/buffer` — хвост CONTEXT-BUFFER (последние записи) | Последние N записей |
| 16.6 | Push-уведомления (ярусы): 🔴 blocker `PRIORITY:critical` + 💀 dead-letter — instant, со звуком, до 3 в сообщении; ⚠️ REJECT — все за тик одним сообщением-списком; ✅ «задача завершена» — одно сводное сообщение за тик. Hard cap 5 сообщений/тик, шторм-контроль (авто-почасовик), тумблер `/alerts`. Дедуп по id события, state в bridge-state.json переживает рестарт | Push ≤ 1 тик после события, без дублей |
| 16.7 | Whitelist: отвечает ТОЛЬКО chat_id пользователя; чужие — игнор + лог | Сообщение с чужого chat_id не вызывает ответа |
| 16.8 | Токен бота не попадает в git (config.local.json в .gitignore + env). /revoke старого токена (засвечен в чате opencode) — БЛОКЕР деплоя; новый передаётся НЕ через чат | `git log -p` не содержит токена |
| 16.9 | MVP ничего не пишет в шину/очереди/сессии — только читает. Статический write-чек в qa: SQL только SELECT, SQLite `?mode=ro` + `PRAGMA query_only=1`, BUSY → тихий скип тика; запрет open(w/a)/subprocess/schtasks/регментра в коде | grep-чек по запрет-листу PASS |
| 16.10 | Запуск вручную `python bridge.py --once` работает без регистрации schtasks (для отладки) | Команда выводит дайджест в консоль |
| 16.11 | Санитайзер — единая точка перед sendMessage: секреты (token=, password=, api_key=, `sk-`, `ghp_`, `xoxb-`, JWT eyJ, PEM, connection-strings) → `[REDACTED:...]`; пути → теги проектов; `html.escape()` на весь динамический контент; `disable_web_page_preview` | Фикстура с секретами не покидает ПК в исходном виде |
| 16.12 | Push-детектор — структурный regex с привязкой к формату записи шины (`^[TIME]...`), не substring-матч; rate-limit; дедуп | Фейковая «blocker critical» строка в контенте не триггерит push |
| 16.13 | Рабочие окна: активен строго пн-пт 08:00–17:00 — вне окна бот полностью молчит (ни ответов, ни push), буферизация вне окна не нужна (система вне окна не работает) | Запуск в субботу/вечером — бот не отвечает |
| 16.14 | Empty states: все команды при пустых источниках отвечают внятным «активных сессий нет» (не пустота, не traceback); first-run без токена — понятная ошибка, exit≠0 | Прогон с пустыми источниками |
| 16.15 | Анти-дубли: подряд идущие одинаковые команды от одного chat_id = один ответ; анти-наложение тиков: schtasks `/ET` + IgnoreNew, network-timeout < интервала | Двойное нажатие не даёт два ответа |
| 16.16 | UX-контракт задержки: /start декларирует «ответ ≤ 2 мин — норма»; каждый ответ несёт метку `⏱ данные на ЧЧ:ММ`; setMyCommands (нативное «/»-меню); команды латиницей + русские текстовые фразы-синонимы («что происходит», «кто занят» — словарь ~20-30 фраз) | /start содержит контракт |
| 16.17 | Локальный аудит-лог исходящих сообщений (bridge-outbox.log): тип события, проект-тег, время — без текста (доказательство, что наружу уходили только статусы) | Файл растёт, доступен для проверки |

**v2 (после того как MVP поживёт; отдельная фаза, новое ревью):**
- Reply на сообщение агента → текст в inbox этого агента → poller подхватывает.
- Кнопки Да/Нет для запросов агентов на ОК пользователя (schtasks и т.п.).
- `/run <agent> <текст>` — выдать команду агенту из ТГ.

**План делегирования (MVP):**

| Фаза | Кто | Что | Оценка (агент) |
|------|-----|-----|----------------|
| A | dev-1 | Каркас: aiogram + прокси, setMyCommands, whitelist, анти-дубли, `--once`, HTML+escape, empty states | 35 мин |
| B | dev-2 | collectors + санитайзер-фаннел (16.11) + форматтеры (сегментация 4096, теги проектов, 2-строчные блоки, empty states) | 40 мин |
| C | dev-1 | Push-детектор: структурный regex (16.12), ярусы (16.6), дедуп, cap, шторм-контроль, тумблер /alerts | 30 мин |
| D | qa-engineer | Тесты на моках + статический write-чек (16.9) + фикстура 20+ сессий со спецсимволами `<>&_*[]` и секретами | 25 мин |
| E | code-reviewer + security-auditor | Ревью по чеклистам (redaction, whitelist, read-only, токен, инъекции) | 30 мин |
| F | tech-writer | README + тексты для BotFather (подготовлены smm-strategist) | 10 мин |

**Консультация 6 агентов (10.09.2026, все вердикты MODIFY — после правок approve):** PM (скоуп/KPI/empty states), frontend (HTML vs MarkdownV2, сегментация, контракт задержки, макеты push), security-auditor (threat model T1-T11, /revoke-блокер, redaction, write-чек), smm-strategist (push-ярусы, анти-спам, тексты), legal-advisor (юр. оценка РБ: data minimization, санитайзер в архитектуре, аудит-лог исходящих), mobile-dev (push-first, heartbeat-дайджест, 2-строчные сессии). Полные отчёты — в истории сессий тимлида.

**РЕШЕНИЯ ПОЛЬЗОВАТЕЛЯ (11.09.2026, все открытые вопросы закрыты):**
1. Навигация «сессия → детали»: **inline-кнопки + номер-фолбэк** — кнопки под списком (в тик — мгновенно 5-15 сек), протухший спиннер лечится текстовым номером («2» → детали следующим тиком). Оба пути работают всегда.
2. Суть ТЗ агента в деталях: **краткая первая строка ТЗ после санитайзера** (секреты/клиенты redacted, пути → теги) — триаж с телефона важнее; средний legal-риск принят осознанно.
3. Рабочие часы: **строго пн-пт 08:00–17:00** — вне окна бот полностью молчит (ни ответов, ни push); буферизация не нужна (система не работает вне окна).
4. Ввод: **русские фразы-синонимы + /команды параллельно** (словарь ~20-30 фраз) + нативное «/»-меню setMyCommands.

**Blocker для деплоя (не для разработки):** bot-token от @BotFather — /revoke старого (засвечен в чате), новый НЕ через чат; разработка и тесты — на моках.

**Won't Have (this release):** постоянный скрытый процесс (PDM-риск — прецедент sberbank-бота); вебхук-режим (нужен внешний IP); отправка команд до приёмки MVP (v2 отдельно).

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
| **US-016** | Telegram-мост (MVP: мониторинг сессий) | Удалённый контроль удобен, но система работает и без него; ждёт bot-token |

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
