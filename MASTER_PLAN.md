# MASTER_PLAN.md — производный от FULL_PLAN.md (источник истины)

## Последнее обновление: 2026-08-25

---

## Статус этапов

### Этап 1: Foundation — ГОТОВО
- [x] Git-версионирование: .git, .gitignore, .agents и .memory в git
- [x] Agent Communication Protocol: inbox/outbox JSON, message-queue.ps1
- [x] Sandbox через git worktree: .agents/worktrees/
- [x] Memory Bank: 5 файлов (activeContext, decisionLog, productContext, progress, systemPatterns)
- [x] Единые пути workspace: пути заданы в opencode.json
- [x] Skills-first правило: model-router, memory-search, summarization
- [x] Tool priority: приоритет инструментов задан
- [x] Model Router skill: скилл создан
- [x] Единый конфиг: opencode.json с флагами модулей

### Этап 2: Core Logic — ГОТОВО
- [x] Registry.json: 19 агентов с specialization matrix (`.opencode/agents/registry.json`)
- [x] JSON-конфиги агентов: 19 файлов в `.opencode/agents/*.json`
- [x] Промпты агентов: 19 .txt файлов в `.opencode/agents/prompts/`
- [x] Команды team-lead: /sync, /status, /new-project, /cost-report, /team-report — все определены в `opencode.json`

### Этап 3: Intelligence — ГОТОВО
- [x] Context Compression: `memory.compression.enabled=true`, strategy=summary+archive + скилл summarization
- [x] Specialization Matrix: есть в registry.json
- [x] Умная шина: keyword search по .memory/ доступен

### Этап 4: Production — ГОТОВО
- [x] Шаблоны проектов: `create-project.ps1` (`.agents/scripts/`) — создан и протестирован
- [x] Health-monitoring: `health-check.ps1` — работает (traces-ошибки за час, inbox backlog, worktree, avg duration, disk)
- [x] Distributed Tracing: `.opencode/plugins/tracer.js` → `traces.jsonl` (tool-спаны, session lifecycle)
- [x] Performance Scoring: `.opencode/plugins/scoring.js` → `performance.jsonl` (29+ сессий)
- [x] Inbox Poller: `.agents/scripts/inbox-poller.ps1` — E2E 9/9 PASS, code review APPROVED

### Этап 5: Advanced — ГОТОВО
- [x] Self-Healing: протокол retry в AGENTS.md + fallback-маппинг в `.agents/skills/model-router/SKILL.md`
- [x] Performance Scoring: scoring.js → performance.jsonl (живые данные)
- [x] Плагин-система: 2 плагина — tracer.js + scoring.js
- [x] Best practices: README.md (295 строк), AGENTS.md, полная документация

---

## Файловая структура (актуальная)

```
D:\Тест\agent-hq\
├── opencode.json                        # Главный конфиг (агенты, MCP, модули, команды)
├── MASTER_PLAN.md                       # Этот файл
├── FULL_PLAN.md                         # Источник истины (детали и история)
├── AGENTS.md                            # Правила работы агентов
├── CONTEXT-BUFFER.md                    # Шина агентов
├── README.md                            # Документация проекта
├── KNOWLEDGE-BASE.md                    # База знаний
├── .gitignore
├── .opencode/
│   ├── agents/
│   │   ├── registry.json                # Реестр 19 агентов
│   │   ├── backend.json                 # JSON-конфиги (19 штук)
│   │   ├── code-reviewer.json
│   │   ├── dev-1.json
│   │   ├── ... (ещё 16 агентов)
│   │   └── prompts/                     # Промпты агентов (19 .txt файлов)
│   │       ├── backend.txt
│   │       ├── code-reviewer.txt
│   │       ├── dev-1.txt
│   │       └── ... (ещё 16 файлов)
│   ├── plugins/
│   │   ├── tracer.js                    # Distributed tracing → traces.jsonl
│   │   └── scoring.js                   # Performance scoring → performance.jsonl
│   └── node_modules/                    # npm-зависимости
├── .agents/
│   ├── scripts/
│   │   ├── create-project.ps1           # Шаблоны проектов
│   │   ├── health-check.ps1             # Мониторинг здоровья
│   │   ├── inbox-poller.ps1             # Автообработка входящих сообщений
│   │   ├── message-queue.ps1            # Очередь сообщений
│   │   ├── sync-agents.ps1              # Синхронизация агентов
│   │   └── verify-phase.ps1             # Верификация этапов (29/29 PASSED)
│   ├── skills/
│   │   ├── memory-search/SKILL.md
│   │   ├── model-router/SKILL.md
│   │   ├── performance-scoring/SKILL.md
│   │   ├── plugin-system/SKILL.md
│   │   ├── self-healing/SKILL.md
│   │   └── summarization/SKILL.md
│   └── worktrees/
│       └── dev-1/                       # Git worktree для dev-1
├── .memory/
│   ├── activeContext.md
│   ├── decisionLog.md
│   ├── productContext.md
│   ├── progress.md
│   ├── systemPatterns.md
│   ├── inbox/                           # Входящие сообщения агентов
│   ├── outbox/                          # Исходящие сообщения
│   ├── dead-letter/                     # Необработанные сообщения
│   ├── archive/                         # Архив сообщений (>7 дней)
│   ├── reports/                         # Отчёты (/team-report и др.)
│   └── traces/
│       ├── traces.jsonl                 # Distributed tracing (живые данные)
│       ├── performance.jsonl            # Performance scoring (29+ сессий)
│       └── poller.log                   # Лог inbox-poller
└── projects/                            # Проекты, созданные через create-project.ps1
```

---

## Оставшиеся шаги

### 1. Worktree-песочницы другим агентам (по потребности)
Git worktree для dev-1 уже создан. Остальные агенты могут получить песочницы по запросу:
```bash
git worktree add .agents/worktrees/<agent-name> -b agent/<agent-name>
```

### 2. Автозапуск inbox-poller через Task Scheduler
Команда для регистрации (выполняется в PowerShell от администратора):
```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"D:\Тест\agent-hq\.agents\scripts\inbox-poller.ps1`" -Base `"D:\Тест\agent-hq`" -Once"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "agent-hq-inbox-poller" -Action $action -Trigger $trigger -Description "Auto-poll inbox for agent-hq"
```

### 3. Опционально: CI GitHub Actions с verify-phase
```yaml
# .github/workflows/verify.yml
- name: Verify phases
  run: powershell -File .agents/scripts/verify-phase.ps1
```

---

## Ссылки
- **Детали и история**: `FULL_PLAN.md`
- **Шина агентов**: `CONTEXT-BUFFER.md`
- **Правила работы**: `AGENTS.md`
- **Документация**: `README.md`
