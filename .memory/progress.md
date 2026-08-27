# Progress — Отслеживание прогресса

## Фазы и статус

### Этап 1: Foundation (7 ч) — ✅ Готово
- [x] 2.5 Git-версионирование
- [x] 0 Agent Communication Protocol
- [x] 0.5 Sandbox через git worktree
- [x] 1 Memory Bank — 5 файлов
- [x] 4 Единые пути workspace
- [x] 3 Skills-first правило
- [x] 5 Tool priority
- [x] 7 Model Router skill
- [x] 14 Единый конфиг

### Этап 2: Core Logic (3 ч) — ✅ Готово
- [x] 6 Registry.json
- [x] 2 JSON-формат промптов — 19 агентов
- [x] 11 Команды team-lead

### Этап 3: Intelligence (4 ч) — ✅ Готово
- [x] 1.5 Context Compression
- [x] 6.5 Specialization Matrix
- [x] 10 Умная шина контекста

### Этап 4: Production (6 ч) — ✅ Готово
- [x] 8 Шаблоны проектов — create-project.ps1
- [x] 13 Health-monitoring
- [x] 10.5 Distributed Tracing
- [x] 12 Дашборд стоимости — cost-report обновлён

### Этап 5: Advanced (2.5 ч) — ✅ Готово
- [x] 7.5 Cost-Aware Routing — model-router обновлён
- [x] 13.5 Self-Healing — protocol создан
- [x] 15.5 Performance Scoring — protocol создан
- [x] 9 Плагин-система — plugin-system создан
- [x] 15 Best practices — в документации агентов

## Все фазы выполнены 🎉

## 21.08.2026 — MVP
- MVP: структура, opencode.json, registry.json, 3 скилла, message-queue
- Фазы 0-15: git, Memory Bank, 19 JSON-конфигов, create-project.ps1, все модули
- Верификация: verify-phase.ps1 — 19/19 PASSED
- Git: remote GitHub (LastCtrl/test), SSH настроен
- Итого: 10 скиллов, 19 агентов, 5 команд, все модули включены

## 24.08.2026 — /sync + /team-report
- verify-phase.ps1: 29/29 PASSED (18 старых + 11 новых от qa-engineer)
- health-check.ps1: HEALTH: PASS
- /sync: закрыт — activeContext.md, progress.md, decisionLog.md синхронизированы
- /team-report: закрыт — отчёт в .memory/reports/team-report-2026-08-24.md
- Остаток: коммит + push (задача #7 из FULL_PLAN)

## 27.08.2026 — Переключение моделей проверяющих + протокол §3.1-3.3
- opencode-go/ox-alpha-free упал ("Model not found") — проверяющие (qa-engineer, code-reviewer, security-auditor) переведены на opencode/nemotron-3-ultra-free
- 21 замена в 14 файлах (.opencode/agents/*.json source, opencode.json, .agents/cards/*.json + index.json, AGENTS.md §1, README.md, FULL_PLAN.md, IMPROVEMENTS.md)
- AGENTS.md §3 расширен: §3.1 Оценка времени (5/10/15/20/30/45 мин для агента), §3.2 x2 timeout (передача другому агенту на более сильной модели без 2-й попытки), §3.3 Верификация НЕ тимлидом (qa-engineer/code-reviewer)
- cleanup-garbage.ps1 создан (dev-3, оценка 10 мин): автоочистка temp_*/bak/stray root agent JSON, -DryRun (по умолчанию)/-Execute, идемпотентен
- Рестарт opencode выполнен (конфиг не hot-reload — скилл customize-opencode)
- /sync прогнан пост-рестарт: sync-agents.ps1 обновил секцию agent (19 агентов); activeContext.md, progress.md, decisionLog.md перегенерированы из CONTEXT-BUFFER.md + KNOWLEDGE-BASE.md
- PENDING: 16 stray root agent JSON + prompts/ (byte-identical дубликаты). Баг cleanup-garbage.ps1:94 (хардкод 3 имён проверяющих). Задача — делегировать dev-3 на nemotron-ultra (оценка 15 мин): трассировка источника + правка детекта ВСЕХ stray root agent JSON + удаление 16 копий + прогон -DryRun
