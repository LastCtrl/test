# MASTER_PLAN.md — Статус проекта agent-hq

## Дата создания: 2026-08-21
## Последнее обновление: 2026-08-21

## Модели (только бесплатные)
| Модель | Роль | Скорость |
|--------|------|----------|
| opencode/mimo-v2.5-free | Основная,高质量 | 5-6 сек |
| opencode/nemotron-3.5-lightning-free | Быстрая, рутина | 3-4 сек |
| opencode/nemotron-3-ultra-free | Запасная, глубокий анализ | 7-8 сек |

## Этапы и фазы

### Этап 1: Foundation (7 ч) ✅ Готово
- [x] **2.5** Git-версионирование: .git/, .gitignore, .agents/ и .memory/ в git
- [x] **0** Agent Communication Protocol: inbox/outbox JSON, message-queue.ps1
- [x] **0.5** Sandbox через git worktree: .agents/worktrees/
- [x] **1** Memory Bank: 5 файлов (activeContext, decisionLog, productContext, progress, systemPatterns)
- [x] **4** Единые пути workspace: пути заданы в opencode.json
- [x] **3** Skills-first правило: model-router, memory-search, summarization
- [x] **5** Tool priority: приоритет инструментов задан
- [x] **7** Model Router skill: скилл создан
- [x] **14** Единый конфиг: opencode.json с флагами модулей

### Этап 2: Core Logic (3 ч) ✅ Готово
- [x] **6** Registry.json: 17 агентов с specialization matrix
- [x] **2** JSON-формат промптов: 19 JSON-конфигов агентов
- [x] **11** Команды team-lead: /sync, /status, /new-project, /cost-report, /team-report

### Этап 3: Intelligence (4 ч) ⏳ Частично
- [ ] **1.5** Context Compression: флаг false → включить
- [x] **6.5** Specialization Matrix: есть в registry.json
- [x] **10** Умная шина: keyword search по .memory/ доступен

### Этап 4: Production (6 ч) ⏳ Не начат
- [ ] **8** Шаблоны проектов: скрипт create-project.ps1
- [x] **13** Health-monitoring: базовая работа (health_monitoring: true)
- [ ] **10.5** Distributed Tracing: флаг false → включить
- [ ] **12** Дашборд стоимости: показывать бесплатные модели

### Этап 5: Advanced (2.5 ч) ⏳ Не начат
- [ ] **7.5** Cost-Aware Routing: флаг false
- [ ] **13.5** Self-Healing: не реализован
- [ ] **15.5** Performance Scoring: не реализован
- [ ] **9** Плагин-система: не начата
- [ ] **15** Best practices: добавлены в документацию

## Файловая структура
```
D:\Тест\agent-hq\
├── opencode.json                    # Главный конфиг
├── MASTER_PLAN.md                   # Этот файл
├── .gitignore                       # Игнорируемые файлы
├── test-structure.txt               # Тестовый файл (удалить после проверки)
├── .opencode/
│   └── agents/
│       ├── registry.json            # Реестр 17 агентов
│       ├── backend.json             # JSON-конфиг backend
│       ├── dev-1.json               # JSON-конфиг dev-1
│       └── ... (19 файлов)
├── .agents/
│   ├── skills/
│   │   ├── model-router/SKILL.md
│   │   ├── memory-search/SKILL.md
│   │   └── summarization/SKILL.md
│   ├── scripts/
│   │   ├── message-queue.ps1
│   │   └── verify-phase.ps1
│   └── worktrees/
│       └── dev-1/                   # Git worktree для dev-1
└── .memory/
    ├── activeContext.md
    ├── decisionLog.md
    ├── productContext.md
    ├── progress.md
    ├── systemPatterns.md
    ├── inbox/
    │   ├── dev-1/
    │   │   ├── task-001.json
    │   │   ├── task-002.json
    │   │   └── task-123.json
    │   ├── dev-2/
    │   └── ... (10 агентов)
    ├── outbox/
    │   └── task-002.json
    └── dead-letter/
```

## Следующие шаги
1. Включить context_compression (флаг → true)
2. Создать create-project.ps1
3. Настроить distributed tracing
4. Протестировать все 19 JSON-конфигов агентов
