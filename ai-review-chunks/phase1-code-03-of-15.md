# PHASE1 PART 3/15

   70: **чтобы** критические задачи выполнялись первыми, а очереди не блокировали другие проекты.
   71: 
   72: **Acceptance Criteria:**
   73: 
   74: | # | Критерий | Проверяемость |
   75: |---|----------|---------------|
   76: | 13.1 | Каждый проект имеет `projects/{name}/queue.json` с массивом задач | Файл существует, валидный JSON |
   77: | 13.2 | Задачи в очереди имеют поля: `id, title, priority, status, assigned_agent, created_at, started_at` | Schema check |
   78: | 13.3 | Приоритеты: `critical > high > normal > low` — критические задачи берутся первыми | Лог: critical задача назначена раньше normal |
   79: | 13.4 | Максимальное время в очереди (queue time) < 5 минут для high+ | Метрика: `started_at - created_at < 300s` для priority >= high |
   80: | 13.5 | Задачи с deadlock (агент ждёт ресурс, который держит другой агент того же проекта) обнаруживается и resolution через timeout | Timeout → reassign |
   81: 
   82: ---
   83: 
   84: ### US-014: Resource Awareness — знание кто свободен/занят
   85: 
   86: **Как** Team Lead,
   87: **я хочу** видеть в реальном времени кто из агентов свободен, кто занят, и какой проект потребляет ресурсы,
   88: **чтобы** принимать обоснованные решения о перераспределении.
   89: 
   90: **Acceptance Criteria:**
   91: 
   92: | # | Критерий | Проверяемость |
   93: |---|----------|---------------|
   94: | 14.1 | Команда `/status` показывает таблицу: агент → статус (free/busy) → проект → задача | Вывод команды содержит эту таблицу |
   95: | 14.2 | Дашборд utilization: % занятых агентов по проектам | `utilization_by_project` в метриках |
   96: | 14.3 | Alert если utilization < 50% (простой) или > 90% (перегрузка) | Лог/уведомление при нарушении |
   97: | 14.4 | История назначений (кто, когда, какой проект) — аудит-лог | Файл `agent-assignments.jsonl` растёт |
   98: 
   99: ---
  100: 
  101: ### US-015: Cross-Project Knowledge — обмен знаниями между проектами
  102: 
  103: **Как** Team Lead,
  104: **я хочу** чтобы агенты проекта B могли использовать решения/паттерны из проекта A (если это применимо),
  105: **чтобы** не изобретать велосипед и использовать накопленный опыт.
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 145-260

