# FULL_PLAN.md — Единый план системы agent-hq (источник истины)

> Этот файл — единственный полный план. MASTER_PLAN.md и progress.md — производные.
> Статусы: ✅ реально работает | ⚠️ частично | ❌ не сделано
> Последняя проверка: 2026-08-24

---

## 1. Источники требований

| Источник | Что взято |
|----------|-----------|
| `agent-team/AGENTS.md` | Workflow team-lead, iron rules, retry-протокол, параллельность |
| `agent-team/CONTEXT-BUFFER.md` | Формат шины, история задач (news-bot, lk-fl) |
| `agent-team/KNOWLEDGE-BASE.md` | Архитектура news-bot, ADR, паттерны багфикса |
| `agent-team/.opencode/agents/*.md` | 19 промптов агентов |
| Требования пользователя | Только бесплатные модели; inbox/outbox; git worktree; Memory Bank; работа в одном окне с видимостью агентов |

## 2. Модели (только бесплатные)

| Модель | Роль | Скорость |
|--------|------|----------|
| `opencode/mimo-v2.5-free` | Основная (качество, русский) | 5-6 сек |
| `opencode/nemotron-3.5-lightning-free` | Быстрая (рутина) | 3-4 сек |
| `opencode/nemotron-3-ultra-free` | Запасная (глубокий анализ) | 7-8 сек |
| `opencode-go/ox-alpha-free` | Все проверяющие (qa/review/security) — пока бесплатна | — |

Запрещены (нет в подписке): kimi-k2.x, glm-5.x, deepseek-v4-pro/flash, qwen-plus, minimax-m2.x/m3

## 3. Архитектура

```
Пользователь → Team Lead (build-агент в opencode TUI)
    │
    ├── task tool → субагенты (19 шт., параллельно)
    │       каждый читает CONTEXT-BUFFER.md (посл. 30 строк)
    │       каждый пишет результат обратно в шину
    │
    ├── .memory/ — Memory Bank (контекст между сессиями)
    ├── .memory/inbox/{agent}/ — задачи агенту (JSON)
    ├── .memory/outbox/ — результаты (JSON, status: done)
    ├── .agents/worktrees/{agent}/ — git worktree песочницы
    └── .agents/skills/ — скиллы (подгружать перед работой)
```

## 4. Команда (19 агентов)

Управление: product-manager, tech-writer, skill-surgeon
Разработка: dev-1, dev-2, dev-3, frontend, backend, db-specialist, mobile-dev, devops, integration-specialist, data-engineer
Качество: qa-engineer, security-auditor (read-only), code-reviewer (read-only)
Спец: team-lead, legal-advisor (РБ), smm-strategist

База данных агентов: `.opencode/agents/*.json` (name, model, mode, temperature, permissions, prompt)
Синхронизация в конфиг: `.agents/scripts/sync-agents.ps1` → секция `"agent"` в opencode.json + промпты в `.opencode/agents/prompts/*.txt`

## 5. Iron Rules (из AGENTS.md)

1. Team Lead НЕ пишет код сам — только конфиги/доки/правки 1-2 строк
2. Независимые задачи — ВСЕГДА параллельно (один вызов = несколько task)
3. Retry: максимум 2 попытки на агента → откат → другой агент сильнее → эскалация пользователю
4. Каждый агент перед работой читает посл. 30 строк CONTEXT-BUFFER.md и пишет результат туда
5. Skills-first: подгрузить нужный скилл ДО работы; нет скилла → skill-surgeon
6. Никаких секретов в коде/логах
7. Перед сдачей: code-reviewer + security-auditor
8. Долгие процессы — в отдельном окне PowerShell

## 6. Чек-лист реализации (честный статус)

### A. Инфраструктура
- [x] ✅ Git-репо + remote GitHub (LastCtrl/test), коммиты от LastCtrl
- [x] ✅ .gitignore
- [x] ✅ Структура папок (.memory, inbox/outbox/dead-letter/traces/archive, worktrees, skills, scripts, projects)
- [x] ✅ Git worktree dev-1 (создан через git worktree add)

### B. Конфигурация
- [x] ✅ Глобальный конфиг починен (была несуществующая модель deepseek-v4-flash-free → mimo/lightning)
- [x] ✅ opencode.json: команды, модули, workspace, projects
- [x] ✅ registry.json: 19 агентов со specialization matrix
- [x] ✅ sync-agents.ps1: JSON база → секция "agent" в opencode.json (+промпты .txt)
- [x] ✅ 19 агентов загружаются opencode (проверено debug config)
- [x] ✅ Делегирование работает end-to-end: build → task → subagent → ответ

### C. Команды
- [x] ✅ /status — статус системы (протестирован)
- [x] ✅ /sync — реальный прогон выполнен 2026-08-24 (activeContext/progress/decisionLog обновлены)
- [x] ✅ /new-project → create-project.ps1 (full-stack/api-only/mobile/data-pipeline, протестирован)
- [x] ✅ /cost-report — читает реальные данные из трейсов (плагины пишут)
- [x] ✅ /team-report — первый отчёт сгенерирован: .memory/reports/team-report-2026-08-24.md

