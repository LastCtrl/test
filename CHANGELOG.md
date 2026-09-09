# Changelog

Все заметные изменения в проекте agent-hq документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/),
и проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

## [2.0.0] - 2026-09-09

### Added — Мультипроектность (US-011..015)
- **US-011 Multi-Project Isolation**: `.agents/templates/project/` (CONTEXT-BUFFER, KNOWLEDGE-BASE, project.json, queue.json, memory/), create-project.ps1 разворачивает из шаблона; проекты приведены к латинице (1c-buh, 1c-kis-teplo, smartwatch-bd); `/projects/` в .gitignore
- **US-012 Dynamic Agent Pool**: `.memory/agent-registry.json` (30 агентов, free/busy/error, специализации, daily_load) + `agent-registry.ps1` CLI: -Init/-List/-Reserve/-Release/-SetStatus/-Acquire (выбор: специализация → тот же проект → загрузка → рейтинг из ratings.jsonl)
- **US-013 Project Queue**: `project-queue.ps1` — приоритеты critical>high>normal>low, FIFO, -StaleCheck (15 мин timeout → dead-letter, retries≥2 → возврат в очередь), интеграция с agent-registry Release
- **US-014 Resource Awareness**: `agent-utilization.ps1` (дашборд, алерты UNDERUTILIZED/OVERLOADED, -Json, -Watch, -LogAssignment аудит в agent-assignments.jsonl) + /status секция "Agents & Utilization"
- **US-015 Cross-Project Knowledge**: `knowledge-index.md` (8 PAT-записей из ADR + опыта), промпты team-lead ×4 — проверка паттернов перед делегированием
- **TokenRouter GLM 5.3-free**: провайдер `sdk: @ai-sdk/openai-compatible`, apiKey `{env:TOKENROUTER_API_KEY}` (без хардкода; в истории git ключей нет — проверено аудитом)
- **verify-phase.ps1**: Phase F (11 чеков US-011..015), итог 41/41 PASS идемпотентно
- **Task Scheduler**: agent-hq-inbox-poller каждые 5 мин (обработка inbox в фоне; спящий режим корпоративного ПК → утренний прогон backlog)
- **run-daemons.ps1**: запуск session-recovery daemon (singleton-lock)
- **Тестовые проекты удалены**: test-project, test-wt3, examples/, fastapi-health/

### Changed — Аварийная миграция моделей (2026-09-09)
- **ВСЕ 30 агентов → `tokenrouter/z-ai/glm-5.3-free`**: квота opencode free-tier исчерпана («Free usage exceeded, subscribe to Go») — mimo/lightning/ultra недоступны. Лестница моделей недоступна → эскалация через копии агентов (AGENTS.md §3.2, §5), model-router SKILL обновлён (план восстановления распределения при возврате квоты)
- sync-agents.ps1: секция `agents` (мн.ч.), авторемов legacy-дубля `agent` (Remove-JsonTopLevelSection, -TestLegacyRemoval 3/3 PASS)

### Fixed
- **tracer.js**: session.error писал пустой message (105 записей "" ) → полный дамп event properties (fallback-цепочка + JSON.stringify 500 chars)
- **session-recovery.ps1**: хардкод даты 2026-09-07, readonly $PID, here-strings PS 5.1, UTF-8 no BOM
- **Code review round 2 (3 major)**: sync-agents legacy-removal ломал JSON во всех 3 позициях; мёртвый rollback-контракт Save-Registry/Save-Queue (Write-Error terminating); F7 не идемпотентен (мусор в queue.json)
- **Бонус-фикс**: Copy-Item с двумя -Path — .bak файлы вообще не создавались (4 места)
- **Security**: path traversal в -Project (project-queue.ps1, create-project.ps1) — whitelist + GetFullPath guard; .gitignore `*.bak` паттерны