```markdown
  145: | Cross-project code sharing (импорт модулей между проектами) | Это нарушает изоляцию; knowledge sharing — только через паттерны/решения |
  146: | ML-based load prediction | Избыточно; rule-based балансировки достаточно на этапе 5 проектов |
  147: 
  148: ---
  149: 
  150: ## Архитектурное решение: почему копии НЕ у всех агентов
  151: 
  152: ### Текущая модель копий (как есть)
  153: 
  154: ```
  155: Агент           Копия          Зачем
  156: ─────────────   ──────────     ──────────────────────────────────
  157: dev-1           dev-1-1        Параллельная работа над разными задачами
  158: dev-2           dev-2-1        То же
  159: dev-3           dev-3-1        То же
  160: backend         backend-1      То же
  161: code-reviewer   code-reviewer-1 Ревью двух проектов параллельно
  162: qa-engineer     qa-engineer-1  QA двух проектов параллельно
  163: security-auditor security-auditor-1 Аудит двух проектов
  164: team-lead       team-lead-1/2/3 Оркестрация 3+ проектов
  165: tech-writer     tech-writer-1  Документация двух проектов
  166: ```
  167: 
  168: **Почему НЕ у всех 19 агентов есть копии:**
  169: 
  170: | Группа агентов | Кол-во | Почему без копий |
  171: |----------------|--------|-------------------|
  172: | **Узкие специалисты** (db-specialist, data-engineer, mobile-dev, integration-specialist, devops) | 5 | Работают редко (раз в несколько дней). Копия простаивала бы 90% времени. Достаточно 1 экземпляра + очередь |
  173: | **Специфичные роли** (legal-advisor, smm-strategist, skill-surgeon, product-manager) | 4 | Уникальная экспертиза, копия не даёт преимущества (один и тот же промпт/модель). Бутылочное горлышко — экспертиза, не параллелизм |
  174: | **Вспомогательные** (tech-writer — уже есть копия) | 1 | Копия есть, хватает |
  175: 
  176: **Правило:** Копия создаётся когда:
  177: 1. Агент работает часто (>3 задач/день)
  178: 2. Задачи независимы (можно параллелить)
  179: 3. Стоимость копии (простой) < стоимость ожидания
  180: 
  181: **Для 5 проектов нужно добавить копии:**
  182: - `dev-1-2`, `dev-2-2`, `dev-3-2` — ещё по 1 копии каждого dev (итого 3 dev × 3 копии = 9 dev-слотов)
  183: - `backend-2` — 2-й backend (нужен для 3+ проектов с бэкендом)
  184: - `qa-engineer-2` — 2-й QA (бутылочное горлышко приёмки)
  185: - `code-reviewer-2` — 2-й ревьюер
  186: 
  187: **Итого:** 19 base + 12 copies = 31 агент-слот. Достаточно для 5 проектов с 4-6 агентами каждый.
  188: 
  189: ---
  190: 
  191: ## Delegation Routing: как работает назначение агентов
  192: 
  193: ### Текущая модель (AS-IS)
  194: 
  195: ```
  196: Пользователь → Team Lead (primary build-агент)
  197:     ↓
  198:     task tool (вызов по имени агента)
  199:     ↓
  200:     Subagent выполняет → пишет в CONTEXT-BUFFER.md
  201:     ↓
  202:     Team Lead читает результат → следующий шаг
  203: ```
  204: 
  205: **Проблема:** Team Lead сам выбирает агента вручную. Нет awareness кто свободен.
  206: 
  207: ### Целевая модель (TO-BE): Project-Aware Delegation
  208: 
  209: ```
  210: ┌─────────────────────────────────────────────────────┐
  211: │                   TEAM LEAD (оркестратор)            │
  212: │                                                      │
  213: │  1. Получает задачу из очереди проекта               │
  214: │  2. Читает project.json проекта (тип, required_skills)│
  215: │  3. Запрашивает agent-registry: кто свободен?         │
  216: │  4. Выбирает агента по: specialization + availability │
  217: │  5. Назначает: agent.status = busy, project = X       │
  218: │  6. Вызывает task tool с agent name                   │
  219: │  7. Агент работает в isolated project context         │
  220: │  8. По завершении: agent.status = free                 │
  221: │  9. Следующая задача из очереди (или другой проект)   │
  222: └─────────────────────────────────────────────────────┘
  223: ```
  224: 
  225: ### Delegation Routing — алгоритм
  226: 
  227: ```
  228: function assignAgent(task, project):
  229:     # 1. Определяем required_specialization из task.type
  230:     required = task.required_skills  # ["backend", "api"]
  231: 
  232:     # 2. Ищем свободных агентов нужной специализации
  233:     candidates = agentRegistry.filter(
  234:         specialization IN required
  235:         AND status == "free"
  236:         AND current_project == null OR current_project == task.project
  237:     )
  238: 
  239:     # 3. Сортируем по приоритету
  240:     #    a) Тот же проект (уже знаком с контекстом)
  241:     #    b) Наименьшая загрузка за день
  242:     #    c) Лучший рейтинг (.memory/ratings.jsonl)
  243:     candidates.sort(by: [same_project, daily_load, rating])
  244: 
  245:     # 4. Если нет свободных — в очередь ожидания
  246:     if candidates.empty:
  247:         task.status = "queued"
  248:         task.queued_at = now()
  249:         return null
  250: 
  251:     # 5. Назначаем лучшего кандидата
  252:     agent = candidates[0]
  253:     agent.status = "busy"
  254:     agent.current_project = task.project
  255:     agent.current_task = task.id
  256:     task.assigned_agent = agent.name
  257:     task.status = "assigned"
  258:     task.started_at = now()
  259: 
  260:     return agent
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 285-384

