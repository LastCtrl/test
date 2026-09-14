# PHASE1 PART 14/15

# 1C:Enterprise Development — Встроенный язык

## Описание

Разработка на встроенном языке (BSL) платформы 1С:Предприятие 8.3. Покрывает модули, процедуры/функции, работу с объектами метаданных (справочники, документы, регистры), паттерны БСП, типизацию и обработку ошибок.

## Когда использовать

- Написание/модификация модулей объектов, форм, менеджеров
- Разработка внешних обработок и отчётов (EPF/ERF)
```

### .agents/skills/1c-edt-configurator/SKILL.md
```markdown
# 1C:Enterprise — EDT и Конфигуратор

## Описание

Работа в 1С:EDT (Enterprise Development Tools) и Конфигураторе: расширения конфигурации (CFE), обновление конфигурации, выгрузка/загрузка CF/CFE, командная разработка с Git-хранилищем, ролевая модель и best practices.

## Когда использовать

- Создание и управление расширениями конфигурации (CFE)
- Выгрузка конфигурации в файлы (CF) и обратная загрузка
```

### .agents/skills/1c-epf-build/SKILL.md
```markdown
# 1C:Enterprise — Сборка внешней обработки (EPF/ERF)

## Описание

Сборка внешней обработки 1С (EPF) или внешнего отчёта (ERF) из XML-исходников через пакетный запуск платформы. Работает без EDT — напрямую из исходников в файл.

## Когда использовать

- Собрать EPF/ERF из XML-исходников
- Автоматизировать сборку обработок в CI/CD
```

### .agents/skills/1c-form-patterns/SKILL.md
```markdown
# 1C:Enterprise — Паттерны компоновки управляемых форм

## Описание

Справочник типовых паттернов дизайна управляемых форм 1С. Архетипы форм (документ, обработка, справочник, список), конвенции именования, иерархия групп, продвинутые приёмы компоновки.

## Когда использовать

- Проектирование управляемой формы (выбор архетипа)
- Расположение элементов управления на форме
```

### .agents/skills/1c-meta-edit/SKILL.md
```markdown
# 1C:Enterprise — Точечное редактирование метаданных

## Описание

Атомарные операции модификации XML объектов метаданных 1С. Добавление/удаление/изменение реквизитов, табличных частей, измерений, ресурсов, свойств объекта, форм, макетов, команд. Работает с XML-выгрузкой конфигурации без платформы и EDT.

## Когда использовать

- Добавить/удалить реквизит справочника, документа, регистра
- Добавить/удалить табличную часть с реквизитами
```

### .agents/skills/1c-naparnik/SKILL.md
```markdown
# 1C:Enterprise — 1С:Напарник (MCP-инструменты анализа кода)

## Описание

MCP-сервер **1c-naparnik** — интеграция с API 1С:Напарник (code.1c.ai). 12 инструментов: 6 для анализа/модификации BSL-кода, 6 для поиска по документации и базе знаний ИТС.

## Когда использовать

- Нужно проверить качество BSL-кода (стиль, архитектура, стандарты)
- Нужно проверить код на синтаксические ошибки, логические проблемы, антипаттерны
```

### .agents/skills/1c-platform-docs/SKILL.md
```markdown
# 1C:Enterprise — Документация платформы 1С (MCP)

## Описание

MCP-сервер **bsl-platform-help** — доступ к документации API платформы 1С:Предприятие. Поддерживает keyword, semantic (эмбеддинги) и hybrid поиск. Проверка существования встроенных функций/методов/свойств, получение сигнатур, просмотр членов типа.

## Когда использовать

- Проверка существования встроенных процедур/функций/методов/свойств
- Поиск методов и типов по описанию на естественном языке
```

### .agents/skills/1c-query/SKILL.md
```markdown
# 1C:Enterprise — Язык запросов

## Описание

Составление и оптимизация запросов на языке запросов 1С:Предприятие 8.3. Покрывает синтаксис (ВЫБРАТЬ/ИЗ/ГДЕ), соединения, временные таблицы, виртуальные таблицы регистров (остатки, обороты, срезы), агрегатные функции и оптимизацию производительности.

## Когда использовать

- Составление запросов для получения/фильтрации/агрегации данных из 1С-базы
- Построение отчётов и сводок
```

### .agents/skills/1c-query-optimization/SKILL.md
```markdown
# 1C:Enterprise — Продвинутая оптимизация запросов

## Описание

Продвинутые паттерны оптимизации запросов 1С: временные таблицы вместо подзапросов, оптимизация JOIN, оптимизация СКД-отчётов, обработка больших объёмов данных порциями. Дополняет базовые правила из 1c-query.

## Когда использовать

