# Product Context — Описание проекта agent-hq

## TL;DR
**Проект:** agent-hq — штаб-квартира мультиагентной команды на бесплатных моделях opencode-go.

## Стек
- **Модели:** mimo-v2.5-free (primary), nemotron-3.5-lightning-free (fast), nemotron-3-ultra-free (fallback)
- **Язык:** Русский (подтверждено excelente quality в тестах mimo)
- **Архитектура:** Git worktree изоляция, файловая очередь сообщений, Memory Bank
- **Лицензия:** Отдельная от существующего agent-team

## Цели
1. Создать рабочую систему мультиагентов на бесплатных моделях
2. Разделить ответственность между 17 агентами с четкими специальностями
3. Организовать компактный контекст через Memory Bank (5 файлов вместо одного巨大文件)
4. Организовать модульную систему, где каждую функциональность можно включить/выключить
5. Создать CI/CD для промптов агентов (авто-тесты при изменении моделей)

## Принципы
1. **Skills-first:** Перед любым действием проверять `.agents/skills/`
2. **Sandbox:** Агенты работают в git worktree, main защищен
3. **Communication:** Через inbox/outbox, а не общий контекст
4. **Modularity:** Флаги в opencode.json включают/выключают функции
5. **Versioning:** git commit после каждого изменения промпта агента

## Состояние на 21.08.2026
- ✅ Создана структура папок
- ✅ Создан opencode.json с настройками
- ✅ Создан registry.json с 17 агентами
- ✅ Созданы 3 скилла (model-router, memory-search, summarization)
- ✅ Создан message-queue.ps1
- ⏳ MVP (7 ч) — далее по необходимости
- ⏳ Полная система — 22 часа

## Ключевые файлы
- `.opencode.json` — команды иDefaults
- `.agents/registry.json` — реестр агентов
- `.memory/activeContext.md` — текущий контекст
- `.memory/decisionLog.md` — логи решений
- `.memory/progress.md` — прогресс