```markdown
  285: ---
  286: 
  287: ## Нефункциональные требования
  288: 
  289: | Категория | Требование | Метрика |
  290: |-----------|-----------|---------|
  291: | **Производительность** | Назначение агента на задачу < 2 сек | Время от `task.created` до `task.started` |
  292: | **Производительность** | Queue time < 5 мин для high+ priority | `started_at - created_at < 300s` |
  293: | **Изоляция** | Контекст проекта A недоступен агенту проекта B | Security test: попытка доступа → fail |
  294: | **Масштабируемость** | 5 проектов × 6 агентов = 30 concurrent tasks без деградации | Utilization > 80%, queue time < 5 мин |
  295: | **Надёжность** | Агент не "застревает" — timeout 15 мин на задачу | Timeout → reassign → dead-letter |
  296: | **Аудит** | Каждое назначение логируется | `agent-assignments.jsonl` |
  297: | **Обратная совместимость** | Текущие 2 проекта продолжают работать без изменений | news-bot, pong-advanced — PASS |
  298: 
  299: ---
  300: 
  301: ## Рекомендуемый Tech Stack
  302: 
  303: | Компонент | Технология | Обоснование |
  304: |-----------|-----------|-------------|
  305: | **Project Isolation** | Директории `projects/{name}/` + git worktree | Простота, нативная git изоляция, Windows-совместимость |
  306: | **Agent Registry** | JSON файл `.memory/agent-registry.json` + PowerShell/Node скрипты | Консистентно с текущей архитектурой (JSON-based memory) |
  307: | **Task Queue** | JSON файлы `projects/{name}/queue.json` + скрипт `project-queue.ps1` | Простота, нет внешних зависимостей, версионируется в git |
  308: | **Load Balancing** | Rule-based (specialization + availability + rating) | Достаточно для 5 проектов; ML — избыточно |
  309: | **Monitoring** | Расширенный `/status` + `agent-utilization.ps1` | Консистентно с текущими командами |
  310: | **Knowledge Index** | `knowledge-index.md` (markdown с frontmatter) | Читаемо людьми и агентами, версионируется в git |
  311: 
  312: ---
  313: 
  314: ## Риски и зависимости
  315: 
  316: | Риск | Описание | Митигация |
  317: |------|----------|-----------|
  318: | **R1: Дедлоки** | Агент A ждёт агента B в том же проекте, B ждёт A | Timeout 15 мин → reassign → dead-letter. Мониторинг цепочек ожидания |
  319: | **R2: Бутылочное горлышко** | Все 5 проектов хотят backend одновременно | Очередь с приоритетами; dynamic priority boost для waiters |
  320: | **R3: Context leak** | Агент случайно читает контекст другого проекта | Permission check в delegation script; isolation в prompts |
  321: | **R4: Простой агентов** | При Uneven load одни проекты простаивают | Load balancing: если utilization < 50% — перераспределяем |
  322: | **R5: Сложность** | Дополнительные скрипты и файлы | Минимум new files; расширение существующих |
  323: | **Зависимость D1** | opencode.json重大项目 → перезапуск TUI | Hot-reload не поддерживается; команда `/sync` для обновления |
  324: | **Зависимость D2** | 19 агентов + copies = 31 слот в opencode.json | Проверить лимит opencode (тестировать с 31 агентом) |
  325: 
  326: ---
  327: 
  328: ## Roadmap
  329: 
  330: ### Sprint 1 (MVP Foundation) — 10 дней
  331: 
  332: **US-011: Multi-Project Isolation**
  333: 
  334: | День | Задача | Кто |
  335: |------|--------|-----|
  336: | 1-2 | Создать `projects/{name}/` структуру для 5 проектов (шаблон) | dev-1 |
  337: | 3-4 | Изолированный CONTEXT-BUFFER.md для каждого проекта | tech-writer |
  338: | 5-6 | Git worktree для каждого проекта | devops |
  339: | 7-8 | Permission boundaries: агент не видит чужой контекст | security-auditor |
  340: | 9-10 | Тест изоляции: 2 проекта параллельно, проверка на leak | qa-engineer |
  341: 
  342: ### Sprint 2 (Dynamic Pool + Queue) — 10 дней
  343: 
  344: **US-012: Dynamic Agent Pool + US-013: Project Queue**
  345: 
  346: | День | Задача | Кто |
  347: |------|--------|-----|
  348: | 1-3 | `agent-registry.json` + скрипт обновления статусов | dev-2 |
  349: | 4-6 | `project-queue.ps1`: создание/чтение/назначение из очереди | dev-3 |
  350: | 7-8 | Delegation routing: алгоритм выбора агента | backend |
  351: | 9-10 | Интеграция: Team Lead использует delegation при назначении | team-lead |
  352: 
  353: ### Sprint 3 (Monitoring + Polish) — 7 дней
  354: 
  355: **US-014: Resource Awareness**
  356: 
  357: | День | Задача | Кто |
  358: |------|--------|-----|
  359: | 1-3 | Расширенный `/status` с таблицей агентов | dev-1 |
  360: | 4-5 | `agent-utilization.ps1`: метрики по проектам | data-engineer |
  361: | 6-7 | Alerts: utilization < 50% / > 90% | devops |
  362: 
  363: ### Sprint 4 (Knowledge) — 5 дней (Could Have)
  364: 
  365: **US-015: Cross-Project Knowledge**
  366: 
  367: | День | Задача | Кто |
  368: |------|--------|-----|
  369: | 1-2 | `knowledge-index.md` структура + шаблон | tech-writer |
  370: | 3-4 | Интеграция в delegation: проверка index перед решением | backend |
  371: | 5 | Тест: агент проекта B использует паттерн проекта A | qa-engineer |
  372: 
  373: ---
  374: 
  375: ## Definition of Done
  376: 
  377: - [ ] 5 проектов работают одновременно без конфликтов контекста
  378: - [ ] Агенты не простаивают — utilization > 80%
  379: - [ ] Queue time < 5 мин для high+ priority задач
  380: - [ ] Контекст проекта A недоступен агенту проекта B (проверено security-тестом)
  381: - [ ] `/status` показывает таблицу агентов по проектам
  382: - [ ] Все существующие проекты (news-bot, pong-advanced) продолжают работать
  383: - [ ] agent-registry.json содержит актуальные статусы всех агентов
  384: - [ ] Documentation обновлена (AGENTS.md, README.md)
```

