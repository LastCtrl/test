# Changelog

Все заметные изменения в проекте agent-hq документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/),
и проект придерживается [Semantic Versioning](https://semver.org/lang/ru/).

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