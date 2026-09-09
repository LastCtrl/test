# Skills Catalog — agent-hq

Каталог всех доступных скиллов. Используй `skill <name>` для загрузки.

## 1C Skills (17 шт.)

| Скилл | Описание | Когда использовать | Путь |
|-------|----------|-------------------|------|
| 1c-bsl-validate | Проверка BSL-кода на синтаксические ошибки и вызовы несуществующих методов | Перед коммитом 1С-кода, CI/CD | .agents/skills/1c-bsl-validate/SKILL.md |
| 1c-bsp-api | Справочник методов БСП (Библиотека Стандартных Подсистем) | Нужны методы БСП: работа с регистрами, обмен данными, права доступа | .agents/skills/1c-bsp-api/SKILL.md |
| 1c-config-index | Индексация выгрузки конфигурации для быстрого поиска | Анализ больших конфигураций, поиск объектов | .agents/skills/1c-config-index/SKILL.md |
| 1c-config-router | Мета-скилл: маршрутизация задач по всем 1С-скиллам | Не знаешь какой скилл использовать для 1С-задачи | .agents/skills/1c-config-router/SKILL.md |
| 1c-dev | Базовые паттерны разработки на 1С:Enterprise | Любая задача по 1С: создание объектов, форм, отчётов | .agents/skills/1c-dev/SKILL.md |
| 1c-edt-configurator | Настройка EDT (1C:Enterprise Development Tools) | Настройка IDE, отладка, профилирование | .agents/skills/1c-edt-configurator/SKILL.md |
| 1c-epf-build | Сборка внешних обработок (EPF) | Создание/сборка .epf файлов | .agents/skills/1c-epf-build/SKILL.md |
| 1c-form-patterns | Паттерны форм 1С: управляемые, такси, списки, выбор | Создание/рефакторинг форм | .agents/skills/1c-form-patterns/SKILL.md |
| 1c-meta-edit | Редактирование метаданных: реквизиты, табличные части, команды | Добавление/изменение реквизитов, ТЧ, команд | .agents/skills/1c-meta-edit/SKILL.md |
| 1c-naparnik | Работа с 1С:Напарник (MCP сервер для 1С) | Автоматизация через 1С:Напарник MCP | .agents/skills/1c-naparnik/SKILL.md |
| 1c-platform-docs | Документация платформы 1С: синтаксис, стандартные библиотеки | Справочник по платформе, стандартные библиотеки | .agents/skills/1c-platform-docs/SKILL.md |
| 1c-query | Составление запросов 1С: СКД, временные таблицы, виртуальные таблицы | Написание/оптимизация запросов | .agents/skills/1c-query/SKILL.md |
| 1c-query-optimization | Оптимизация запросов 1С: индексы, планы, СКД | Медленные запросы, EXPLAIN, индексы | .agents/skills/1c-query-optimization/SKILL.md |
| 1c-query-validate | Проверка запросов по выгрузке данных | Валидация логики запросов на тестовых данных | .agents/skills/1c-query-validate/SKILL.md |
| 1c-storage-ops | Операции с хранилищем конфигурации (Git, bin) | Работа с хранилищем, слияние, история | .agents/skills/1c-storage-ops/SKILL.md |
| 1c-support-state | Управление состоянием поддержки конфигурации | Включение/выключение поддержки, безопасное редактирование | .agents/skills/1c-support-state/SKILL.md |
| 1c-vanessa-steps | BDD-тесты Vanessa Automation | Написание/запуск BDD-тестов | .agents/skills/1c-vanessa-steps/SKILL.md |

## Core Skills (7 шт.)