### `opencode.json` lines 1-110

```json
    1: {
    2:   "$schema": "https://opencode.ai/config.json",
    3:   "mcp": {
    4:     "context7": {
    5:       "type": "local",
    6:       "command": [
    7:         "context7-mcp.cmd"
    8:       ],
    9:       "enabled": true
   10:     },
   11:     "hermes-atlas-mcp": {
   12:       "type": "local",
   13:       "command": [
   14:         "hermes-atlas-mcp.cmd"
   15:       ],
   16:       "enabled": true
   17:     },
   18:     "sequential-thinking": {
   19:       "type": "local",
   20:       "command": [
   21:         "mcp-server-sequential-thinking.cmd"
   22:       ],
   23:       "enabled": true
   24:     },
   25:     "serena": {
   26:       "type": "local",
   27:       "command": [
   28:         "uvx",
   29:         "--from",
   30:         "git+https://github.com/oraios/serena",
   31:         "serena",
   32:         "start-mcp-server",
   33:         "--project-from-cwd"
   34:       ],
   35:       "enabled": false,
   36:       "timeout": 30000,
   37:       "cwd": ".",
   38:       "environment": {
   39:         "HTTP_PROXY": "http://127.0.0.1:3128",
   40:         "HTTPS_PROXY": "http://127.0.0.1:3128",
   41:         "NO_PROXY": "localhost,127.0.0.1,10.*,192.168.*,*.minsk.energo.net"
   42:       }
   43:     }
   44:   },
   45:   "command": {
   46:     "new-project": {
   47:       "template": "Создай новый проект в .agents/projects/ по выбранному шаблону (full-stack/api-only/mobile/data-pipeline): структуру папок, базовые конфиги, README. Используй .agents/scripts/create-project.ps1 если есть. Спроси тип проекта если не задан.",
   48:       "description": "Создать новый проект по шаблону (full-stack/api-only/mobile/data-pipeline)."
   49:     },
   50:     "cost-report": {
   51:       "template": "Сформируй отчёт по стоимости сессий: прочитай файлы из %LOCALAPPDATA%\\opencode\\agent-hq-traces\\ (traces.jsonl и performance.jsonl). Посчитай суммарные токены/время/ошибки по агентам и сессиям. Выведи таблицей. Если данных нет — сообщи об этом.",
   52:       "description": "Отчёт по стоимости и токенам из трейсов."
   53:     },
   54:     "team-report": {
   55:       "template": "Сформируй отчёт команды agent-hq: кто работал (агенты), какие задачи (из .memory/inbox/outbox), результаты ревью, рейтинг моделей (.memory/ratings.jsonl). Сохрани в .memory/reports/team-report-<date>.md.",
   56:       "description": "Сформировать отчёт команды из трейсов и Memory Bank."
   57:     },
   58:     "sync": {
   59:       "template": "Синхронизируй состояние системы: перегенерируй .memory/activeContext.md, progress.md, decisionLog.md из CONTEXT-BUFFER.md и KNOWLEDGE-BASE.md. Обнови секцию agent в opencode.json из .opencode/agents/*.json через .agents/scripts/sync-agents.ps1. Запиши результат в CONTEXT-BUFFER.md.",
   60:       "description": "Синхронизация агентов и Memory Bank из CONTEXT-BUFFER/KNOWLEDGE-BASE."
   61:     },
   62:     "status": {
   63:       "template": "Покажи статус системы agent-hq: список агентов из registry.json, состояние Memory Bank (.memory/), активные worktrees (.agents/worktrees/), результат health-check. Запусти .agents/scripts/health-check.ps1 если есть. Ответ кратко, таблицей.\n\n## Agents & Utilization\nПосле базового статуса покажи секцию 'Agents & Utilization':\n1. Запусти `.agents/scripts/agent-registry.ps1 -List` и покажи таблицу: Агент | Статус | Проект | Задача\n2. Запусти `.agents/scripts/agent-utilization.ps1` и покажи вывод: сводка, busy по проектам, free по ролям, алерты, последние 5 назначений из аудит-лога.",
   64:       "description": "Статус системы agent-hq: агенты, utilization, Memory Bank, worktrees, здоровье."
   65:     }
   66:   },
   67:   "agents": {
   68:     "backend-1": {
   69:         "description": "Backend Specialist (copy 1) — REST/GraphQL API, бизнес-логика, middleware, авторизация для параллельной работы.",
   70:         "mode": "subagent",
   71:         "model": "tokenrouter/z-ai/glm-5.3-free",
   72:         "temperature": 0.2,
   73:         "permission": {
   74:             "bash": "allow",
   75:             "edit": "allow",
   76:             "external_directory": {
   77:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
   78:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",


---
Ответь только: `Принято 3/15`. Жди следующую часть.
