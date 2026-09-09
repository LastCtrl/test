# agent-hq

Система оркестрации команды из **30 ИИ-агентов** поверх opencode: team-lead + product-manager (dual-agent) декомпозируют задачи и делегируют 28 субагентам, всё на бесплатных моделях, с полной наблюдаемостью, самовосстановлением и параллельными worktree.

---

## Содержание

1. [Что это](#что-это)
2. [Архитектура](#архитектура)
3. [Как это работает](#как-это-работает)
4. [Быстрый старт](#быстрый-старт)
5. [Модели](#модели)
6. [MCP](#mcp)
7. [Правила эффективности](#правила-эффективности)
8. [Рейтинг моделей](#рейтинг-моделей)
9. [Безопасность Windows](#безопасность-windows)
10. [Статус реализации](#статус-реализации)
11. [Эксперименты](#эксперименты)
12. [Плюсы](#плюсы)
13. [Минусы и ограничения](#минусы-и-ограничения)
14. [Что можно добавить дальше](#что-можно-добавить-дальше)

---

## Что это

**agent-hq** — это мультиагентная система, построенная на [opencode](https://opencode.ai). **Dual-agent delegation**: team-lead + product-manager работают вместе на каждом запросе, декомпозируют задачу и параллельно делегируют 28 специализированным субагентам. Каждый агент работает в своём контексте (git worktree), пишет результаты в общую шину (CONTEXT-BUFFER.md), а проверяющие агенты (QA, code-reviewer, security-auditor) гарантируют качество перед финальным коммитом.

Все модели бесплатные. Стоимость: $0.

---

## Архитектура

### Карта репозитория

| Файл / Папка | Назначение |
|---|---|
| `FULL_PLAN.md` | Единый план проекта — источник истины. Все статусы, чек-листы, дорожная карта |
| `AGENTS.md` | Правила работы агентов: модели, роли, протокол, retry, команды |
| `CONTEXT-BUFFER.md` | Шина контекста — обмен сообщениями между агентами (последние 30 строк читаются перед задачей) |
| `opencode.json` | Главный конфиг: агенты, MCP context7, команды, модули, память, workspace |
| `.opencode/agents/*.json` | 30 конфигов агентов (name, model, permissions, prompt) |
| `.opencode/agents/prompts/*.txt` | 30 промптов агентов (подгружаются через `{file:...}`) |
| `.opencode/agents/registry.json` | Реестр агентов со specialization matrix + required_skills |
| `.opencode/plugins/tracer.js` | Плагин distributed tracing → traces.jsonl |
| `.opencode/plugins/scoring.js` | Плагин performance scoring → performance.jsonl |
| `.agents/scripts/` | 7 скриптов: sync-agents.ps1, verify-phase.ps1, health-check.ps1, message-queue.ps1, create-project.ps1, inbox-poller.ps1, session-recovery.ps1 |
| `.agents/skills/` | 24 скилла: 17 для 1С + 7 core + 4 superpowers (spec/plan/implement/test) |
| `.agents/tasks/` | Задачи для агентов (текстовые файлы) |
| `.agents/worktrees/` | **30 git worktrees** — изолированные песочницы для каждого агента |
| `.memory/` | Memory Bank: activeContext.md, progress.md, decisionLog.md, productContext.md, systemPatterns.md |
| `.memory/inbox/{agent}/` | Входящие задачи агенту (JSON) |
| `.memory/outbox/` | Результаты задач (JSON, status: done) |
| `.memory/dead-letter/` | Сообщения с ошибками |
| `.memory/archive/` | Архив сообщений старше 7 дней |
| `.memory/traces/` | Логи трейсинга |
| `.memory/reports/` | Отчёты (/team-report, /cost-report) |
| `projects/` | Директория проектов (test-project, news-bot, pong-advanced, 1СBuh) |

### Структура команды

```
Пользователь
    │
    ▼
Dual-Agent: Team Lead + Product Manager (параллельно через task tool)
    │
    ├── task tool → 28 субагентов (параллельно)
    │       │
    │       ├── Разработка: dev-1×2, dev-2×2, dev-3×2, frontend, backend×2, db-specialist, mobile-dev, devops, integration-specialist, data-engineer
    │       ├── Качество: qa-engineer×2, code-reviewer×2, security-auditor×2
    │       ├── Управление: product-manager, tech-writer×2, skill-surgeon
    │       └── Спец: legal-advisor, smm-strategist, team-lead×4
    │
    ├── CONTEXT-BUFFER.md (шина сообщений, self-report с SKILLS_LOADED/MCP_USED)
    ├── .memory/ (Memory Bank — контекст между сессиями)
    ├── .memory/inbox/{agent}/ (задачи агентам через файловые очереди)
    ├── .memory/outbox/ (результаты)
    ├── .agents/skills/ (24 скилла, подгружать перед работой — обязательно)
    ├── .agents/locks/ (файловые блокировки для scheduler'а)
    └── .agents/scripts/session-recovery.ps1 (автовосстановление при lock conflict)
```

---

## Как это работает

### Основной цикл (Dual-Agent Delegation)

```
1. Пользователь пишет задачу в TUI opencode (build/plan режим)
2. Primary agent запускает ПАРАЛЛЕЛЬНО:
   task "Analyze requirements: <task>" subagent_type=product-manager
   task "Create orchestration plan: <task>" subagent_type=team-lead
3. product-manager выдаёт: User Stories, Acceptance Criteria, MoSCoW, NFR, Stack
4. team-lead выдаёт: Architecture, Tech Stack, Delegation Plan, Risks
5. Оба читают вывод друг друга в CONTEXT-BUFFER.md → синхронизация
6. team-lead параллельно делегирует исполнителей через task tool:
   task "Create UI: ..." subagent_type=frontend
   task "Create API: ..." subagent_type=backend
   task "Design DB: ..." subagent_type=db-specialist
   ...
7. Каждый агент в своём worktree:
   a. Читает последние 30 строк CONTEXT-BUFFER.md
   b. ОБЯЗАТЕЛЬНО: skill <нужные-скиллы> → context7 (библиотеки) → sequential-thinking (>3 шага)
   c. Выполняет задачу
   d. Пишет self-report в CONTEXT-BUFFER.md (SKILLS_LOADED, MCP_USED, COMPLIANCE: true)
8. Проверяющие агенты (параллельно):
    - qa-engineer: тесты, edge cases
    - code-reviewer: ревью кода (read-only)
    - security-auditor: безопасность (read-only)
9. Финальный коммит + PR
```

### Auto-Recovery (Session Recovery)

При конфликте файловых блокировок (`Busy: FileSystem.writeFile ... info/exclude`):

```
1. session-recovery.ps1 (фоновый демон) обнаруживает lock conflict в трейсах
2. Находит свободную копию team-lead (team-lead-1/2/3)
3. Создаёт задачу в inbox свободной копии с флагом recovery=true
4. Записывает в CONTEXT-BUFFER.md: auto-recovery delegation
5. Новая сессия поднимается на копии → продолжает работу
```

### Inbox Poller (автозапуск воркеров)

`inbox-poller.ps1` — мониторит `.memory/inbox/{agent}/*.json` и автоматически запускает агентов:

| Флаг | Описание |
|---|---|
| `-Once` | Однократный прогон (проверить и выйти) |
| `-IntervalSeconds N` | Интервал проверки в секундах (по умолчанию 30) |
| `-DryRun` | Без реального запуска агентов (только проверка логики) |

---

## Быстрый старт

```bash
cd D:\Тест\agent-hq
opencode
```

### Примеры использования

**Обычная задача (dual-agent запустится автоматически):**
```
Создай функцию slugify в src/utils/string-utils.js, которая превращает строку в URL-friendly вид.
```

**Обращение к конкретному агенту:**
```
@frontend Сделай адаптивную версию карточки товара.
```

**Команды:**
```
/status          — статус системы (health-check + verify-phase)
/sync            — синхронизация контекста из Memory Bank + registry
/new-project     — создать новый проект из шаблона (create-project.ps1)
/cost-report     — отчёт по стоимости (все модели бесплатные)
/team-report     — отчёт по работе команды
```

### После правки конфигов

```powershell
.\.agents\scripts\sync-agents.ps1
# Перезапустить opencode (кэш конфига обновляется только при старте)
```

---

## Модели

| Модель | Роль | Скорость | Используется |
|---|---|---|---|
| `tokenrouter/z-ai/glm-5.3-free` | Основная (качество, русский) | 5-6 сек | dev-1, dev-3, frontend, legal-advisor, product-manager, skill-surgeon, smm-strategist, team-lead, tech-writer, team-lead-1/2/3, dev-1-1, dev-2-1, dev-3-1, backend-1, qa-engineer-1, security-auditor-1, code-reviewer-1, tech-writer-1 |
| `opencode/nemotron-3.5-lightning-free` | Быстрая (рутина) | 3-4 сек | backend, data-engineer, db-specialist, dev-2, devops, integration-specialist, mobile-dev, dev-2-1 |
| `opencode/nemotron-3-ultra-free` | Запасная (глубокий анализ) | 7-8 сек | резервная / escalation |

**Запрещены** (нет в подписке): kimi-k2.x, glm-5.x, deepseek-v4-pro/flash, qwen-plus, minimax-m2.x/m3

> Платные модели запрещены. Стоимость всегда $0.

---

## MCP

Три сервера подключены в проектном `opencode.json` (секция `mcp`), доступны всем агентам автоматически:

| Сервер | Назначение |
|--------|-----------|
| **context7** | Актуальная документация библиотек в реальном времени: свежие API, примеры, миграции |
| **hermes-atlas-mcp** | Каталог 100+ скиллов/тулов экосистемы Hermes Atlas — поиск и установка готовых скиллов |
| **sequential-thinking** | Структурированное пошаговое планирование сложных задач (>3 шага) |

---

## Правила эффективности

1. **Dual-Agent: Team Lead + Product Manager** — на КАЖДОМ запросе запускаются вместе параллельно
2. **Team Lead не пишет код** — только конфиги, документация, правки 1-2 строк
3. **Независимые задачи — строго параллельно** — один вызов task = несколько агентов одновременно
4. **Правило лимит-3**: попытки 1-2 тем же агентом (полный лог ошибок + путь к скиллу в ТЗ); попытка 3 — другой агент + более сильная модель (lightning → mimo → ultra); после третьей неудачи — эскалация пользователю со всей историей
5. **Skills-first** — подгрузить скилл из `.agents/skills/` ДО работы (skill tool); нет нужного → skill-surgeon
6. **MCP обязательно**: context7 для библиотек, sequential-thinking для >3 шагов, hermes-atlas для новых скиллов
7. **Self-report mandatory**: каждый агент пишет SKILLS_LOADED, MCP_USED, COMPLIANCE: true в CONTEXT-BUFFER.md
7. **Никаких секретов** — пароли, токены, ключи никогда в код или логи
8. **Перед сдачей** — обязательный прогон qa-engineer + code-reviewer + security-auditor
9. **PowerShell** — не использовать `&&` (сломано в Windows), использовать `;` для разделения команд
10. **CONTEXT-BUFFER.md** — перед задачей читать последние 30 строк, после — писать результат
11. **Мини-допрос** — при приёме задачи от пользователя: задать вопросы одним батчем (с вариантами ответов), зафиксировать в ТЗ, дальше работать молча до результата или blocker'а

---

## Рейтинг моделей

После каждой приёмки задачи тимлид записывает оценку в `.memory/ratings.jsonl`:

```json
{"model":"glm-5.3-free (mimo недоступен: квота opencode исчерпана)","agent":"dev-1","task_type":"feature","grade":8,"date":"2026-08-26"}
```

**Поля:** `model`, `agent`, `task_type` (feature/bugfix/refactor/doc), `grade` (1-10), `date`.

**Таблица лидеров:**

```powershell
.\.agents\scripts\model-leaderboard.ps1            # все записи
.\.agents\scripts\model-leaderboard.ps1 -ByModel    # по моделям
.\.agents\scripts\model-leaderboard.ps1 -ByAgent    # по агентам
.\.agents\scripts\model-leaderboard.ps1 -ByTaskType # по типам задач
```

Тимлид сверяется с рейтингом перед делегированием — приоритет отдаётся агентам/моделям с лучшим score.

---

## Безопасность Windows

Скилл `.agents/skills/windows-safety/SKILL.md` **обязателен** перед любыми загрузками, установками и запуском чужих скриптов. Основные правила:

- PowerShell 5.1: нет `&&`/`||`, только `;` и `if ($LASTEXITCODE -eq 0) {...}`
- Пути с кириллицей/пробелами — всегда в кавычках
- Скачивание: только официальные релизы; после скачивания — `certutil -hashfile SHA256` и сверка
- Бинарники — в `.agents\tools\` (в .gitignore), НЕ в корень репо
- **Kaspersky-ложняки**: Bun-бинарники ловят `PDM:Trojan.Win32.Generic` → файл удалён АВ → НЕ переустанавливать молча, а доложить пользователю (тикет в ИБ на исключение папки `.agents\tools\`)

---

## Статус реализации

### A. Инфраструктура ✅
Git-репо, .gitignore, структура папок, **30 git worktrees** — всё на месте.

### B. Конфигурация ✅
**30 агентов** зарегистрированы в opencode.json. Dual-agent делегирование работает end-to-end.

### C. Команды ✅
`/status`, `/sync`, `/new-project`, `/cost-report`, `/team-report` — все протестированы.

### D. Шина контекста и память ✅
Memory Bank (5 файлов), CONTEXT-BUFFER.md, AGENTS.md, message-queue.ps1 — созданы и работают.

### E. Кодовые фичи ✅
- Distributed Tracing: tracer.js → traces.jsonl
- Performance Scoring: scoring.js → performance.jsonl
- Health Monitoring: health-check.ps1 — HEALTH: PASS
- Session Recovery: session-recovery.ps1 — автовосстановление при lock conflict
- Skills+MCP Enforcement: compliance-gate.ps1 в health-check
- Context Compression: compaction opencode + summarization skill

### F. Проверки и ревью ✅
- verify-phase.ps1: 29/29 PASSED
- Code review infra: APPROVED
- Параллельный прогон агентов — работает

### G. Inbox Poller ✅
- inbox-poller.ps1: E2E тест PASS
- Code review: APPROVED

---

## Эксперименты

| Эксперимент | Описание | Статус |
|---|---|---|
| **OmniRoute** | Шлюз-ротатор бесплатных моделей (350+ провайдеров, авто-fallback) | Ожидает ключей провайдеров |
| **codebase-memory-mcp** | MCP-сервер для семантического поиска по кодовой базе | Пауза: Kaspersky блокирует |

---

## Плюсы

| Преимущество | Описание |
|---|---|
| **$0 стоимость** | Все модели бесплатные |
| **Полная наблюдаемость** | Traces + performance + health-check + compliance |
| **Самовосстановление** | Session recovery + retry protocol + escalation |
| **Dual-Agent качество** | TL + PM вместе = лучшие requirements + architecture |
| **Параллелизм** | 30 worktrees + task tool параллелизм |
| **Память между сессиями** | Memory Bank (5 файлов) |
| **Безопасность** | Read-only проверяющие, секреты запрещены |
| **Автоматизация** | inbox-poller + session-recovery + scheduler |

---

## Минусы и ограничения

| Ограничение | Описание |
|---|---|
| Кэш конфига | После правки `.opencode/agents/*.json` нужно перезапускать opencode |
| Нет фоновых демонов | inbox-poller / session-recovery работают вручную или по интервалу |
| Кириллица в консоли | PowerShell 5.1 может отображать UTF-8 эмодзи кракозябрами |
| nemotron-3-ultra-free | Проверяющие — fallback после ухода ox-alpha-free |

---

## Что можно добавить дальше

| Задача | Описание |
|---|---|
| Task Scheduler | Автоматическое назначение задач свободным агентам (registry-state.json + locks) |
| Веб-дашборд | Визуализация performance.jsonl |
| CI/CD | GitHub Actions с verify-phase.ps1 |
| Buffer Archive | Архивация CONTEXT-BUFFER.md каждые 100 строк |
| Project Isolation | create-project.ps1 создаёт worktree + назначает agents |

---

## Команда

Сгенерировано мультиагентной командой agent-hq.

**30 агентов** | **opencode** | **бесплатные модели** | **$0**

---

**GitHub PR:** https://github.com/LastCtrl/test/pull/new/feature/skills-mcp-enforcement