| Скилл | Описание | Когда использовать | Путь |
|-------|----------|-------------------|------|
| skill-enforcement | Мета-скилл: принудительное использование скиллов/MCP | ВСЕГДА — базовое правило для всех агентов | .agents/skills/skill-enforcement/SKILL.md |
| model-router | Маршрутизация задач по моделям (mimo/lightning/ultra) | Выбор модели для задачи | .agents/skills/model-router/SKILL.md |
| performance-scoring | Оценка производительности агентов | Анализ трейсов, scoring | .agents/skills/performance-scoring/SKILL.md |
| self-healing | Автоисправление типичных ошибок | Retry, fallback, recovery | .agents/skills/self-healing/SKILL.md |
| summarization | Саммаризация длинных текстов/логов | Сжатие контекста, отчёты | .agents/skills/summarization/SKILL.md |
| memory-search | Поиск в Memory Bank (.memory/*) | Поиск контекста, решений, багов | .agents/skills/memory-search/SKILL.md |
| plugin-system | Система плагинов opencode | Создание/подключение плагинов | .agents/skills/plugin-system/SKILL.md |

## Superpowers (4 шт.) — SDLC фазы

| Скилл | Фаза | Описание | Путь |
|-------|------|----------|------|
| superpowers-spec | Specification | Requirements, user stories, acceptance criteria | .agents/skills/superpowers/spec/SKILL.md |
| superpowers-plan | Planning | Архитектура, decomposition, dependencies | .agents/skills/superpowers/plan/SKILL.md |
| superpowers-implement | Implementation | TDD, clean code, YAGNI | .agents/skills/superpowers/implement/SKILL.md |
| superpowers-test | Testing | Test strategy, edge cases, regression | .agents/skills/superpowers/test/SKILL.md |

---

## MCP Tools (встроенные, не требуют skill вызова)

| Инструмент | Описание |
|------------|----------|
| context7_resolve-library-id | Найти ID библиотеки в Context7 |
| context7_query-docs | Получить актуальную документацию/примеры |
| hermes-atlas-mcp_search_projects | Поиск готовых скиллов/тулов в Hermes Atlas |
| hermes-atlas-mcp_get_project | Детали проекта из Atlas |
| sequential-thinking_sequentialthinking | Структурированное планирование сложных задач |
| serena_* | Serena инструменты (code navigation, edit, search) |

---

## Role → Skills Mapping (из registry.json)

| Агент | Required Skills |
|-------|-----------------|
| team-lead | model-router, performance-scoring, self-healing, summarization, skill-enforcement |
| dev-1 | 1c-dev, 1c-query, 1c-bsp-api, windows-safety, skill-enforcement |
| dev-2 | 1c-dev, 1c-query, 1c-edt-configurator, windows-safety, skill-enforcement |
| dev-3 | 1c-dev, 1c-bsl-validate, 1c-query-validate, windows-safety, skill-enforcement |
| frontend | 1c-form-patterns, 1c-meta-edit, skill-enforcement |
| backend | 1c-query, 1c-bsp-api, 1c-query-optimization, skill-enforcement |
| db-specialist | 1c-storage-ops, 1c-config-index, 1c-support-state, skill-enforcement |
| mobile-dev | 1c-epf-build, skill-enforcement |
| devops | windows-safety, 1c-platform-docs, skill-enforcement |
| integration-specialist | 1c-naparnik, 1c-config-router, skill-enforcement |
| data-engineer | 1c-query, 1c-query-validate, 1c-query-optimization, skill-enforcement |
| qa-engineer | 1c-bsl-validate, 1c-query-validate, 1c-storage-ops, skill-enforcement |
| security-auditor | windows-safety, 1c-platform-docs, skill-enforcement |
| code-reviewer | 1c-dev, 1c-bsl-validate, clean-code, skill-enforcement |
| product-manager | summarization, memory-search, skill-enforcement |
| tech-writer | summarization, 1c-platform-docs, skill-enforcement |
| skill-surgeon | 1c-dev, 1c-query, 1c-bsp-api, 1c-storage-ops, 1c-config-router, windows-safety, model-router, performance-scoring, self-healing, summarization, memory-search, clean-code, skill-enforcement, plugin-system |
| legal-advisor | 1c-platform-docs, summarization, skill-enforcement |
| smm-strategist | memory-search, performance-scoring, skill-enforcement |

---

**Команда для загрузки:** `skill <skill-name>` (например: `skill 1c-query`)
