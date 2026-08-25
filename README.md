# agent-hq

Система оркестрации команды из 19 ИИ-агентов поверх opencode: team-lead декомпозирует задачи и делегирует субагентам, всё на бесплатных моделях, с полной наблюдаемостью и самовосстановлением.

---

## Содержание

1. [Что это](#что-это)
2. [Архитектура](#архитектура)
3. [Как это работает](#как-это-работает)
4. [Быстрый старт](#быстрый-старт)
5. [Модели](#модели)
6. [MCP](#mcp)
7. [Правила эффективности](#правила-эффективности)
8. [Статус реализации](#статус-реализации)
9. [Плюсы](#плюсы)
10. [Минусы и ограничения](#минусы-и-ограничения)
11. [Что можно добавить дальше](#что-можно-добавить-дальше)

---

## Что это

**agent-hq** — это мультиагентная система, построенная на [opencode](https://opencode.ai). Один team-lead получает задачу от пользователя, декомпозирует её и параллельно делегирует 19 специализированным субагентам. Каждый агент работает в своём контексте, пишет результаты в общую шину (CONTEXT-BUFFER.md), а проверяющие агенты (QA, code-reviewer, security-auditor) гарантируют качество перед финальным коммитом.

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
| `.opencode/agents/*.json` | 19 конфигов агентов (name, model, permissions, prompt) |
| `.opencode/agents/prompts/*.txt` | 19 промптов агентов (подгружаются через `{file:...}`) |
| `.opencode/agents/registry.json` | Реестр агентов со specialization matrix |
| `.opencode/plugins/tracer.js` | Плагин distributed tracing → traces.jsonl |
| `.opencode/plugins/scoring.js` | Плагин performance scoring → performance.jsonl |
| `.agents/scripts/` | 6 скриптов: sync-agents.ps1, verify-phase.ps1, health-check.ps1, message-queue.ps1, create-project.ps1, inbox-poller.ps1 |
| `.agents/skills/` | 6 скиллов: memory-search, model-router, performance-scoring, plugin-system, self-healing, summarization |
| `.agents/tasks/` | Задачи для агентов (текстовые файлы) |
| `.agents/worktrees/dev-1/` | Git worktree песочница для dev-1 (выдаётся по потребности) |
| `.memory/` | Memory Bank: activeContext.md, progress.md, decisionLog.md, productContext.md, systemPatterns.md |
| `.memory/inbox/{agent}/` | Входящие задачи агенту (JSON) |
| `.memory/outbox/` | Результаты задач (JSON, status: done) |
| `.memory/dead-letter/` | Сообщения с ошибками |
| `.memory/archive/` | Архив сообщений старше 7 дней |
| `.memory/traces/` | Логи трейсинга |
| `.memory/reports/` | Отчёты (/team-report, /cost-report) |
| `projects/` | Директория проектов (test-project, news-bot, pong-advanced) |

### Структура команды

```
Пользователь
    │
    ▼
Team Lead (оркестратор)
    │
    ├── task tool → 19 субагентов (параллельно)
    │       │
    │       ├── Разработка: dev-1, dev-2, dev-3, frontend, backend, db-specialist, mobile-dev, devops, integration-specialist, data-engineer
    │       ├── Качество: qa-engineer, code-reviewer, security-auditor
    │       ├── Управление: product-manager, tech-writer, skill-surgeon
    │       └── Спец: legal-advisor, smm-strategist, team-lead
    │
    ├── CONTEXT-BUFFER.md (шина)
    ├── .memory/ (Memory Bank — контекст между сессиями)
    ├── .memory/inbox/{agent}/ (задачи агентам)
    ├── .memory/outbox/ (результаты)
    └── .agents/skills/ (скиллы, подгружать перед работой)
```

---

## Как это работает

### Основной цикл

```
1. Пользователь пишет задачу team-lead'у
2. Team-lead декомпозирует задачу на подзадачи
3. Параллельно делегирует независимые подзадачи через task tool
4. Каждый агент:
   a. Читает последние 30 строк CONTEXT-BUFFER.md
   b. Подгружает нужный скилл (skills-first)
   c. Выполняет задачу
   d. Пишет результат в CONTEXT-BUFFER.md
5. Проверяющие агенты:
   - qa-engineer: тесты, edge cases
   - code-reviewer: ревью кода (read-only)
   - security-auditor: безопасность (read-only)
6. Финальный коммит
```

### Inbox Poller (автозапуск воркеров)

`inbox-poller.ps1` — мониторит `.memory/inbox/{agent}/*.json` и автоматически запускает агентов через `opencode run --agent`:

| Флаг | Описание |
|---|---|
| `-Once` | Однократный прогон (проверить и выйти) |
| `-IntervalSeconds N` | Интервал проверки в секундах (по умолчанию 30) |
| `-DryRun` | Без реального запуска агентов (только проверка логики) |

**Поток**: inbox → opencode run --agent → outbox (status: done) → archive | dead-letter (при ошибке)

---

## Быстрый старт

```bash
cd D:\Тест\agent-hq
opencode
```

### Примеры использования

**Обычная задача текстом:**
```
Создай функцию slugify в src/utils/string-utils.js, которая превращает строку в URL-friendly вид.
```

**Обращение к конкретному агенту:**
```
@frontend Сделай адаптивную версию карточки товара.
```

**Команды:**
```
/status          — статус системы
/sync            — синхронизация контекста из Memory Bank
/new-project     — создать новый проект из шаблона
/cost-report     — отчёт по стоимости (все модели бесплатные)
/team-report     — отчёт по работе команды
```

### После правки конфигов

Если изменились `.opencode/agents/*.json`:

```powershell
.\.agents\scripts\sync-agents.ps1
# Перезапустить opencode (кэш конфига обновляется только при старте)
```

---

## Модели

| Модель | Роль | Скорость | Используется |
|---|---|---|---|
| `opencode/mimo-v2.5-free` | Основная (качество, русский) | 5-6 сек | dev-1, dev-3, frontend, legal-advisor, product-manager, skill-surgeon, smm-strategist, team-lead, tech-writer |
| `opencode/nemotron-3.5-lightning-free` | Быстрая (рутина) | 3-4 сек | backend, data-engineer, db-specialist, dev-2, devops, integration-specialist, mobile-dev |
| `opencode/nemotron-3-ultra-free` | Запасная (глубокий анализ) | 7-8 сек | резервная |
| `opencode-go/ox-alpha-free` | Проверяющие | varies | qa-engineer, code-reviewer, security-auditor |

**Запрещены** (нет в подписке): kimi-k2.x, glm-5.x, deepseek-v4-pro/flash, qwen-plus, minimax-m2.x/m3

> Платные модели запрещены. Стоимость всегда $0.

---

## MCP

### Context7

Подключён в проектном `opencode.json`:

```json
"mcp": {
    "context7": {
        "type": "local",
        "command": ["npx", "-y", "@upstash/context7-mcp"],
        "enabled": true
    }
}
```

**Что делает**: Предоставляет актуальную документацию библиотек и фреймворков в реальном времени. Вместо устаревших знаний из данных обучения агенты получают свежие API-ссылки, примеры кода и инструкции по миграции.

**Доступен**: Всем агентам сессии автоматически.

---

## Правила эффективности

1. **Team Lead не пишет код** — только конфиги, документация, правки 1-2 строк
2. **Независимые задачи — строго параллельно** — один вызов task = несколько агентов одновременно
3. **Retry: максимум 2 попытки** → откат изменений → другой агент → эскалация пользователю
4. **Skills-first** — подгрузить скилл из `.agents/skills/` ДО работы; нет нужного → skill-surgeon
5. **Никаких секретов** — пароли, токены, ключи никогда в код или логи
6. **Перед сдачей** — обязательный прогон qa-engineer + code-reviewer + security-auditor
7. **PowerShell** — не использовать `&&` (сломано в Windows), использовать `;` для разделения команд
8. **CONTEXT-BUFFER.md** — перед задачей читать последние 30 строк, после — писать результат

---

## Статус реализации

### A. Инфраструктура ✅

Git-репо, .gitignore, структура папок, git worktree dev-1 — всё на месте.

### B. Конфигурация ✅

19 агентов зарегистрированы в opencode.json. Делегирование работает end-to-end (build → task → subagent → ответ).

### C. Команды ✅

/status, /sync, /new-project, /cost-report, /team-report — все протестированы.

### D. Шина контекста и память ✅

Memory Bank (5 файлов), CONTEXT-BUFFER.md, AGENTS.md, message-queue.ps1 — созданы и работают.

### E. Кодовые фичи ✅

- Distributed Tracing: tracer.js → traces.jsonl (живые данные)
- Performance Scoring: scoring.js → performance.jsonl
- Health Monitoring: health-check.ps1 — HEALTH: PASS
- Self-Healing протокол: правила в AGENTS.md + fallback-маппинг
- Context Compression: встроенная compaction opencode + summarization skill

### F. Проверки и ревью ✅

- verify-phase.ps1: 29/29 PASSED
- Code review infra: APPROVED, 3 замечания исправлены
- Параллельный прогон 3 агентов через Start-Job — работает

### G. Inbox Poller ✅

- inbox-poller.ps1: E2E тест 9/9 PASS
- Code review: APPROVED 8/10, 0 критических
- Полный цикл: inbox → агент → outbox → archive

### Живой пример: string-utils

Цикл разработки подтверждён: dev-1 написал → qa-engineer нашёл баг slugify (кириллица) → dev-2 исправил (Unicode regex) → qa-engineer принял 6/6 PASS → APPROVED.

---

## Плюсы

| Преимущество | Описание |
|---|---|
| **$0 стоимость** | Все модели бесплатные, cost-report всегда показывает $0 |
| **Полная наблюдаемость** | Traces (traces.jsonl) + performance (performance.jsonl) + health-check |
| **Самовосстановление** | Протокол retry → откат → другой агент → эскалация |
| **Работа в одном окне** | Один TUI opencode, все агенты доступны через task tool |
| **Память между сессиями** | Memory Bank: activeContext, progress, decisionLog, productContext, systemPatterns |
| **Параллелизм** | Независимые задачи выполняются одновременно |
| **Безопасность** | security-auditor (read-only), секреты запрещены,dead-letter для ошибок |
| **Автоматизация** | inbox-poller.ps1 для автозапуска воркеров |

---

## Минусы и ограничения

| Ограничение | Описание |
|---|---|
| Кэш конфига | После правки `.opencode/agents/*.json` нужно перезапускать opencode (кэш при старте сессии) |
| Нет демонов | inbox-poller.ps1 работает вручную или через `-IntervalSeconds`; нет фонового сервиса |
| Worktree только у dev-1 | Остальные агенты делят основную working copy; worktree выдаётся по потребности |
| Кириллица в консоли | PowerShell 5.1 может отображать UTF-8 эмодзи кракозябрами; файлы при этом корректны (UTF-8 no BOM) |
| Message-queue archive | Чистит только outbox; inbox-файлы архивируются вручную |
| ox-alpha-free | Проверяющие агенты на opencode-go/ox-alpha-free — пока бесплатна, но статус может измениться |

---

## Что можно добавить дальше

| Задача | Описание |
|---|---|
| Worktree для всех агентов | Расширить `git worktree add` на dev-2, dev-3, frontend, backend и др. |
| Веб-дашборд | Визуализация performance.jsonl: score/duration по сессиям, топ агентов |
| Автозапуск poller | Регистрация inbox-poller.ps1 в Windows Task Scheduler как фоновый сервис |
| Расширение MCP | Добавить fetch/search серверы для веб-поиска и скрапинга |
| CI/CD | GitHub Actions с прогоном verify-phase.ps1 на каждый push |
| Cost dashboard | Расширенный отчёт с распределением по моделям (когда появятся платные) |

---

## Команда

Сгенерировано мультиагентной командой agent-hq.

19 агентов | opencode | бесплатные модели | $0
