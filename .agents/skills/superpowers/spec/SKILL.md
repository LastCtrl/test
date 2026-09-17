---
name: superpowers-spec
description: "Фаза specification методологии Superpowers (obra) для SDLC: от идеи до User Stories с Acceptance Criteria. Применять для формализации требований на SDLC-задачах."
---

# Superpowers Spec — Specification Phase

## Описание

Фаза specification методологии Superpowers (obra) для SDLC.
Автоматизирует сбор и структурирование требований: от размытой идеи до чётких User Stories с Acceptance Criteria.

## Когда использовать

- Задачи SDLC, требующие фазы specification
- Команда team-lead делегирует задачу с указанием фазы spec
- Есть размытые требования, идея или бизнес-задача, нуждающаяся в формализации
- Нужна структура: идея → requirements → user stories → acceptance criteria

## Инструкции

### Входные данные
- ТЗ от team-lead (idea, business context, constraints)
- Контекст из CONTEXT-BUFFER.md
- Результаты предыдущих фаз (если есть)

### Процесс
1. Загрузи связанные локальные скиллы (см. ниже)
2. Используй MCP инструменты (context7, sequential-thinking)
3. Выполни фазу по чек-листу
4. Запиши артефакт в CONTEXT-BUFFER.md

### Чек-лист фазы
- [ ] Проанализируй входное ТЗ и извлеки бизнес-цели
- [ ] Определи целевых пользователей (user personas)
- [ ] Сформулируй User Stories в формате: "As a <role>, I want <action>, so that <benefit>"
- [ ] Добавь Acceptance Criteria к каждой User Story (Given/When/Then)
- [ ] Проведи MoSCoW приоритизацию (Must/Should/Could/Won't)
- [ ] Определи нефункциональные требования (performance, security, scalability)
- [ ] Сформируй рекомендации по стеку технологий
- [ ] Запиши финальный specification артефакт

### MCP инструменты (ОБЯЗАТЕЛЬНЫЕ)
- context7_query-docs — для best practices requirements engineering
- sequential-thinking — структурирование требований, анализ неоднозначностей
- hermes-atlas-mcp — если нужны новые скиллы для специфичных доменов

### Связанные локальные скиллы (подгружай через skill tool)
- product-manager — если нужна помощь с user stories и приоритизацией
- summarization — для сжатия большого контекста до ключевых требований

### Выходной артефакт
Формат записи в CONTEXT-BUFFER.md:
```
[TIME] <agent> → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: |
  ## Specification
  
  ### Business Goals
  - ...
  
  ### User Stories
  - US-01: As a ...
    AC: Given ... When ... Then ...
    Priority: Must
  
  ### Non-functional Requirements
  - Performance: ...
  - Security: ...
  
  ### Recommended Stack
  - ...
SKILLS_LOADED: ["superpowers-spec", "product-manager", "summarization"]
MCP_USED: ["context7", "sequential-thinking"]
COMPLIANCE: true
STATUS: resolved
```

## Интеграция с team-lead

team-lead при делегировании SDLC-задачи указывает в ТЗ:
```
- Phase: spec
- Skills: superpowers-spec + product-manager
- MCP: sequential-thinking + context7
- Оценка времени: 15-20 мин (агент)
```
