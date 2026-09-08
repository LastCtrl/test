# REQUIREMENTS.md — Требования проекта agent-hq

> **Версия**: 1.1.0  
> **Дата**: 2026-09-07  
> **Автор**: Product Manager (Team Lead)

---

## Обзор проекта

agent-hq — мультиагентная система для автоматизации разработки и оркестрации ИИ-агентов. Новые требования направлены на强制化 Git-процесса и актуальность документации для безопасного масштабирования команды.

---

## User Stories

### US-009: Git Workflow Automation — автоматизация ветвления и PR

**Как** Team Lead,  
**я хочу** чтобы весь процесс изменений (промпты, скрипты, скиллы) шёл через feature branch → PR → mandatory reviews,  
**чтобы** не было прямых коммитов в main и была трассируемость изменений.

**Acceptance Criteria:**

| # | Критерий | Проверяемость |
|---|----------|---------------|
| 9.1 | Создана ветка `feature/skills-mcp-enforcement` | `git branch --list` |
| 9.2 | Каждый этап = отдельный коммит (conventional: `feat:`, `fix:`, `docs:`, `chore:`) | `git log --oneline` |
| 9.3 | PR создаётся автоматически/скриптом с template | PR body содержит sections из шаблона |
| 9.4 | Required reviewers: `qa-engineer`, `code-reviewer`, `security-auditor` | Branch protection rule |
| 9.5 | Merge только после PASS всех checks + approvals | GitHub merge queue / branch protection |
| 9.6 | После merge — удаление feature branch | `git branch -d` автоматически |

---

### US-010: Documentation Updates — обновление всей документации под новый процесс

**Как** Team Lead,  
**я хочу** чтобы вся документация отражала новый принудительный процесс Skills + MCP,  
**чтобы** новые агенты/люди сразу понимали правила.

**Acceptance Criteria:**

| # | Критерий | Файл | Проверяемость |
|---|----------|------|---------------|
| 10.1 | Добавлены §3.4 Self-report mandate, §3.5 Validator enforcement, §3.6 Superpowers integration | `AGENTS.md` | Секции существуют и нумерованы |
| 10.2 | Новая секция "Skills & MCP Enforcement" с описанием 3 слоёв | `README.md` | Секция видна в TOC |
| 10.3 | Каталог всех 17+4 скиллов с кратким описанием и когда использовать | `.agents/skills/README.md` | Каждый скилл в списке |
| 10.4 | Структура промптов, где найти role→skill mapping | `.opencode/agents/prompts/README.md` | Mapping-таблица |
| 10.5 | Запись v1.1.0 "Forced Skills+MCP Enforcement" | `CHANGELOG.md` | Entry существует |
| 10.6 | Все изменения в docs — в тех же коммитах что и код (atomic commits) | `git diff --stat` | Один PR, один branch |

---

## Приоритизация (MoSCoW)

### Must Have (MVP)
- **US-009** — Git Workflow Automation (ветвление, PR, reviews)
- **US-010** — Documentation Updates (вся документация под новый процесс)

### Should Have
- GitHub Actions workflow для автоматического создания PR
- Pre-commit hooks для conventional commits

### Could Have
- Автоматическое удаление feature branch после merge (через GitHub settings)
- PR template в `.github/PULL_REQUEST_TEMPLATE.md`

### Won't Have (this release)
- Merge queue с squash (если нет GitHub Pro)
- Автоматические release notes из PR

---

## Non-Functional Requirements

| Категория | Требование |
|-----------|-----------|
| **Производительность** | PR создаётся за < 10 сек; проверки (lint, tests) за < 2 мин |
| **Безопасность** | Branch protection: no direct push to main, mandatory reviews, status checks |
| **Масштабируемость** | Процесс работает при 19+ агентах и росте команды |
| **Доступность** | Все файлы документации в UTF-8, markdown-формат, индексируемы |
| **Трассируемость** | Каждое изменение привязано к PR, author, reviewers, timestamp |

---

## Рекомендуемый Tech Stack

| Компонент | Технология | Обоснование |
|-----------|-----------|-------------|
| **Version Control** | Git + GitHub | Отраслевой стандарт, branch protection API |
| **Branch Strategy** | GitFlow-lite (feature branches → main) | Простота при масштабировании |
| **CI/Checks** | GitHub Actions | Нативная интеграция, бесплатный для public repos |
| **Commit Convention** | Conventional Commits | Автоматизация CHANGELOG, semver |
| **PR Template** | `.github/PULL_REQUEST_TEMPLATE.md` | Стандарт GitHub, версионируется в репо |

---

## Риски и зависимости

| Риск | Описание | Митигация |
|------|----------|-----------|
| R1 | Упрямые коммиты в main из-за привычки | Branch protection + настройка "Require PR" |
| R2 | Merge conflicts при параллельной работе агентов | Feature branches короткоживущие, squash merge |
| R3 | Забытая документация | US-010 обязывает docs в каждом PR (atomic commits) |
| R4 | Нет GitHub Pro (merge queue) | Fallback: ручной squash-merge с проверкой |
| **Зависимость D1** | GitHub репозиторий должен быть на плане, поддерживающем branch protection | Проверить при начале спринта |
| **Зависимость D2** | Все агенты должны соблюдать conventional commits | Обучение через SKILL.md + enforcement |

---

## Roadmap

### Sprint 1 (MVP) — 5 дней
**US-009**: Git Workflow Automation
- День 1: Настройка branch protection rules в GitHub
- День 2: PR template (`.github/PULL_REQUEST_TEMPLATE.md`)
- День 3: Скрипт автоматического создания feature branch + PR
- День 4: Настройка required reviewers
- День 5: Тестирование полного цикла

### Sprint 1 (параллельно) — 3 дня
**US-010**: Documentation Updates
- День 1: AGENTS.md (§3.4, §3.5, §3.6), README.md (новая секция)
- День 2: `.agents/skills/README.md`, `.opencode/agents/prompts/README.md`
- День 3: CHANGELOG.md v1.1.0, проверка atomic commits

---

## Связанные документы

| Документ | Описание |
|----------|----------|
| `REQUIREMENTS-PARALLEL-PROJECTS.md` | Масштабирование до 5 параллельных проектов (US-011 — US-015) |

---

## Definition of Done

- [ ] Feature branch `feature/skills-mcp-enforcement` создана
- [ ] Все коммиты — conventional format (`feat:`, `fix:`, `docs:`, `chore:`)
- [ ] PR открыт с шаблоном
- [ ] Required reviewers: qa-engineer, code-reviewer, security-auditor — все approved
- [ ] Все status checks pass
- [ ] Вся документация обновлена и в том же PR
- [ ] Git history чистый (squash/ff merge, no merge commits в main)
- [ ] Feature branch удалена после merge
