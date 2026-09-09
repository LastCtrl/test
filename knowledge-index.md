# Cross-Project Knowledge Index

> **Инструкция для агентов**: Перед решением задачи проверь подходящие теги ниже — есть ли паттерн, который уже решал аналогичную проблему. После решения задачи с новым интересным решением — предложи запись тимлиду (не блокирует задачу).

---

### PAT-001: Memory Bank — изолированное хранилище контекста проекта
- **Source**: agent-hq (ADR-001)
- **Problem**: Агенты разных проектов видят чужой контекст → ошибки, путаница, утечка данных
- **Solution**: Каждый проект получает свою папку `projects/{name}/` с изолированным `CONTEXT-BUFFER.md`, `KNOWLEDGE-BASE.md`, `memory/`. Агент проекта A не может читать/писать контекст проекта B.
- **Where**: `projects/{name}/CONTEXT-BUFFER.md`, `.memory/`
- **Tags**: [architecture, isolation, context, multi-project]

### PAT-002: Agent Communication Protocol — inbox/outbox JSON
- **Source**: agent-hq (ADR-002)
- **Problem**: Агенты не могут надёжно обмениваться сообщениями при параллельной работе
- **Solution**: Файловый протокол inbox/outbox через JSON-файлы в `.agents/inbox/` и `.agents/outbox/`. Каждое сообщение — отдельный файл с метаданными (id, from, to, type, priority, payload). Guarantees: запись атомарна, чтение — через polling.
- **Where**: `.agents/inbox/`, `.agents/outbox/`, `.agents/scripts/inbox-poller.ps1`
- **Tags**: [messaging, async, agents, protocol]

### PAT-003: Sandbox worktree — изоляция через git worktree
- **Source**: agent-hq (ADR-003)
- **Problem**: Несколько агентов пишут в один репо одновременно → merge-конфликты, потеря данных
- **Solution**: Каждый агент работает в собственном git worktree (`sandbox_per_agent: true`). Изменения изолированы до merge. `merge_strategy: git-branch` — автоматическое создание ветки при конфликте.
- **Where**: git worktree directories, `opencode.json` → sandbox config
- **Tags**: [git, isolation, sandbox, parallel]

### PAT-004: Skills-first — подгрузка скиллов перед задачей
- **Source**: agent-hq (ADR-004)
- **Problem**: Агенты не знают специфику технологий → ошибки, неактуальные паттерны, повторное изобретение
- **Solution**: Перед каждой задачей агент подгружает релевантные скиллы из `.agents/skills/` через Skill tool. Скиллы содержат инструкции, примеры кода, checklist'ы. Тимлид при делегировании САМ указывает пути к нужным SKILL.md в ТЗ.
- **Where**: `.agents/skills/`
- **Tags**: [skills, onboarding, best-practice, delegation]

### PAT-005: Model Router — автоматический выбор модели по сложности
- **Source**: agent-hq (ADR-005)
- **Problem**: Все задачи идут на одной модели → простые задачи дорого, сложные — слабо
- **Solution**: Роутер выбирает модель по длине промпта и триггер-словам. Простые правки → lightning, средние → mimo, сложные/архитектурные → nemotron-ultra. Лестница силы: lightning → mimo → nemotron-ultra.
- **Where**: `opencode.json` → models config, AGENTS.md §5
- **Tags**: [models, routing, cost, optimization]

### PAT-006: PowerShell 5.1 — текстовая замена JSON без ломания кириллицы
- **Source**: agent-hq (sync-agents.ps1)
- **Problem**: PowerShell 5.1 на русской Windows использует cp1251; JSON-файлы с кириллицей ломаются при чтении/записи через Get-Content/Set-Content
- **Solution**: Использовать `[System.IO.File]::ReadAllText()` и `::WriteAllText()` с `[System.Text.Encoding]::UTF8`. Файлы БЕЗ BOM. Не использовать `-Encoding UTF8` в PS 5.1 (производит UTF-8 с BOM, который ломает بعض парсеры). Не писать кириллицу через `Set-Content`.
- **Where**: `.agents/scripts/sync-agents.ps1`, `.agents/scripts/inbox-poller.ps1`
- **Tags**: [powershell, encoding, windows, json, utf8]

### PAT-007: Busy lock recovery — session-recovery при файловых конфликтах
- **Source**: agent-hq
- **Problem**: При параллельной работе агентов возникает `Busy: FileSystem.writeFile` lock conflict — агент не может записать файл, потому что другой агент держит блокировку
- **Solution**: Скрипт `session-recovery.ps1` автоматически переделегирует задачу на свободную копию агента (team-lead-1/2/3). Приоритет: сначала попытка на той же модели, затем — более сильная. Лестница: lightning → mimo → nemotron-ultra.
- **Where**: `.agents/scripts/session-recovery.ps1`
- **Tags**: [recovery, locking, concurrency, resilience]

### PAT-008: TokenRouter openai-compatible провайдер — подстановка ключа через {env:}
- **Source**: agent-hq
- **Problem**: API-ключи не должны храниться в конфигах в открытом виде; разные провайдеры требуют разные форматы заголовков авторизации
- **Solution**: В `opencode.json` ключ подставляется из переменной окружения через синтаксис `{env:VAR_NAME}`. Провайдер `openai-compatible` позволяет работать с любым API, совместимым с OpenAPI, указывая `baseURL` и `apiKey` отдельно. Пример: `"apiKey": "{env:OPENROUTER_API_KEY}"`.
- **Where**: `opencode.json` → providers section
- **Tags**: [config, api, security, providers, env]
