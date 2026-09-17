---
name: superpowers-test
description: "Фаза testing методологии Superpowers (obra) для SDLC: unit/integration/e2e, coverage, edge cases, regression. Применять для проверки качества реализованного кода."
---

# Superpowers Test — Testing Phase

## Описание

Фаза testing методологии Superpowers (obra) для SDLC.
Автоматизирует тестирование: unit/integration/e2e, coverage analysis, edge cases, regression test plan.

## Когда использовать

- Задачи SDLC, требующие фазы testing
- Команда team-lead делегирует задачу с указанием фазы test
- Есть реализованный код из implement фазы, нужно проверить качество
- Нужна структура: code → test strategy → test execution → report

## Инструкции

### Входные данные
- Реализованный код из implement фазы
- Тесты, написанные в TDD (implement фаза)
- Контекст из CONTEXT-BUFFER.md

### Процесс
1. Загрузи связанные локальные скиллы (см. ниже)
2. Используй MCP инструменты (context7 для testing frameworks)
3. Выполни фазу по чек-листу
4. Запиши артефакт в CONTEXT-BUFFER.md

### Чек-лист фазы
- [ ] Определи тестовую стратегию (unit → integration → e2e)
- [ ] Проверь покрытие: critical paths ≥ 80%, edge cases covered
- [ ] Запусти unit-тесты, убедись что все проходят
- [ ] Запусти integration-тесты (если применимо)
- [ ] Проведи e2e тестирование критических сценариев
- [ ] Проверь edge cases: null, empty, boundary values, errors
- [ ] Составь regression test plan для будущих изменений
- [ ] Проведи security-аудит (если применимо)
- [ ] Запиши test report

### MCP инструменты (ОБЯЗАТЕЛЬНЫЕ)
- context7_resolve-library-id + context7_query-docs — для testing frameworks (jest, vitest, pytest и т.д.)
- sequential-thinking_sequentialthinking — для test strategy, анализ покрытия
- hermes-atlas-mcp — если нужен специфичный testing инструмент

### Связанные локальные скиллы (подгружай через skill tool)
- qa-engineer — основной testing skill
- 1c-bsl-validate / 1c-query-validate — если стек включает 1С
- security-auditor — для security testing

### Выходной артефакт
Формат записи в CONTEXT-BUFFER.md:
```
[TIME] <agent> → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: |
  ## Test Report
  
  ### Coverage
  - Unit: X% (Y tests)
  - Integration: X% (Y tests)
  - Critical paths: X% covered
  
  ### Test Results
  - PASSED: X
  - FAILED: Y
  - SKIPPED: Z
  
  ### Edge Cases Checked
  - null/empty input: ✓
  - Boundary values: ✓
  - Error handling: ✓
  
  ### Regression Test Plan
  - ...
  
  ### Security Notes (if applicable)
  - ...
SKILLS_LOADED: ["superpowers-test", "qa-engineer", "<domain-skills>"]
MCP_USED: ["context7", "sequential-thinking"]
COMPLIANCE: true
STATUS: resolved
```

## Интеграция с team-lead

team-lead при делегировании SDLC-задачи указывает в ТЗ:
```
- Phase: test
- Skills: superpowers-test + qa-engineer + <domain-skills>
- MCP: context7 + sequential-thinking
- Оценка времени: 15-20 мин (агент)
```
