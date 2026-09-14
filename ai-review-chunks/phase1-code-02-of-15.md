# PHASE1 PART 2/15

   49: | `.agents/scripts/` | 18 скриптов — Управление: sync-agents.ps1, verify-phase.ps1, health-check.ps1, message-queue.ps1, cleanup-garbage.ps1, generate-agent-cards.ps1; Мультипроектность: create-project.ps1 (US-011), agent-registry.ps1 (пул агентов US-012), project-queue.ps1 (очереди US-013), agent-utilization.ps1 (утилизация US-014); Quality: compliance-gate.ps1, prompt-gate.ps1, model-leaderboard.ps1; Recovery: inbox-poller.ps1, run-poller.ps1, run-daemons.ps1, session-recovery.ps1, tui-cleanup.ps1 (ручной чистильщик сессий) |
   50: | `.agents/skills/` | 24 скилла: 17 для 1С + 7 core + 4 superpowers (spec/plan/implement/test) |
   51: | `.agents/tasks/` | Задачи для агентов (текстовые файлы) |
   52: | `.agents/worktrees/` | **30 git worktrees** — изолированные песочницы для каждого агента |
   53: | `.memory/` | Memory Bank: activeContext.md, progress.md, decisionLog.md, productContext.md, systemPatterns.md |
   54: | `.memory/inbox/{agent}/` | Входящие задачи агенту (JSON) |
   55: | `.memory/outbox/` | Результаты задач (JSON, status: done) |
   56: | `.memory/dead-letter/` | Сообщения с ошибками |
   57: | `.memory/archive/` | Архив сообщений старше 7 дней |
   58: | `.memory/traces/` | Логи трейсинга |
   59: | `.memory/reports/` | Отчёты (/team-report, /cost-report) |
   60: | `projects/` | Директория проектов (test-project, news-bot, pong-advanced, 1СBuh) |
   61: 
   62: ### Структура команды
   63: 
   64: ```
   65: Пользователь
   66:     │
   67:     ▼
   68: Dual-Agent: Team Lead + Product Manager (параллельно через task tool)
   69:     │
   70:     ├── task tool → 28 субагентов (параллельно)
   71:     │       │
   72:     │       ├── Разработка: dev-1×2, dev-2×2, dev-3×2, frontend, backend×2, db-specialist, mobile-dev, devops, integration-specialist, data-engineer
   73:     │       ├── Качество: qa-engineer×2, code-reviewer×2, security-auditor×2
   74:     │       ├── Управление: product-manager, tech-writer×2, skill-surgeon
   75:     │       └── Спец: legal-advisor, smm-strategist, team-lead×4
   76:     │
   77:     ├── CONTEXT-BUFFER.md (шина сообщений, self-report с SKILLS_LOADED/MCP_USED)
   78:     ├── .memory/ (Memory Bank — контекст между сессиями)
   79:     ├── .memory/inbox/{agent}/ (задачи агентам через файловые очереди)
   80:     ├── .memory/outbox/ (результаты)
   81:     ├── .agents/skills/ (24 скилла, подгружать перед работой — обязательно)
   82:     ├── .agents/locks/ (файловые блокировки для scheduler'а)
   83:     └── .agents/scripts/session-recovery.ps1 (автовосстановление при lock conflict)
   84: ```
   85: 
   86: ---
   87: 
   88: ## Как это работает
   89: 
   90: ### Основной цикл (Dual-Agent Delegation)
   91: 
   92: ```
   93: 1. Пользователь пишет задачу в TUI opencode (build/plan режим)
   94: 2. Primary agent запускает ПАРАЛЛЕЛЬНО:
   95:    task "Analyze requirements: <task>" subagent_type=product-manager
   96:    task "Create orchestration plan: <task>" subagent_type=team-lead
   97: 3. product-manager выдаёт: User Stories, Acceptance Criteria, MoSCoW, NFR, Stack
   98: 4. team-lead выдаёт: Architecture, Tech Stack, Delegation Plan, Risks
   99: 5. Оба читают вывод друг друга в CONTEXT-BUFFER.md → синхронизация
  100: 6. team-lead параллельно делегирует исполнителей через task tool:
  101:    task "Create UI: ..." subagent_type=frontend
  102:    task "Create API: ..." subagent_type=backend
  103:    task "Design DB: ..." subagent_type=db-specialist
  104:    ...
  105: 7. Каждый агент в своём worktree:
  106:    a. Читает последние 30 строк CONTEXT-BUFFER.md
  107:    b. ОБЯЗАТЕЛЬНО: skill <нужные-скиллы> → context7 (библиотеки) → sequential-thinking (>3 шага)
  108:    c. Выполняет задачу
  109:    d. Пишет self-report в CONTEXT-BUFFER.md (SKILLS_LOADED, MCP_USED, COMPLIANCE: true)
  110: 8. Проверяющие агенты (параллельно):
  111:     - qa-engineer: тесты, edge cases
  112:     - code-reviewer: ревью кода (read-only)
  113:     - security-auditor: безопасность (read-only)
  114: 9. Финальный коммит + PR
  115: ```
  116: 
  117: ### Auto-Recovery (Session Recovery)
  118: 
  119: При конфликте файловых блокировок (`Busy: FileSystem.writeFile ... info/exclude`):
  120: 
  121: ```
  122: 1. session-recovery.ps1 (фоновый демон) обнаруживает lock conflict в трейсах
  123: 2. Находит свободную копию team-lead (team-lead-1/2/3)
  124: 3. Создаёт задачу в inbox свободной копии с флагом recovery=true
  125: 4. Записывает в CONTEXT-BUFFER.md: auto-recovery delegation
  126: 5. Новая сессия поднимается на копии → продолжает работу
  127: ```
  128: 
  129: ### Inbox Poller (автозапуск воркеров)
  130: 
  131: `inbox-poller.ps1` — мониторит `.memory/inbox/{agent}/*.json` и автоматически запускает агентов:
  132: 
  133: | Флаг | Описание |
  134: |---|---|
  135: | `-Once` | Однократный прогон (проверить и выйти) |
  136: | `-IntervalSeconds N` | Интервал проверки в секундах (по умолчанию 30) |
  137: | `-DryRun` | Без реального запуска агентов (только проверка логики) |
  138: 
  139: ---
  140: 