### Security
- Аудит: 0 critical/high. Секретов нет (env-подстановка), история git чистая. Task Scheduler persistence-риск принят (корпоративный ПК, аргументы фиксированы)

## [1.1.0] - 2026-09-07

### Added
- **Skill Enforcement System** — принудительное использование Skills и MCP всеми агентами
  - `.agents/skills/skill-enforcement/SKILL.md` — мета-скилл enforcement (Слой 2)
  - `registry.json` — `required_skills` для всех 30 агентов (role→skill mapping)
  - `compliance-gate.ps1` — автоматическая валидация self-report (Слой 3)
  - Интеграция в `health-check.ps1` — compliance check как часть health check

- **AGENTS.md Updates** — новые разделы enforcement протокола
  - §3.4 Self-report Mandate — обязательный формат с `SKILLS_LOADED` и `MCP_USED`
  - §3.5 Validator Enforcement — compliance-gate проверки
  - §3.6 Superpowers Integration — MCP инструменты + 4 скилла SDLC фаз

- **Documentation**
  - `.agents/skills/README.md` — каталог 24 скиллов (17 1C + 7 Core + 4 Superpowers) + role→skill mapping
  - `.opencode/agents/prompts/README.md` — структура промптов + agent→skills+MCP таблица + delegation template
  - `.github/PULL_REQUEST_TEMPLATE.md` — PR template с обязательными reviewers

- **Superpowers (obra) Integration** — 4 скилла SDLC фаз
  - `superpowers-spec` — Specification (requirements, user stories, acceptance criteria)
  - `superpowers-plan` — Planning (architecture, decomposition, dependencies)
  - `superpowers-implement` — Implementation (TDD, clean code, YAGNI)
  - `superpowers-test` — Testing (test strategy, edge cases, regression)

- **Parallel Agent Copies** — устранение конфликтов при одновременных вызовах
  - team-lead: 3 копии (team-lead, team-lead-1, team-lead-2, team-lead-3)
  - dev-1, dev-2, dev-3: по 1 копии
  - backend: 1 копия
  - qa-engineer: 1 копия
  - security-auditor: 1 копия
  - code-reviewer: 1 копия
  - tech-writer: 1 копия
  - **Итого: 30 агентов** (вместо 19)

### Changed
- `opencode.json` — обновлён через `sync-agents.ps1` с 30 агентами
- `health-check.ps1` — добавлен Skills+MCP Compliance check
- `.opencode/agents/*.json` — все 30 агентов с `required_skills` и MCP enforcement в промптах

### Fixed
- Конфликты параллельных вызовов team-lead (Busy: FileSystem.writeFile)
- Отсутствие валидации использования skills/MCP в трейсах

### Testing
- 3 тестовые задачи пройдены:
  1. dev-1: 1C запрос с временными таблицами → SKILLS_LOADED: 6 скиллов, MCP: offline
  2. dev-1: PowerShell тестовый скрипт → compliance: true
  3. qa-engineer: Security audit test-script.ps1 → ПРИНЯТО, SKILLS_LOADED: 3 скилла

### Compliance
- Self-report format работает: `SKILLS_LOADED`, `MCP_USED`, `COMPLIANCE: true`
- compliance-gate.ps1 валидирует трейсы корректно
- health-check включает compliance check

## [1.0.0] - 2026-08-27

### Added
- Базовая инфраструктура agent-hq
- 19 агентов с разными моделями (mimo, nemotron-lightning, nemotron-ultra)
- Memory Bank (.memory/*) с inbox/outbox
- Git worktrees для sandbox
- MCP серверы: context7, hermes-atlas-mcp, sequential-thinking, serena
- 17 1C-скиллов
- verify-phase.ps1, health-check.ps1, sync-agents.ps1
- Plugins: tracer.js, scoring.js

---

**Ссылки:**
- PR: feature/skills-mcp-enforcement
- Branch: feature/skills-mcp-enforcement
- Commit: dcd16a5