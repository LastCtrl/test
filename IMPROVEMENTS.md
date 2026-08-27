# IMPROVEMENTS.md — Дорожная карта улучшений agent-hq

> **Документ создан:** 2026-08-25
> **Автор:** tech-writer (мультиагентная команда)
> **Статус:** DRAFT — не коммитить до приёмки qa-engineer

---

## Оглавление

1. [Правила использования документа](#1-правила-использования-документа)
2. [Таблица кандидатов](#2-таблица-кандидатов)
3. [Детализация по каждому кандидату](#3-детализация-по-каждому-кандидату)
4. [Быстрые победы на эту неделю](#4-быстрые-победы-на-эту-неделю)
5. [Правила внедрения](#5-правила-внедрения)

---

## 1. Правила использования документа

- **Приоритет** = «Польза для нас» × «Размер Effort» (чем меньше Effort при высокой пользе — тем выше приоритет).
- **Effort** обозначения: S (< 1 день), M (1–3 дня), L (> 3 дней).
- **Статус**: `IDEAS` → `VALIDATING` → `APPROVED` → `IN PROGRESS` → `DONE`.
- **Платные API запрещены.** Все решения проверяются на совместимость с бесплатными моделями (mimo-v2.5-free, nemotron-3.5-lightning-free, opencode/nemotron-3-ultra-free).
- **Приёмка обязательна.** Ни одно изменение не считается завершённым без независимой проверки qa-engineer / code-reviewer.

---

## 2. Таблица кандидатов

| # | Кандидат | Источник | Лицензия | Effort | Польза | Приоритет | Статус |
|---|---------|----------|----------|--------|--------|-----------|--------|
| 1 | **Agent Cards (A2A)** | [A2A Project](https://github.com/a2aproject/A2A) — 25.5k★ | Apache-2.0 (Linux Foundation) | **S** | Структурное обнаружение агентов; JSON-карточки в `.well-known/` | **★★★★★** | ВНЕДРЕНО |
| 2 | **Deploy-gate для промптов** | Паттерн GEPA / agent-self-evolution | N/A (собственный) | **S** | Защита от деградации промптов; baseline в git + qa-оценка | **★★★★★** | ВНЕДРЕНО |
| 3 | **Flows-паттерны (LangGraph/CrewAI)** | LangGraph, CrewAI | MIT / Apache-2.0 | **S** | Event-driven flows, conditional routing между агентами | **★★★★☆** | ВНЕДРЕНО |
| 4 | **BSL Language Server + MCP** | [mcp-bsl-platform-context](https://github.com/topics/bsl-language-server), [mcp-1c](https://github.com/topics/mcp-1c), [code-index-mcp](https://github.com/topics/code-index-mcp), Claude Code BSL LSP plugin | LGPL-3 | **M** | Статический анализ кода 1С нашими агентами | **★★★★☆** | ЖДЁТ |
| 5 | **Qodo PR-Agent** | [Qodo PR-Agent](https://github.com/Codium-ai/pr-agent) — 12.7k★ | MIT | **M** | Авто-ревью PR на GitHub; требует LLM-провайдера | **★★★☆☆** | VALIDATING |
| 6 | **DeepEval** | [DeepEval](https://github.com/confident-ai/deepeval) — Apache-2.0 | Apache-2.0 | **M** | Eval-рамка для оценки качества промптов агентов | **★★★☆☆** | IDEAS |
| 7 | **Arize Phoenix** | [Arize Phoenix](https://github.com/Arize-ai/phoenix) — Apache-2.0 | Apache-2.0 | **M** | Self-host наблюдаемость поверх traces.jsonl (OTel-native) | **★★★☆☆** | IDEAS |
| 8 | **Mem0** | [Mem0](https://github.com/mem0ai/mem0) — 63.8k★ | Apache-2.0 | **L** | Долговременная память фактов; требует Python + embeddings | **★☆☆☆☆** | IDEAS |
| 9 | **OmniRoute** | [OmniRoute](https://github.com/diegosouzapw/OmniRoute) | MIT | **S** | Шлюз-ротатор 350+ бесплатных моделей, авто-fallback, единый эндпоинт | **★★★★☆** | ЖДЁТ |
| 10 | **codebase-memory-mcp** | MCP-сервер семантического поиска по кодовой базе | — | **M** | Контекстная память для агентов при работе с крупной кодовой базой | **★★★☆☆** | ПАУЗА |
| 11 | **Рейтинг моделей** | Внутренний: ratings.jsonl + model-leaderboard.ps1 | N/A (собственный) | **S** | Оценка моделей/агентов после приёмки, таблица лидеров для делегирования | **★★★★☆** | ВНЕДРЕНО |

### Матрица приоритетов

```
Польза ↑
  ★★★★★ │  [1] Agent Cards  [2] Deploy-gate
  ★★★★☆ │  [3] Flows       [4] BSL LS
  ★★★☆☆ │  [5] Qodo PR     [6] DeepEval  [7] Phoenix
  ★★☆☆☆ │
  ★☆☆☆☆ │  [8] Mem0
         └──────────────────────────────────────→ Effort →
            S          M          L
```

---

## 3. Детализация по каждому кандидату

### 3.1. Agent Cards (A2A — Agent-to-Agent Protocol)

**Источник:** [github.com/a2aproject/A2A](https://github.com/a2aproject/A2A) (25.5k★, Apache-2.0, Linux Foundation)

**Что это:** Стандарт структурного описания агентов в формате JSON (`AgentCard`). Каждый агент публикует карточку в папке `.well-known/agent.json` (по аналогии с robots.txt / well-known URI), содержащую:
- имя, описание, версию
- список поддерживаемых навыков (skills/capabilities)
- эндпоинты для взаимодействия (URL, протокол)
- требования к аутентификации
- список моделей, которые агент использует

**Польза конкретно нам:**
- Наши 19 субагентов не имеют формализованного описания для внешнего мира. Agent Cards.allow discovering capabilities without reading промпты вручную.
- При добавлении новых агентов (или при работе с внешними командами) — автоматическая регистрация через JSON-файл.
- Совместимость с A2A-клиентами (будущий стандарт Linux Foundation).
- Генератор можно написать на чистом PowerShell / JS — без новых зависимостей.

**Зависимости:** Нет. Чистый JSON-файл + скрипт генерации.

**Риски:** Спецификация A2A молодая (2025). Формат может измениться. Однако Apache-2.0 + Linux Foundation = стабильность на горизонте.

**Effort:** S — генератор из `registry.json` (или напрямую из `opencode.json`) → `.well-known/agent.json`.

**Статус:** `IDEAS` — требует проверки

---

### 3.2. Deploy-gate для промптов

**Источник:** Паттерн из agent-self-evolution / GEPA (General Evolutionary Prompt Adaptation)

**Что это:** Механизм защиты промптов агентов от деградации. Паттерн:
1. **Baseline** — текущие промпты хранятся в git (`.opencode/agents/prompts/*.txt`).
2. **При изменении промпта** — автоматический прогон через qa-оценку (проверка на: регрессию вaccuracy, loss of instructions,语义 drift).
3. **Промпт принимается** только если qa-оценка ≥ порога (например, ≥ 90% от baseline).
4. **Rollback** — при деградации: `git checkout` предыдущей версии промпта.

**Польза конкретно нам:**
- У нас 19 агентов × промпты в `.opencode/agents/prompts/`. Любое изменение промпта может сломать поведение.
- Сейчас нет механизма защиты: агент может изменить промпт и мы узнаем о проблеме только по результатам.
- Deploy-gate = PowerShell-скрипт + текущий qa-engineer. Ноль новых зависимостей.

**Зависимости:** Нет. PowerShell + git + существующий qa-engineer.

**Риски:** Низкие. Скрипт может быть написан за 1 день. Единственный риск — overfitting qa-оценки (нужно сделать метрику устойчивой).

**Effort:** S

**Статус:** `IDEAS` — рекомендован к внедрению в первую очередь

---

### 3.3. Flows-паттерны (Event-Driven / Conditional Routing)

**Источники:** [LangGraph](https://github.com/langchain-ai/langgraph) (MIT), [CrewAI](https://github.com/crewAIInc/crewAI) (Apache-2.0)

**Что это:** Мы НЕ переносим фреймворки. Мы берём архитектурные паттерны:

1. **Event-driven flows** — агенты реагируют на события (сообщения в CONTEXT-BUFFER.md), а не на прямые вызовы. Каждое событие имеет тип, приоритет, источник. Агент сам решает, реагировать или игнорировать.

2. **Conditional routing** — вместо жёсткой иерархии (team-lead → dev-1) — динамическая маршрутизация по типу задачи. Например:
   - Баг в 1С → dev-3 (1С-скиллы) + qa-engineer
   - Новый скилл → skill-surgeon
   - Документация → tech-writer
   - Ревью → code-reviewer (автоматически)

3. **State machines** — агенты переходят между состояниями (IDLE → WORKING → REVIEW → DONE/BLOCKED), с явными переходами и таймаутами.

**Польза конкретно нам:**
- Сейчас коммуникация через CONTEXT-BUFFER.md — это pub/sub без маршрутизации. Team Lead = единственный роутер.
- Flows.allow decentralize routing: агенты могут самостоятельно обрабатывать события без обращения к team-lead.
- Уменьшает нагрузку на team-lead (особенно при масштабировании).

**Зависимости:** Нет. Описание в AGENTS.md + возможно небольшой PowerShell-скрипт для state machine.

**Риски:** Сложность перехода от текущей модели. Нужно аккуратно документировать и тестировать.

**Effort:** S — описать паттерны в AGENTS.md, реализовать state machine в CONTEXT-BUFFER.md (новые типы сообщений).

**Статус:** `IDEAS` — требует приёмки team-lead

---

### 3.4. BSL Language Server + MCP-обёртки для 1С

**Источники:**
- [mcp-bsl-platform-context](https://github.com/topics/mcp-bsl-platform-context) — MCP-сервер для BSL Language Server
- [mcp-1c](https://github.com/topics/mcp-1c) — MCP-инструменты для анализа 1С
- [code-index-mcp](https://github.com/topics/code-index-mcp) — индексация кода через MCP
- Claude Code BSL LSP plugin — плагин для Claude Code с поддержкой BSL

**Что это:** BSL Language Server — статический анализатор кода на встроенном языке 1С (BSL). Поддерживает:
- Проверку синтаксиса и семантики
- Паттерны код-стиля (1С:Стандарт)
- Поиск уязвимостей
- Метрики кода (цикломатическая сложность и т.д.)

MCP-обёртки.allow our agents to call BSL Language Server через MCP-протокол (context7 или отдельный MCP-сервер).

**Польза конкретно нам:**
- У нас уже 23 скилла для 1С. BSL LS allow автоматизированную проверку кода 1С (вместо ручной).
- При работе с 1С-проектами: агенты dev-3, backend, qa-engineer могут вызывать BSL LS через MCP.
- LGPL-3: можно использовать в коммерческом проекте (мы не модифицируем сам BSL LS, только оборачиваем).

**Зависимости:**
- BSL Language Server (JVM, ~200MB)
- MCP-обёртка (npm-пакет или Docker-контейнер)
- Проверить: работоспособность MCP-обёрток на бесплатных моделях

**Риски:**
- LGPL-3: если модифицировать BSL LS — нужно open-source изменения. Мы НЕ модифицируем, только оборачиваем → OK.
- JVM-зависимость: нужен Java 17+ на машине агента.
- Активность: mcp-bsl-platform-context — активен (1.0.7, август 2026) → низкий риск заброшенности.

**Effort:** M — интеграция BSL LS + MCP-обёртка + тестирование в verify-phase.

**Статус:** `IDEAS` — требует проверки: (1) совместимость с бесплатными моделями, (2) стабильность MCP-обёрток, (3) LGPL-лицензирование.

---

### 3.5. Qodo PR-Agent

**Источник:** [github.com/Codium-ai/pr-agent](https://github.com/Codium-ai/pr-agent) — 12.7k★, MIT

**Что это:** Автоматический ревьюер pull request'ов. Работает через GitHub Actions / GitLab CI / локально. Использует LLM для:
- Анализа изменений
- Поиска багов и security-проблем
- Предложений по улучшению
- Генерации описания PR

**Польза конкретно нам:**
- Автоматическое ревью PR на GitHub (если мы начнём использовать GitHub для collaboration).
- Дополняет наш code-reviewer: PR-Agent = первый фильтр, code-reviewer = глубокое ревью.

**Зависимости:**
- LLM-провайдер (OpenAI API, Anthropic API, или self-hosted)
- GitHub/GitLab токен
- **ПРОВЕРИТЬ:** совместимость с бесплатными моделями (opencode/nemotron-3-ultra-free, mimo-v2.5-free)

**Риски:**
- Требует LLM API → **потенциально платные API**. Если PR-Agent не поддерживает self-hosted модели — отклоняем.
- GitHub-зависимость: если мы работаем только локально — нет benefit.

**Effort:** M — интеграция + проверка LLM-совместимости.

**Статус:** `VALIDATING` — главный вопрос: поддерживает ли self-hosted / бесплатные модели?

---

### 3.6. DeepEval

**Источник:** [github.com/confident-ai/deepeval](https://github.com/confident-ai/deepeval) — Apache-2.0

**Что это:** Eval-рамка для оценки качества LLM-промптов и агентов. Метрики:
- Faithfulness (точность ответов)
- Answer relevancy (релевантность)
- Context precision / recall
- Hallucination detection
- Toxicity / bias detection

**Польза конкретно нам:**
- Регулярная оценка качества промптов 19 агентов.
- Автоматический regression testing: новый промпт vs baseline.
- Apache-2.0: полная свобода использования.

**Зависимости:**
- Python 3.10+
- LLM-провайдер для оценки (может быть тот же бесплатный)
- **ПРОВЕРИТЬ:** можно ли использовать DeepEval с self-hosted моделями (без OpenAI API)

**Риски:**
- Python-зависимость: у нас PowerShell + JS. Нужен Docker или отдельный Python-процесс.
- Может требовать OpenAI API для某些 метрик (faithfulness, relevancy) → проверить.

**Effort:** M

**Статус:** `IDEAS` — требует проверки: (1) Python-интеграция, (2) LLM-совместимость.

---

### 3.7. Arize Phoenix

**Источник:** [github.com/Arize-ai/phoenix](https://github.com/Arize-ai/phoenix) — Apache-2.0

**Что это:** Self-hosted платформа наблюдаемости для LLM-приложений. Совместима с OpenTelemetry (OTel). Возможности:
- Визуализация traces (наши traces.jsonl)
- Оценка качества (сравнение с baseline)
- Мониторинг latency / cost / quality
- Single binary部署 (без Kubernetes)

**Польза конкретно нам:**
- Наши traces.jsonl и performance.jsonl уже содержат данные. Phoenix allow визуализировать и анализировать их.
- Заменяет / дополняет health-check.ps1 (текстовый → визуальный дашборд).
- OTel-native: данные из tracer.js автоматически попадают в Phoenix.

**Зависимости:**
- Docker (для self-hosted) или бинарник (~50MB)
- Браузер для дашборда
- **ПРОВЕРИТЬ:** совместимость с форматом traces.jsonl (нужен OTel-формат или конвертер)

**Риски:**
- Docker: нужен Docker на машине (или Docker Desktop на Windows).
- Формат traces: наш tracer.js пишет в custom JSON, не OTel. Нужен конвертер или адаптер.

**Effort:** M

**Статус:** `IDEAS` — требует проверки: (1) Docker-доступность, (2) совместимость формата traces.

---

### 3.8. Mem0

**Источник:** [github.com/mem0ai/mem0](https://github.com/mem0ai/mem0) — 63.8k★, Apache-2.0

**Что это:** Долговременная память для LLM-агентов. Хранит факты, предпочтения, контекст между сессиями. Использует embeddings + vector store.

**Польза конкретно нам:**
- Наша Memory Bank (markdown-файлы в `.memory/`) уже решает эту задачу. Mem0 = более продвинутая версия (vector search, автоматическое извлечение фактов).

**Зависимости:**
- Python 3.10+
- Vector store (Chroma, Pinecone, Qdrant)
- Embeddings model (local или API)
- **МНОГО** новых зависимостей

**Риски:**
- **Высокий effort (L)**: установка Python, vector store, embeddings модель, настройка.
- **Дублирование**: наша Memory Bank уже работает. Mem0 = overkill для текущего масштаба (19 агентов).
- **Платные API**: embeddings через OpenAI/Anthropic → платно. Self-hosted embeddings = ещё одна зависимость.

**Effort:** L

**Статус:** `IDEAS` — **экспериментально, не приоритет**. Рассмотреть при масштабировании > 50 агентов или при необходимости semantic search по истории.

---

## 4. Быстрые победы на эту неделю

Эти задачи можно выполнить за 1–3 дня с минимальными рисками. Рекомендованы к немедленному внедрению.

### 4.1. Agent Cards генератор (Effort: S)

**Задача:** Написать PowerShell-скрипт `generate-agent-cards.ps1`, который:
1. Читает `registry.json` (или `opencode.json`) с описанием 19 агентов.
2. Генерирует `.well-known/agent.json` — JSON-массив карточек в формате A2A Agent Card.
3. Каждая карточка: `name`, `description`, `capabilities[]`, `models[]`, `skills[]`.
4. Запуск: при каждом `/sync` или вручную.

**Выход:** Новый скрипт + JSON-файл в `.well-known/`.

**Приёмка:** qa-engineer проверяет валидность JSON, наличие всех 19 агентов, корректность полей.

**Команда:** dev-1 или dev-3 (PowerShell).

**Статус:** ✅ ВНЕДРЕНО — скрипт `generate-agent-cards.ps1` работает, генерирует карточки для 19 агентов.

---

### 4.2. Deploy-gate скрипт (Effort: S)

**Задача:** PowerShell-скрипт `prompt-deploy-gate.ps1`:
1. Сравнивает текущий промпт с baseline (git HEAD или `.memory/prompt-baselines/`).
2. Запускает прогон через qa-engineer (или автоматическую оценку) → score.
3. Если score < порога (например, 90%) → блокирует принятие + логирует.
4. Если score ≥ порога → allow.

**Выход:** Новый скрипт + baseline-папка.

**Приёмка:** qa-engineer проверяет: (1) деградация блокируется, (2) улучшение проходит, (3) log-файл корректен.

**Команда:** dev-3 (PowerShell).

**Статус:** ✅ ВНЕДРЕНО — `prompt-gate.ps1`, PASS 19/19 промптов.

---

### 4.3. BSL LS пробная интеграция (Effort: M)

**Задача:** Установить BSL Language Server локально (или в Docker), проверить:
1. Запуск на Windows (Java 17+ нужна?).
2. Анализ простого BSL-файла (ВЫБРАТЬ ... ИЗ ... ГДЕ ...).
3. Интеграция с MCP (mcp-bsl-platform-context или mcp-1c).
4. Вызов из opencode (через context7 или отдельный MCP-сервер).

**Выход:** Отчёт: работает / не работает + рекомендации.

**Приёмка:** qa-engineer проверяет: (1) BSL LS запустился, (2) нашёл ошибки в тестовом коде, (3) MCP-вызов работает.

**Команда:** dev-3 + backend (для MCP-интеграции).

**Статус:** ⏳ ЖДЁТ — нужна Java 17+ (решение пользователя об установке JDK).

---

### 4.4. Описание flows-паттернов (Effort: S)

**Задача:** Расширить AGENTS.md секцию о коммуникации агентов:
1. Описать event-driven модель: CONTEXT-BUFFER.md = event bus, типы событий (heartbeat, decision, blocker, update).
2. Описать conditional routing: таблица «тип задачи → ответственный агент».
3. Описать state machine для агента: IDLE → WORKING → REVIEW → DONE/BLOCKED → IDLE.
4. Примеры: как dev-3 получает задачу 1С, как code-reviewer запускается автоматически.

**Выход:** Обновлённый AGENTS.md с секцией «Event-Driven Flows».

**Приёмка:** team-lead проверяет: (1) паттерны описаны, (2) примеры рабочие, (3) нет противоречий с текущим протоколом.

**Команда:** tech-writer + team-lead.

**Статус:** ✅ ВНЕДРЕНО (частично) — базовые правила коммуникации и conditional routing описаны в AGENTS.md.

---

## 5. Правила внедрения

### Обязательные

1. **qa-приёмка** — каждое изменение проходит проверку qa-engineer (или code-reviewer). Без приёмки = не готово.
2. **Платные API запрещены** — все решения проверяются на совместимость с бесплатными моделями (mimo-v2.5-free, nemotron-3.5-lightning-free, opencode/nemotron-3-ultra-free). Если требует платный API — отклоняется.
3. **Коммит после приёмки** — файлы не коммитятся до Approve от qa-engineer. Откат: `git stash` или `git checkout`.
4. **Документация** — каждое изменение сопровождается обновлением README.md / AGENTS.md / CHANGELOG.md.

### Рекомендуемые

5. **Feature flags** — новые функции включаются через конфигурацию (а не через удаление старого кода).
6. **Post-mortem** — после каждого incidents (blocker в CONTEXT-BUFFER.md) — краткий анализ причины и предотвращения.
7. **Ретроспектива** — еженедельно: что работает, что нет, что улучшить.

---

## Приоритеты на ближайшие 2 недели

| Неделя | Задача | Effort | Ответственный |
|--------|--------|--------|---------------|
| 1 | Agent Cards генератор | S | dev-3 |
| 1 | Deploy-gate скрипт | S | dev-3 |
| 1 | Flows-паттерны в AGENTS.md | S | tech-writer + team-lead |
| 1-2 | BSL LS пробная интеграция | M | dev-3 + backend |
| 2 | Qodo PR-Agent: проверка LLM-совместимости | M | backend |
| 2 | DeepEval: проверка Python-интеграции | M | backend |
| 2+ | Arize Phoenix: проверка Docker + формата traces | M | devops |
| later | Mem0: эксперимент при масштабировании | L | — |

---

## 6. Волна 2 — разведка [2026-08-25]

### Таблица А. Общие усиления

| # | Кандидат | Лицензия | ★ | Effort | Что даёт |
|---|----------|----------|---|--------|----------|
| 1 | **serena** | MIT | 28.4k | **M** | Семантический поиск / рефакторинг кода через LSP-MCP — «IDE-глаза» для агентов |
| 2 | **ast-grep-mcp** | — | — | **M** | Структурный поиск и переписывание по AST (абстрактному синтаксическому дереву) |
| 3 | **playwright-mcp** + **chrome-devtools-mcp** | — | — | **M** | Агенты водят браузер и читают консоль/сеть — тестирование UI |
| 4 | **worktrunk** | — | — | **S** | Менеджер git worktree (изолированные рабочие копии для параллельных задач) |
| 5 | **claude-squad** | AGPL-3.0 | — | **M** | TUI-оркестратор параллельных агентов. **На Windows только через WSL** |
| 6 | **sqlite-vec** | — | — | **M/L** | Локальный векторный RAG без сервера (SQLite-плагин для embeddings) |
| 7 | **scip-search** | — | — | **S** | Stateless символ-поиск без MCP (быстрый переход к определению функций/классов) |

> **Примечание по claude-squad:** лицензия AGPL-3.0 +requirement на WSL делает кандидата спорным. Решение — после детальной оценки рисков.

---

### Таблица Б. 1С-стек

| # | Кандидат | Лицензия | Effort | Что даёт |
|---|----------|----------|--------|----------|
| 1 | **mcp-1c** (feenlace) | — | **S!** | Go-бинарник MCP: дерево метаданных, поиск по коду, запросы к конфигурации |
| 2 | **sonar-bsl-plugin-community v1.18** | LGPL | **S-M** | 250+ диагностик BSL LS как правила SonarQube, quality gates |
| 3 | **vanessa-runner** + **Vanessa Automation** | — | **M** | Headless BDD/Gherkin тесты 1С в CI + интеграция с Allure |
| 4 | **EDT CLI** (`1cedtcli`) | — | **M** | Управление EDT из командной строки — дружелюбно к агентам |
| 5 | **OneScript skills-пакеты** | — | **S** | Готовые скиллы на OneScript для автоматизации |
| 6 | **Arman-Kudaibergenov/1c-ai-development-kit** | — | **S** | 52 скилла в формате SKILL.md — кандидат на докачку skill-surgeon'ом |

---

### Блок. Минимальный высокоимпактный 1С-стек

```
mcp-1c (контекст конфигурации) → BSL LS / Sonar (проверка качества) → Vanessa (тесты)
```

**Замкнутый цикл** «написал → проверил → протестировал» для агентной разработки 1С.

**Ключевые характеристики:**
- Всё **self-host** и **бесплатно**.
- **claude-squad** под вопросом из-за AGPL + WSL-требования.
- Перед внедрением каждого компонента — **qa-приёмка** (обязательно).

---

### Рекомендации

1. **Приоритет Волны 2:** mcp-1c (S!) → serena (M) → sqlite-vec (M/L) — максимальный эффект при минимуме Effort.
2. **1С-стек:** mcp-1c + BSL LS + Vanessa — замкнутый цикл, все компоненты self-host. Приоритетная ветка для 1С-задач.
3. **claude-squad:** отложить до прояснения лицензионных вопросов (AGPL-3.0) и WSL-ограничений.
4. **playwright-mcp + chrome-devtools-mcp:** перспективно для автоматизации UI-тестирования, но требует стабильного окружения (Chromium).
5. **scip-search + worktrunk:** быстрые победы (S), можно подключить параллельно с основными задачами.
6. **1c-ai-development-kit:** 52 скилла — потенциальное ускорение. Skill-surgeon может адаптировать под наш формат SKILL.md.

---

*Документ будет обновляться по мере внедрения кандидатов. Статусы: IDEAS → VALIDATING → APPROVED → IN PROGRESS → DONE.*