```

### `README.md` lines 175-340

```markdown
  175: 
  176: ---
  177: 
  178: ## Модели
  179: 
  180: | Модель | Роль | Скорость | Используется |
  181: |---|---|---|---|
  182: | `tokenrouter/z-ai/glm-5.3-free` | Основная (качество, русский) | 5-6 сек | dev-1, dev-3, frontend, legal-advisor, product-manager, skill-surgeon, smm-strategist, team-lead, tech-writer, team-lead-1/2/3, dev-1-1, dev-2-1, dev-3-1, backend-1, qa-engineer-1, security-auditor-1, code-reviewer-1, tech-writer-1 |
  183: | `opencode/nemotron-3.5-lightning-free` | Быстрая (рутина) | 3-4 сек | backend, data-engineer, db-specialist, dev-2, devops, integration-specialist, mobile-dev, dev-2-1 |
  184: | `opencode/nemotron-3-ultra-free` | Запасная (глубокий анализ) | 7-8 сек | резервная / escalation |
  185: 
  186: **Запрещены** (нет в подписке): kimi-k2.x, glm-5.x, deepseek-v4-pro/flash, qwen-plus, minimax-m2.x/m3
  187: 
  188: > Платные модели запрещены. Стоимость всегда $0.
  189: 
  190: ---
  191: 
  192: ## MCP
  193: 
  194: Три сервера подключены в проектном `opencode.json` (секция `mcp`), доступны всем агентам автоматически:
  195: 
  196: | Сервер | Назначение |
  197: |--------|-----------|
  198: | **context7** | Актуальная документация библиотек в реальном времени: свежие API, примеры, миграции |
  199: | **hermes-atlas-mcp** | Каталог 100+ скиллов/тулов экосистемы Hermes Atlas — поиск и установка готовых скиллов |
  200: | **sequential-thinking** | Структурированное пошаговое планирование сложных задач (>3 шага) |
  201: 
  202: ---
  203: 
  204: ## Правила эффективности
  205: 
  206: 1. **Dual-Agent: Team Lead + Product Manager** — на КАЖДОМ запросе запускаются вместе параллельно
  207: 2. **Team Lead не пишет код** — только конфиги, документация, правки 1-2 строк
  208: 3. **Независимые задачи — строго параллельно** — один вызов task = несколько агентов одновременно
  209: 4. **Правило лимит-3**: попытки 1-2 тем же агентом (полный лог ошибок + путь к скиллу в ТЗ); попытка 3 — другой агент + более сильная модель (lightning → mimo → ultra); после третьей неудачи — эскалация пользователю со всей историей
  210: 5. **Skills-first** — подгрузить скилл из `.agents/skills/` ДО работы (skill tool); нет нужного → skill-surgeon
  211: 6. **MCP обязательно**: context7 для библиотек, sequential-thinking для >3 шагов, hermes-atlas для новых скиллов
  212: 7. **Self-report mandatory**: каждый агент пишет SKILLS_LOADED, MCP_USED, COMPLIANCE: true в CONTEXT-BUFFER.md
  213: 7. **Никаких секретов** — пароли, токены, ключи никогда в код или логи
  214: 8. **Перед сдачей** — обязательный прогон qa-engineer + code-reviewer + security-auditor
  215: 9. **PowerShell** — не использовать `&&` (сломано в Windows), использовать `;` для разделения команд
  216: 10. **CONTEXT-BUFFER.md** — перед задачей читать последние 30 строк, после — писать результат
  217: 11. **Мини-допрос** — при приёме задачи от пользователя: задать вопросы одним батчем (с вариантами ответов), зафиксировать в ТЗ, дальше работать молча до результата или blocker'а
  218: 
  219: ---
  220: 
  221: ## Рейтинг моделей
  222: 
  223: После каждой приёмки задачи тимлид записывает оценку в `.memory/ratings.jsonl`:
  224: 
  225: ```json
  226: {"model":"glm-5.3-free (mimo недоступен: квота opencode исчерпана)","agent":"dev-1","task_type":"feature","grade":8,"date":"2026-08-26"}
  227: ```
  228: 
  229: **Поля:** `model`, `agent`, `task_type` (feature/bugfix/refactor/doc), `grade` (1-10), `date`.
  230: 
  231: **Таблица лидеров:**
  232: 
  233: ```powershell
  234: .\.agents\scripts\model-leaderboard.ps1            # все записи
  235: .\.agents\scripts\model-leaderboard.ps1 -ByModel    # по моделям
  236: .\.agents\scripts\model-leaderboard.ps1 -ByAgent    # по агентам
  237: .\.agents\scripts\model-leaderboard.ps1 -ByTaskType # по типам задач
  238: ```
  239: 
  240: Тимлид сверяется с рейтингом перед делегированием — приоритет отдаётся агентам/моделям с лучшим score.
  241: 
  242: ---
  243: 
  244: ## Безопасность Windows
  245: 
  246: Скилл `.agents/skills/windows-safety/SKILL.md` **обязателен** перед любыми загрузками, установками и запуском чужих скриптов. Основные правила:
  247: 
  248: - PowerShell 5.1: нет `&&`/`||`, только `;` и `if ($LASTEXITCODE -eq 0) {...}`
  249: - Пути с кириллицей/пробелами — всегда в кавычках
  250: - Скачивание: только официальные релизы; после скачивания — `certutil -hashfile SHA256` и сверка
  251: - Бинарники — в `.agents\tools\` (в .gitignore), НЕ в корень репо
  252: - **Kaspersky-ложняки**: Bun-бинарники ловят `PDM:Trojan.Win32.Generic` → файл удалён АВ → НЕ переустанавливать молча, а доложить пользователю (тикет в ИБ на исключение папки `.agents\tools\`)
  253: 
  254: ---
  255: 
  256: ## Статус реализации
  257: 
  258: ### A. Инфраструктура ✅
  259: Git-репо, .gitignore, структура папок, **30 git worktrees** — всё на месте.
  260: 
  261: ### B. Конфигурация ✅
  262: **30 агентов** зарегистрированы в opencode.json. Dual-agent делегирование работает end-to-end.
  263: 
  264: ### C. Команды ✅
  265: `/status`, `/sync`, `/new-project`, `/cost-report`, `/team-report` — все протестированы.
  266: 
  267: ### D. Шина контекста и память ✅
  268: Memory Bank (5 файлов), CONTEXT-BUFFER.md, AGENTS.md, message-queue.ps1 — созданы и работают.
  269: 
  270: ### E. Кодовые фичи ✅
  271: - Distributed Tracing: tracer.js → traces.jsonl
  272: - Performance Scoring: scoring.js → performance.jsonl
  273: - Health Monitoring: health-check.ps1 — HEALTH: PASS
  274: - Session Recovery: session-recovery.ps1 — автовосстановление при lock conflict
  275: - Skills+MCP Enforcement: compliance-gate.ps1 в health-check
  276: - Context Compression: compaction opencode + summarization skill
  277: 
  278: ### F. Проверки и ревью ✅
  279: - verify-phase.ps1: 29/29 PASSED
  280: - Code review infra: APPROVED
  281: - Параллельный прогон агентов — работает
  282: 
  283: ### G. Inbox Poller ✅
  284: - inbox-poller.ps1: E2E тест PASS
  285: - Code review: APPROVED
  286: 
  287: ---
  288: 
  289: ## Эксперименты
  290: 
  291: | Эксперимент | Описание | Статус |
  292: |---|---|---|
  293: | **OmniRoute** | Шлюз-ротатор бесплатных моделей (350+ провайдеров, авто-fallback) | Ожидает ключей провайдеров |
  294: | **codebase-memory-mcp** | MCP-сервер для семантического поиска по кодовой базе | Пауза: Kaspersky блокирует |
  295: 
  296: ---
  297: 
  298: ## Плюсы
  299: 
  300: | Преимущество | Описание |
  301: |---|---|
  302: | **$0 стоимость** | Все модели бесплатные |
  303: | **Полная наблюдаемость** | Traces + performance + health-check + compliance |
  304: | **Самовосстановление** | Session recovery + retry protocol + escalation |
  305: | **Dual-Agent качество** | TL + PM вместе = лучшие requirements + architecture |
  306: | **Параллелизм** | 30 worktrees + task tool параллелизм |
  307: | **Память между сессиями** | Memory Bank (5 файлов) |
  308: | **Безопасность** | Read-only проверяющие, секреты запрещены |
  309: | **Автоматизация** | inbox-poller + session-recovery + scheduler |
  310: 
  311: ---
  312: 
  313: ## Минусы и ограничения
  314: 
  315: | Ограничение | Описание |
  316: |---|---|
  317: | Кэш конфига | После правки `.opencode/agents/*.json` нужно перезапускать opencode |
  318: | Нет фоновых демонов | inbox-poller / session-recovery работают вручную или по интервалу |
  319: | Кириллица в консоли | PowerShell 5.1 может отображать UTF-8 эмодзи кракозябрами |
  320: | nemotron-3-ultra-free | Проверяющие — fallback после ухода ox-alpha-free |
  321: 
  322: ---
  323: 
  324: ## Что можно добавить дальше
  325: 
  326: | Задача | Описание |
  327: |---|---|
  328: | Task Scheduler | Автоматическое назначение задач свободным агентам (registry-state.json + locks) |
  329: | Веб-дашборд | Визуализация performance.jsonl |
  330: | CI/CD | GitHub Actions с verify-phase.ps1 |
  331: | Buffer Archive | Архивация CONTEXT-BUFFER.md каждые 100 строк |
  332: | Project Isolation | create-project.ps1 создаёт worktree + назначает agents |
  333: 
  334: ---
  335: 
  336: ## Команда
  337: 
  338: Сгенерировано мультиагентной командой agent-hq.
  339: 
  340: **30 агентов** | **opencode** | **бесплатные модели** | **$0**
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 1-105

```markdown
    1: # REQUIREMENTS.md — Масштабирование до 5 параллельных проектов
    2: 
    3: > **Версия**: 2.0.0
    4: > **Дата**: 2026-09-07
    5: > **Автор**: Product Manager (Team Lead)
    6: > **Статус**: DRAFT
    7: 
    8: ---
    9: 
   10: ## Обзор проекта
   11: 
   12: agent-hqCurrently supports 2 concurrent projects (news-bot, pong-advanced) with a single shared context buffer. The goal is to scale to **5 simultaneous projects** without agent conflicts, context leaks, or idle agents. This requires a multi-tenant architecture where each project gets isolated context, memory, and agent allocation — while agents remain a shared pool with dynamic routing.
   13: 
   14: ---
   15: 
   16: ## Текущее состояние (AS-IS)
   17: 
   18: | Компонент | Состояние | Проблема |
   19: |-----------|-----------|----------|
   20: | Агенты | 19 агентов (10 base + 9 copies) в `opencode.json` | Copies существуют для параллельной работы, но нет mechanism для автоматического выделения |
   21: | Контекст | Один общий `CONTEXT-BUFFER.md` | Все проекты пишут в одну шину — конфликты, путаница |
   22: | Memory Bank | `.memory/` общий для всех | Контекст проекта A доступен агенту проекта B |
   23: | Projects | `opencode.json` → секция `projects` (2 проекта) | Нет изоляции, нет очереди, нет балансировки |
   24: | Workspace | `sandbox_per_agent: true`, `merge_strategy: git-branch` | Worktree-песочницы есть, но нет project-level изоляции |
   25: 
   26: ---
   27: 
   28: ## User Stories
   29: 
   30: ### US-011: Multi-Project Isolation — изоляция проектов
   31: 
   32: **Как** Team Lead,
   33: **я хочу** чтобы каждый из 5 проектов имел свою изолированную область (контекст, память, агенты),
   34: **чтобы** контекст одного проекта не утекал в другой и агенты разных проектов не конфликтовали.
   35: 
   36: **Acceptance Criteria:**
   37: 
   38: | # | Критерий | Проверяемость |
   39: |---|----------|---------------|
   40: | 11.1 | Каждый проект имеет свою папку `projects/{name}/` с `CONTEXT-BUFFER.md`, `KNOWLEDGE-BASE.md`, `memory/` | `ls projects/*/CONTEXT-BUFFER.md` — 5 файлов |
   41: | 11.2 | Агент проекта A не может читать/писать контекст проекта B | Попытка доступа к чужому контексту → permission denied или пустой результат |
   42: | 11.3 | Каждый проект имеет свой git worktree или ветку | `git worktree list` — 5 изолированных рабочих пространств |
   43: | 11.4 | Один агент может работать только в одном проекте одновременно | Мониторинг: нет дублирования agent ID в разных проектах |
   44: | 11.5 | Конфиг проекта (`project.json`) определяет его тип, агентов, приоритет | Файл существует и валиден для каждого из 5 проектов |
   45: 
   46: ---
   47: 
   48: ### US-012: Dynamic Agent Pool — пул агентов с балансировкой нагрузки
   49: 
   50: **Как** Team Lead,
   51: **я хочу** чтобы агенты распределялись между проектами динамически на основе нагрузки и потребностей,
   52: **чтобы** агенты не простаивали и не были заблокированы в одном проекте, когда другой нуждается в них.
   53: 
   54: **Acceptance Criteria:**
   55: 
   56: | # | Критерий | Проверяемость |
   57: |---|----------|---------------|
   58: | 12.1 | Существует `agent-registry.json` с текущим статусом каждого агента (free/busy/error) | `cat .memory/agent-registry.json` — JSON с 19 записями |
   59: | 12.2 | При назначении задачи агент выбирается из свободных по специализации | Лог: агент назначен, статус → busy |
   60: | 12.3 | После завершения задачи агент возвращается в пул (status → free) | Лог: агент освобождён |
   61: | 12.4 | Если все агенты нужной специализации заняты — задача ставится в очередь (не отбрасывается) | Задача в очереди с timestamp, не lost |
   62: | 12.5 | Load balancing: utilization > 80% при 5 проектах | Метрика из `agent-registry.json`: busy_count / total_count > 0.8 |
   63: 
   64: ---
   65: 
   66: ### US-013: Project Queue — очередь задач на проект с приоритетами
   67: 
   68: **Как** Team Lead,
   69: **я хочу** чтобы у каждого проекта была очередь задач с приоритетами (critical/high/normal/low),


---
Ответь только: `Принято 2/15`. Жди следующую часть.