### D. Шина контекста и память
- [x] ✅ Memory Bank: 5 файлов с реальным контентом из CONTEXT-BUFFER/KNOWLEDGE-BASE
- [x] ✅ CONTEXT-BUFFER.md в agent-hq (создан tech-writer'ом, записи раунда внесены)
- [x] ✅ AGENTS.md в agent-hq (правила сессий, создан tech-writer'ом)
- [x] ✅ message-queue.ps1 (inbox/outbox/dead-letter CLI)

### E. Кодовые фичи (реальные, не флаги)
- [x] ✅ Distributed Tracing: плагин tracer.js — tool-спаны + session события → traces.jsonl (живые данные)
- [x] ✅ Performance Scoring: плагин scoring.js — score/duration сессий → performance.jsonl (3 сессии записано)
- [x] ✅ Health Monitoring: health-check.ps1 — HEALTH: PASS (ошибки/backlog/worktrees/диск)
- [x] ✅ Self-Healing протокол: правила в AGENTS.md + fallback-маппинг в model-router
- [x] ✅ Context Compression: встроенная compaction opencode (auto=true) + summarization skill

### F. Проверки и ревью
- [x] ✅ verify-phase.ps1 — 29/29 PASSED (18 старых + 11 новых от qa-engineer)
- [x] ✅ Code review infra: APPROVED 7/10, 3 замечания исправлены и перепроверены
- [x] ✅ Параллельный прогон 3 агентов через Start-Job (tech-writer+dev-1+devops) и 2 агентов (qa+reviewer) — работает

### G. Inbox Poller (автозапуск воркеров)
- [x] ✅ inbox-poller.ps1: мониторинг .memory/inbox/{agent}/*.json, вызов opencode run --agent, outbox/archive/dead-letter
- [x] ✅ E2E тест: 9/9 PASS, status:"done" (String, не Boolean), архивация корректна
- [x] ✅ Code review: APPROVED 8/10, 0 критических, 10/10 исправлений

## 7. Дорожная карта остатка (этот сеанс)

| # | Задача | Кто |
|---|--------|-----|
| 1 | CONTEXT-BUFFER.md + AGENTS.md в agent-hq | tech-writer (CLI-делегация) |
| 2 | Плагины tracer.js + scoring.js | dev-1 (CLI-делегация) |
| 3 | health-check.ps1 | devops (CLI-делегация) |
| 4 | Параллельный тест 3 агентов | team-lead |
| 5 | Обновить verify-phase.ps1 (+новые проверки) | qa-engineer |
| 6 | Ревью изменений | code-reviewer |
| 7 | Коммит + push | team-lead |

## 8. Известные ограничения

1. Сессия ассистента кэширует глобальный конфиг при старте — после правки конфигов новые субагенты подхватываются только свежими процессами (CLI/TUI перезапуск)
2. ~~Task tool самой сессии принимает только built-in типы~~ СНЯТО 2026-08-24 (ADR-010): все 19 именованных агентов доступны через task tool напрямую
3. PowerShell: оператор `&&` сломан — использовать `;`
4. Кириллица в путях: консоль может отображать кракозябры, файлы при этом корректны (UTF-8 no BOM)
5. message-queue.ps1: archive чистит только outbox; inbox-файлы архивируются вручную в .memory/archive/ (сделано 2026-08-24, backlog 12 → 0)
6. ~~Автозапуск inbox-воркеров нет~~ ЗАКРЫТО 2026-08-24: inbox-poller.ps1 создан, E2E тест 9/9 PASS, code review APPROVED
7. Cost dashboard в $ неактивен по дизайну — все модели бесплатны ($0); активируется сам при появлении платных

## 9. Долги из прошлых сессий (закрыты 2026-08-25)

Долги найдены археологией по старым сессиям/докам (explore) и закрыты:

1. ✅ MCP-пакет: context7 + hermes-atlas-mcp (каталог скиллов Hermes Atlas/Nous Research) + sequential-thinking подключены в opencode.json; fetch не нужен (встроенный webfetch)
2. ✅ MASTER_PLAN.md устарел (17 агентов, ложные [ ]) — перегенерирован tech-writer'ом, 25/25 пунктов сверены с реальностью
3. ✅ Мусор в корне удалён: test-param.ps1, test-simple.ps1, test-structure.txt, opencode.json.bak; run-poller.ps1 → .agents/scripts/; mcp-addition-report → .memory/reports/
4. ✅ Правило приёмки в AGENTS.md §7: «Готово» только после независимой qa/review приёмки
5. ⏳ Автозапуск poller через Task Scheduler — команда для ручной активации:
   schtasks /Create /TN "agent-hq-poller" /SC MINUTE /MO 5 /TR "powershell -NoProfile -ExecutionPolicy Bypass -File D:\Тест\agent-hq\.agents\scripts\inbox-poller.ps1 -Once"
   (не зарегистрирован — требует решения пользователя о фоновом процессе)
6. ⏳ Worktree-песочницы остальным агентам — выдаются по потребности: git worktree add .agents\worktrees\{имя} -b agent/{имя}
7. ⏳ CI GitHub Actions с прогоном verify-phase на push — кандидат в следующую сессию
8. ✅ Рейтинг моделей внедрён (`.memory/ratings.jsonl` + `.agents/scripts/model-leaderboard.ps1`)