- Сложные запросы с многошаговой обработкой данных
- Оптимизация JOIN и подзапросов
```

### .agents/skills/1c-query-validate/SKILL.md
```markdown
# 1C:Enterprise — Проверка запросов по выгрузке конфигурации

## Описание

Проверка текста запроса 1С по выгрузке конфигурации: существуют ли таблицы, табличные части, виртуальные таблицы регистров и поля. Работает без EDT, без платформы и без базы — по индексу от 1c-config-index. Ловит опечатки в именах до того, как запрос попадёт в базу.

## Когда использовать

- Написали запрос и хотите проверить его перед выполнением
- Переименовали объект/реквизит — нужно найти сломанные запросы
```

### .agents/skills/1c-storage-ops/SKILL.md
```markdown
# 1C:Enterprise — Операции с хранилищем конфигурации

## Описание

Работа с хранилищем конфигурации 1С (не Git!) через пакетный запуск платформы: отчёт по версиям, захват и снятие захвата, обновление, помещение, выгрузка в CF, подключение и отключение базы. Основной механизм совместной работы в Конфигураторе.

## Когда использовать

- Захватить объекты для редактирования в хранилище
- Поместить изменения в хранилище (commit)
```

### .agents/skills/1c-support-state/SKILL.md
```markdown
# 1C:Enterprise — Состояние поддержки конфигурации

## Описание

Чтение и переключение состояния поддержки типовой (вендорской) конфигурации 1С в XML-выгрузке: разрешить правку объекта, снять с поддержки, вернуть на замок, включить/выключить возможность изменения. Работает с файлом `Ext/ParentConfigurations.bin`.

## Когда использовать

- Нужно разрешить правку типового объекта (временное снятие с замка)
- Нужно снять объект с поддержки (полное снятие)
```

### .agents/skills/1c-vanessa-steps/SKILL.md
```markdown
# 1C:Enterprise — Шаги Vanessa Automation (BDD-тестирование)

## Описание

Реестр из **1569 шагов** Vanessa Automation с описаниями и типами. Позволяет найти нужный шаг по смыслу и проверить готовый сценарий .feature перед запуском. Предотвращает ошибки «модель сочинила шаг, которого в Vanessa нет».

## Когда использовать

- Пишешь новый сценарий Vanessa — **сначала найди шаги**, потом составляй из найденного
- Правишь чужой сценарий и не уверен, существует ли шаг
```

### .agents/skills/memory-search/SKILL.md
```markdown
# Memory Search Skill

## Keyword grep по .memory/

### Поиск по файлам

1. **activeContext.md** — основной файл поиска
   - `grep -i "выполнено" .memory/activeContext.md`
   - `grep -i "заблокировано" .memory/activeContext.md`
   - `grep -i "ADR" .memory/decisionLog.md`
```

### .agents/skills/model-router/SKILL.md
```markdown
# Model Router Skill

## Текущее состояние (2026-09-09, АВАРИЙНАЯ МИГРАЦИЯ)

** ВСЕ 30 агентов работают на `tokenrouter/z-ai/glm-5.3-free` **

Причина: квота opencode free-tier исчерпана («Free usage exceeded, subscribe to Go») — модели opencode/mimo-v2.5-free, opencode/nemotron-3.5-lightning-free, opencode/nemotron-3-ultra-free НЕДОСТУПНЫ. Все запросы к ним виснут/падают.

Провайдер TokenRouter (ключ {env:TOKENROUTER_API_KEY}, отдельная квота) — единственный рабочий.

```

### .agents/skills/performance-scoring/SKILL.md
```markdown
# Performance Scoring Protocol

## Метрики агентов

### Время отклика (Response Time)
| Метрика | Целевое значение | Штраф |
|---------|------------------|-------|
| Простая задача | < 30 сек | +10 сек = -1 балл |
| Средняя задача | < 2 мин | +1 мин = -1 балл |
| Сложная задача | < 5 мин | +2 мин = -1 балл |
```

### .agents/skills/plugin-system/SKILL.md
```markdown
# Plugin System

## Структура плагинов

```
.opencode/plugins/
├── example-plugin/
│   ├── plugin.json       # Метаданные плагина
│   └── index.js          # Код плагина
└── _disabled/            # Отключённые плагины
```

### .agents/skills/self-healing/SKILL.md
```markdown
# Self-Healing Protocol

## Автоматическое восстановление при ошибках

### Уровень 1: Retry (повтор)
- **Условие**: ошибка сети, таймаут, временная недоступность
- **Действие**: повторить запрос 2 раза с экспоненциальной задержкой (1с, 2с, 4с)
- **Лог**: `.memory/traces/retry.log`

### Уровень 2: Fallback (резервная модель)
```

