---
name: superpowers-implement
description: "Фаза implementation методологии Superpowers (obra) для SDLC: TDD, clean code, YAGNI, соответствие плану. Применять при написании кода по готовому плану."
---

# Superpowers Implement — Implementation Phase

## Описание

Фаза implementation методологии Superpowers (obra) для SDLC.
Автоматизирует написание кода: TDD (тесты первыми), clean code, YAGNI, соответствие плану.

## Когда использовать

- Задачи SDLC, требующие фазы implementation
- Команда team-lead делегирует задачу с указанием фазы implement
- Есть готовый план из plan фазы, нужно написать код
- Нужна структура: plan → TDD → code → refactor → verify

## Инструкции

### Входные данные
- План из plan фазы (task breakdown, architecture decisions)
- Технические требования и стек
- Контекст из CONTEXT-BUFFER.md

### Процесс
1. Загрузи связанные локальные скиллы (см. ниже)
2. Используй MCP инструменты (context7 для ВСЕХ библиотек)
3. Выполни фазу по чек-листу
4. Запиши артефакт в CONTEXT-BUFFER.md

### Чек-лист фазы
- [ ] Прочитай план и определи свою задачу (TASK-X из plan)
- [ ] Загрузи скиллы для используемого стека
- [ ] Используй context7 для документации каждой библиотеки
- [ ] Напиши тесты ПЕРВЫМИ (TDD: Red → Green → Refactor)
- [ ] Реализуй код, проходящий тесты
- [ ] Проведи рефакторинг (clean code, YAGNI, SOLID)
- [ ] Проверь edge cases и error handling
- [ ] Убедись, что код соответствует архитектуре из plan
- [ ] Запиши CHANGELOG и техническую документацию

### MCP инструменты (ОБЯЗАТЕЛЬНЫЕ)
- context7_resolve-library-id + context7_query-docs — для ВСЕХ внешних библиотек (ОБЯЗАТЕЛЬНО, даже если "знаешь")
- sequential-thinking_sequentialthinking — для сложных компонентов, >3 шагов
- hermes-atlas-mcp — если нужен новый скилл/тул

### Связанные локальные скиллы (подгружай через skill tool)
- 1c-dev / 1c-query — если стек включает 1С
- clean-code — принципы чистого кода
- windows-safety — безопасность на Windows (парсеры, пути, скрипты)
- skill-enforcement — проверка что скиллы загружены корректно

### Выходной артефакт
Формат записи в CONTEXT-BUFFER.md:
```
[TIME] <agent> → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: |
  ## Implementation
  
  ### Task
  TASK-01: <описание>
  
  ### Files Changed
  - created: src/...
  - modified: src/...
  
  ### Test Results
  - Unit: X/Y passed
  - Coverage: Z%
  
  ### Notes
  - ...
SKILLS_LOADED: ["superpowers-implement", "<stack-specific-skills>"]
MCP_USED: ["context7", "sequential-thinking"]
COMPLIANCE: true
STATUS: resolved
```

## Интеграция с team-lead

team-lead при делегировании SDLC-задачи указывает в ТЗ:
```
- Phase: implement
- Skills: superpowers-implement + <role-specific skills>
- MCP: context7 (ОБЯЗАТЕЛЕН для библиотек) + sequential-thinking
- Оценка времени: 20-45 мин (агент, зависит от сложности)
```
