---
name: superpowers-plan
description: "Фаза planning методологии Superpowers (obra) для SDLC: декомпозиция requirements на архитектуру, задачи и timeline. Применять для технического планирования SDLC-задач."
---

# Superpowers Plan — Planning Phase

## Описание

Фаза planning методологии Superpowers (obra) для SDLC.
Автоматизирует декомпозицию requirements на архитектурные решения, задачи, зависимости и timeline.

## Когда использовать

- Задачи SDLC, требующие фазы planning
- Команда team-lead делегирует задачу с указанием фазы plan
- Есть готовые User Stories из spec фазы, нужен технический план
- Нужна структура: requirements → architecture → decomposition → timeline

## Инструкции

### Входные данные
- User Stories из spec фазы
- Контекст из CONTEXT-BUFFER.md
- Ограничения: бюджет, время, стек, команда

### Процесс
1. Загрузи связанные локальные скиллы (см. ниже)
2. Используй MCP инструменты (sequential-thinking ОБЯЗАТЕЛЕН, context7)
3. Выполни фазу по чек-листу
4. Запиши артефакт в CONTEXT-BUFFER.md

### Чек-лист фазы
- [ ] Проанализируй User Stories и определи компоненты системы
- [ ] Спрогнозируй архитектурные решения (ADR — Architecture Decision Records)
- [ ] Проведи декомпозицию на конкретные задачи (task breakdown)
- [ ] Построй граф зависимостей между задачами
- [ ] Оцени трудозатраты для каждой задачи
- [ ] Определи риски и митигационные стратегии
- [ ] Сформируй timeline с учётом зависимостей
- [ ] Рекомендуй модели/агентов для каждой задачи (модель-специфичные)
- [ ] Запиши финальный planning артефакт

### MCP инструменты (ОБЯЗАТЕЛЬНЫЕ)
- sequential-thinking_sequentialthinking — ОБЯЗАТЕЛЕН для планирования и декомпозиции
- context7_query-docs — для архитектурных паттернов и best practices
- hermes-atlas-mcp — если нужен новый инструмент/скилл для плана

### Связанные локальные скиллы (подгружай через skill tool)
- model-router — для выбора оптимальных моделей под задачи
- sequential-thinking — для структурированного планирования (встроенный в MCP)

### Выходной артефакт
Формат записи в CONTEXT-BUFFER.md:
```
[TIME] <agent> → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: |
  ## Planning
  
  ### Architecture Decisions
  - ADR-01: ...
  
  ### Task Breakdown
  - TASK-01: <описание> | Est: Xh | Dependencies: [] | Model: lightning
  - TASK-02: <описание> | Est: Xh | Dependencies: [TASK-01] | Model: mimo
  
  ### Dependency Graph
  TASK-01 → TASK-02 → TASK-03
  TASK-01 → TASK-04
  
  ### Risks
  - Risk-1: ... | Mitigation: ...
  
  ### Timeline
  Week 1: TASK-01, TASK-02
  Week 2: TASK-03, TASK-04
SKILLS_LOADED: ["superpowers-plan", "model-router"]
MCP_USED: ["sequential-thinking", "context7"]
COMPLIANCE: true
STATUS: resolved
```

## Интеграция с team-lead

team-lead при делегировании SDLC-задачи указывает в ТЗ:
```
- Phase: plan
- Skills: superpowers-plan + model-router
- MCP: sequential-thinking (ОБЯЗАТЕЛЕН) + context7
- Оценка времени: 15-20 мин (агент)
```