### .agents/skills/skill-enforcement/SKILL.md
```markdown
# Skill Enforcement — Принудительное использование скиллов и MCP

## Описание

Мета-скилл: обеспечивает 100% покрытие задач соответствующими скиллами и MCP-инструментами. Каждый агент ОБЯЗАН прочитать нужный SKILL.md ПЕРЕД началом работы и зафиксировать использование в трейсе.

## Когда использовать

- ВСЕГДА — это базовое правило для всех агентов
- При делегировании любой задачи через task tool
```

### .agents/skills/summarization/SKILL.md
```markdown
# Summarization Skill

## Автоматическое сжатие контекста

### Стратегия: summary + archive

#### Порог сжатия
1. Если `.memory/activeContext.md` > 50KB → сжатие запускается
2. ИЛИ сжатие запускается командой `/sync` каждые 30 минут
3. ИЛИ по запросу team-lead
```

### .agents/skills/superpowers/implement/SKILL.md
```markdown
# Superpowers Implement — Implementation Phase

## Описание

Фаза implementation методологии Superpowers (obra) для SDLC.
Автоматизирует написание кода: TDD (тесты первыми), clean code, YAGNI, соответствие плану.

## Когда использовать

- Задачи SDLC, требующие фазы implementation
```

### .agents/skills/superpowers/plan/SKILL.md
```markdown
# Superpowers Plan — Planning Phase

## Описание

Фаза planning методологии Superpowers (obra) для SDLC.
Автоматизирует декомпозицию requirements на архитектурные решения, задачи, зависимости и timeline.

## Когда использовать

- Задачи SDLC, требующие фазы planning
```

### .agents/skills/superpowers/spec/SKILL.md
```markdown
# Superpowers Spec — Specification Phase

## Описание

Фаза specification методологии Superpowers (obra) для SDLC.
Автоматизирует сбор и структурирование требований: от размытой идеи до чётких User Stories с Acceptance Criteria.

## Когда использовать

- Задачи SDLC, требующие фазы specification
```

### .agents/skills/superpowers/test/SKILL.md
```markdown
# Superpowers Test — Testing Phase

## Описание

Фаза testing методологии Superpowers (obra) для SDLC.
Автоматизирует тестирование: unit/integration/e2e, coverage analysis, edge cases, regression test plan.

## Когда использовать

- Задачи SDLC, требующие фазы testing
```

### .agents/skills/windows-safety/SKILL.md
```markdown
# Windows Safety & PowerShell 5.1 — обязательный скилл

## Когда использовать
ПЕРЕД любой командой сложнее `git status`, ПЕРЕД любым скачиванием/установкой, ПЕРЕД запуском чужих скриптов.

## 1. Синтаксис PowerShell 5.1
- НЕТ `&&` и `||` (это PS7/bash). Правильно:
  `cmd1; if ($LASTEXITCODE -eq 0) { cmd2 }`
- НЕТ bash: `[ -f file ]` → `Test-Path "file"`; `[ -d dir ]` → `Test-Path "dir" -PathType Container`; `rm -rf x` → `Remove-Item -Recurse -Force x`; `mkdir -p d` → `New-Item -ItemType Directory -Force d`
- НЕТ `curl -L`: использовать `curl.exe -L -o out URL` или `Invoke-WebRequest -Uri URL -OutFile out`
```

### `.memory/outbox/test-001.json` lines 1-12

```json
    1: ﻿{
    2:     "id":  "test-001",
    3:     "type":  "result",
    4:     "startedAt":  "2026-09-09T10:04:02",
    5:     "response":  "\u001b[93m\u001b[1m! \u001b[0m agent \"dev-1\" not found. Falling back to default agent \u001b[0m \u003e build ┬╖ z-ai/glm-5.3-free \u001b[0m \u001b[93m\u001b[1m! \u001b[0mpermission requested: external_directory (D:\\╨в╨╡╤Б╤В\\agent-hq\\*); auto-rejecting \u001b[0mтЬЧ \u001b[0mGet-Content -LiteralPath \"D:\\╨в╨╡╤Б╤В\\agent-hq\\CONTEXT-BUFFER.md\" -Tail 30 failed \u001b[91m\u001b[1mError: \u001b[0mThe user rejected permission to use this specific tool call.",
    6:     "finishedAt":  "2026-09-09T10:05:02",
    7:     "payload":  "Create a simple test file test_agent_output.txt with content \u0027Hello from inbox poller test\u0027",
    8:     "from":  "team-lead",
    9:     "status":  "done",
   10:     "priority":  "normal",
   11:     "to":  "dev-1"
   12: }
```

### `.memory/agent-registry.json` lines 1-1

```json


---
Ответь только: `Принято 14/15`. Жди следующую часть.
