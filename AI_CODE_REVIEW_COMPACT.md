# PHASE 1 — COMPACT CODE REVIEW BUNDLE

Это многосообщенческий пакет приватного репозитория Agent HQ.

## ПРОТОКОЛ ДЛЯ ПРОВЕРЯЮЩЕЙ МОДЕЛИ

- Пользователь пришлёт несколько частей с маркерами `PHASE1 PART N/M`.
- До получения `PHASE1 END` не выполняй аудит и отвечай только: `Принято N/M`.
- После `PHASE1 END` выполни задание из следующего раздела.
- Snapshot сокращён: не делай выводов об отсутствующем коде без пометки `NOT ENOUGH EVIDENCE`.
- Номера строк относятся к исходным файлам репозитория.

# Задание внешней ИИ-модели: независимый аудит Agent HQ

## Важно

Сначала проанализируй приложенный `AI_CODE_REVIEW_BUNDLE.md` самостоятельно. Не предполагай, что заявления README соответствуют реализации. Проверяй исполняемые связи по коду.

Не ограничивайся пересказом. Ищи ошибки архитектуры, runtime, безопасности, конкурентности, конфигурации, model routing, evaluation и многопроектной работы.

## Контекст продукта

Agent HQ задуман как полностью автоматизированная система управления общим пулом из 30 ИИ-агентов для одновременной работы над несколькими проектами. Система должна:

1. классифицировать пользовательскую задачу;
2. сформировать минимальную временную команду;
3. выбрать модель по типу, сложности, риску, качеству, цене, квоте и доступности;
4. атомарно назначить свободных агентов;
5. выполнять независимые задачи параллельно в worktree;
6. независимо проверять результат;
7. автоматически выполнять retry, fallback, rollback и escalation;
8. не допускать ложный `DONE`;
9. оценивать отдельно модель, агента, prompt и workflow;
10. улучшать routing на основании объективной истории.

30 агентов — общий доступный пул, а не требование запускать всех на каждую задачу.

## Этап 1 — независимый аудит кода

Ответь по структуре:

### 1. Executive summary

- фактическая зрелость проекта;
- работает ли главный end-to-end workflow;
- пять главных достоинств;
- десять главных рисков.

### 2. Проверка заявленной архитектуры

Для каждой возможности укажи одно из:

- `IMPLEMENTED` — связана и исполняется;
- `PARTIAL` — присутствуют отдельные компоненты;
- `DOCUMENTED ONLY` — описана, но не реализована;
- `BROKEN` — реализация существует, но основной сценарий ошибочен;
- `NOT ENOUGH EVIDENCE`.

Проверь:

- dual-agent delegation;
- dynamic pool;
- project queue;
- reserve/release;
- параллельность;
- worktree isolation;
- inbox/outbox/dead-letter;
- compliance gate;
- retry/recovery;
- tracing/scoring;
- model routing;
- model evaluation;
- five-project isolation.

### 3. Code findings

Для каждого замечания дай:

- severity: Critical/High/Medium/Low;
- файл и приблизительные строки;
- наблюдаемое поведение;
- почему это проблема;
- минимальное исправление;
- правильное долгосрочное исправление;
- тест, который доказывает исправление.

### 4. Конкурентность и состояние

Проверь:

- read-modify-write races;
- duplicate assignment;
- lost update;
- stuck `busy`;
- lease/heartbeat;
- atomic task claim;
- идемпотентность;
- связь queue/registry/inbox;
- поведение при падении между двумя записями;
- возможность пяти проектов работать одновременно.

### 5. Безопасность

Проверь:

- least privilege;
- bash/edit/external-directory permissions;
- prompt injection;
- secrets;
- destructive commands;
- supply chain MCP/plugins/actions;
- worktree boundary;
- auditability;
- human approval для необратимых операций.

### 6. Model routing и evaluation

Предложи честную систему, которая различает:

- capability модели;
- reliability provider;
- качество agent prompt;
- качество workflow;
- тип/сложность/риск задачи;
- инфраструктурные ошибки;
- latency/tokens/cost;
- confidence/sample count;
- exploration/exploitation.

Укажи, какие метрики нельзя объединять в одно число.

### 7. Roadmap

Сформируй порядок P0/P1/P2 с зависимостями и критериями готовности. Не предлагай advanced AI optimization до исправления основного runtime.

### 8. Оценка идеи

Оцени концепцию отдельно от текущей реализации по шкале 1–10:

- полезность;
- реализуемость;
- масштабируемость;
- оригинальность комбинации;
- сложность эксплуатации;
- коммерческий/open-source потенциал.

Добавь собственные идеи, но раздели их на:

- необходимые;
- полезные;
- экспериментальные.

### 9. Неопределённость

Отдельно перечисли выводы, которые нельзя подтвердить без Windows/OpenCode/provider runtime.

## Этап 2 — критика существующего плана

Только после завершения независимого этапа получи:

- `PROJECT_AUDIT_2026-09-14.md`;
- `AGENT_HQ_EVOLUTION_PLAN.md`.

Затем:

1. перечисли, с чем согласен;
2. перечисли, с чем не согласен;
3. найди ошибочные или недоказанные утверждения;
4. найди пропущенные риски;
5. предложи, что удалить как overengineering;
6. предложи изменения roadmap;
7. выдай итоговый объединённый план без повторов.

## Правила честности

- Не утверждай, что запускал команды, если видел только приложенный snapshot.
- Не придумывай отсутствующие файлы и результаты тестов.
- Отделяй факт из кода от предположения.
- Не оценивай качество по объёму документации.
- Не считай существование функции доказательством её интеграции.
- Не считай непустой output доказательством успешного exit code.
- Для каждого Critical/High замечания требуй воспроизводимый тест.

# ТЕХНИЧЕСКИЙ SNAPSHOT

## File tree
```text
.agents/cards/backend-1.json
.agents/cards/backend.json
.agents/cards/code-reviewer-1.json
.agents/cards/code-reviewer.json
.agents/cards/data-engineer.json
.agents/cards/db-specialist.json
.agents/cards/dev-1-1.json
.agents/cards/dev-1.json
.agents/cards/dev-2-1.json
.agents/cards/dev-2.json
.agents/cards/dev-3-1.json
.agents/cards/dev-3.json
.agents/cards/devops.json
.agents/cards/frontend.json
.agents/cards/index.json
.agents/cards/integration-specialist.json
.agents/cards/legal-advisor.json
.agents/cards/mobile-dev.json
.agents/cards/product-manager.json
.agents/cards/qa-engineer-1.json
.agents/cards/qa-engineer.json
.agents/cards/security-auditor-1.json
.agents/cards/security-auditor.json
.agents/cards/skill-surgeon.json
.agents/cards/smm-strategist.json
.agents/cards/team-lead-1.json
.agents/cards/team-lead-2.json
.agents/cards/team-lead-3.json
.agents/cards/team-lead.json
.agents/cards/tech-writer-1.json
.agents/cards/tech-writer.json
.agents/scripts/agent-registry.ps1
.agents/scripts/agent-utilization.ps1
.agents/scripts/cleanup-garbage.ps1
.agents/scripts/compliance-gate.ps1
.agents/scripts/create-project.ps1
.agents/scripts/generate-agent-cards.ps1
.agents/scripts/health-check.ps1
.agents/scripts/inbox-poller.ps1
.agents/scripts/message-queue.ps1
.agents/scripts/model-leaderboard.ps1
.agents/scripts/project-queue.ps1
.agents/scripts/prompt-gate.ps1
.agents/scripts/run-daemons.ps1
.agents/scripts/run-poller.ps1
.agents/scripts/session-recovery.ps1
.agents/scripts/sync-agents.ps1
.agents/scripts/tui-cleanup.ps1
.agents/scripts/verify-phase.ps1
.agents/skills/1c-bsl-validate/SKILL.md
.agents/skills/1c-bsp-api/SKILL.md
.agents/skills/1c-config-index/SKILL.md
.agents/skills/1c-config-router/SKILL.md
.agents/skills/1c-dev/SKILL.md
.agents/skills/1c-edt-configurator/SKILL.md
.agents/skills/1c-epf-build/SKILL.md
.agents/skills/1c-form-patterns/SKILL.md
.agents/skills/1c-meta-edit/SKILL.md
.agents/skills/1c-naparnik/SKILL.md
.agents/skills/1c-platform-docs/SKILL.md
.agents/skills/1c-query-optimization/SKILL.md
.agents/skills/1c-query-validate/SKILL.md
.agents/skills/1c-query/SKILL.md
.agents/skills/1c-storage-ops/SKILL.md
.agents/skills/1c-support-state/SKILL.md
.agents/skills/1c-vanessa-steps/SKILL.md
.agents/skills/README.md
.agents/skills/memory-search/SKILL.md
.agents/skills/model-router/SKILL.md
.agents/skills/performance-scoring/SKILL.md
.agents/skills/plugin-system/SKILL.md
.agents/skills/self-healing/SKILL.md
.agents/skills/skill-enforcement/SKILL.md
.agents/skills/summarization/SKILL.md
.agents/skills/superpowers/implement/SKILL.md
.agents/skills/superpowers/plan/SKILL.md
.agents/skills/superpowers/spec/SKILL.md
.agents/skills/superpowers/test/SKILL.md
.agents/skills/windows-safety/SKILL.md
.agents/tasks/task-dev-1.txt
.agents/tasks/task-devops.txt
.agents/tasks/task-inbox-poller.txt
.agents/tasks/task-qa.txt
.agents/tasks/task-reviewer.txt
.agents/tasks/task-tech-writer.txt
.agents/templates/project/CONTEXT-BUFFER.md
.agents/templates/project/KNOWLEDGE-BASE.md
.agents/templates/project/README.md
.agents/templates/project/memory/.gitkeep
.agents/templates/project/project.json
.agents/templates/project/queue.json
.github/PULL_REQUEST_TEMPLATE.md
.github/workflows/verify.yml
.gitignore
.memory/activeContext.md
.memory/agent-registry.json
.memory/archive/code-reviewer-task-001.json
.memory/archive/db-specialist-task-001.json
.memory/archive/dev-1-task-001.json
.memory/archive/dev-1-test-001.json
.memory/archive/dev-2-task-001.json
.memory/archive/devops-task-001.json
.memory/archive/frontend-task-001.json
.memory/archive/qa-engineer-task-001.json
.memory/archive/skill-surgeon-task-001.json
.memory/archive/task-001.json
.memory/archive/task-002.json
.memory/archive/task-123.json
.memory/archive/tech-writer-task-001.json
.memory/decisionLog.md
.memory/outbox/task-002.json
.memory/outbox/test-001.json
.memory/productContext.md
.memory/progress.md
.memory/ratings.jsonl
.memory/reports/QA_REPORT_v2.md
.memory/reports/code_review_pong_advanced.md
.memory/reports/mcp-addition-2026-08-25.md
.memory/reports/team-report-2026-08-24.md
.memory/systemPatterns.md
.memory/tool-usage-violations.jsonl
.opencode/agents/backend-1.json
.opencode/agents/backend.json
.opencode/agents/code-reviewer-1.json
.opencode/agents/code-reviewer.json
.opencode/agents/data-engineer.json
.opencode/agents/db-specialist.json
.opencode/agents/dev-1-1.json
.opencode/agents/dev-1.json
.opencode/agents/dev-2-1.json
.opencode/agents/dev-2.json
.opencode/agents/dev-3-1.json
.opencode/agents/dev-3.json
.opencode/agents/devops.json
.opencode/agents/frontend.json
.opencode/agents/integration-specialist.json
.opencode/agents/legal-advisor.json
.opencode/agents/mobile-dev.json
.opencode/agents/product-manager.json
.opencode/agents/prompts/README.md
.opencode/agents/prompts/backend-1.txt
.opencode/agents/prompts/backend.txt
.opencode/agents/prompts/code-reviewer-1.txt
.opencode/agents/prompts/code-reviewer.txt
.opencode/agents/prompts/data-engineer.txt
.opencode/agents/prompts/db-specialist.txt
.opencode/agents/prompts/dev-1-1.txt
.opencode/agents/prompts/dev-1.txt
.opencode/agents/prompts/dev-2-1.txt
.opencode/agents/prompts/dev-2.txt
.opencode/agents/prompts/dev-3-1.txt
.opencode/agents/prompts/dev-3.txt
.opencode/agents/prompts/devops.txt
.opencode/agents/prompts/frontend.txt
.opencode/agents/prompts/integration-specialist.txt
.opencode/agents/prompts/legal-advisor.txt
.opencode/agents/prompts/mobile-dev.txt
.opencode/agents/prompts/product-manager.txt
.opencode/agents/prompts/qa-engineer-1.txt
.opencode/agents/prompts/qa-engineer.txt
.opencode/agents/prompts/security-auditor-1.txt
.opencode/agents/prompts/security-auditor.txt
.opencode/agents/prompts/skill-surgeon.txt
.opencode/agents/prompts/smm-strategist.txt
.opencode/agents/prompts/team-lead-1.txt
.opencode/agents/prompts/team-lead-2.txt
.opencode/agents/prompts/team-lead-3.txt
.opencode/agents/prompts/team-lead.txt
.opencode/agents/prompts/tech-writer-1.txt
.opencode/agents/prompts/tech-writer.txt
.opencode/agents/qa-engineer-1.json
.opencode/agents/qa-engineer.json
.opencode/agents/registry.json
.opencode/agents/security-auditor-1.json
.opencode/agents/security-auditor.json
.opencode/agents/skill-surgeon.json
.opencode/agents/smm-strategist.json
.opencode/agents/team-lead-1.json
.opencode/agents/team-lead-2.json
.opencode/agents/team-lead-3.json
.opencode/agents/team-lead.json
.opencode/agents/tech-writer-1.json
.opencode/agents/tech-writer.json
.opencode/plugins/scoring.js
.opencode/plugins/tracer.js
.serena/.gitignore
.serena/memories/code-review/simcards-db-2026-08-28.md
.serena/project.yml
AGENTS.md
AGENT_HQ_EVOLUTION_PLAN.md
AI_CODE_REVIEW_BUNDLE.md
CHANGELOG.md
CONTEXT-BUFFER.md
EXTERNAL_MODEL_REVIEW_PROMPT.md
FULL_PLAN.md
IMPROVEMENTS.md
KNOWLEDGE-BASE.md
MASTER_PLAN.md
PROJECT_AUDIT_2026-09-14.md
README.md
REQUIREMENTS-PARALLEL-PROJECTS.md
REQUIREMENTS.md
api/main.py
api/requirements.txt
docs/omnirout-setup.md
knowledge-index.md
opencode.json
```

## Runtime agent matrix

| Agent | Mode | Model | Bash | Edit | Task |
|---|---|---|---|---|---|
| backend | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| backend-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| code-reviewer | subagent | tokenrouter/z-ai/glm-5.3-free | deny | deny | deny |
| code-reviewer-1 | subagent | tokenrouter/z-ai/glm-5.3-free | deny | deny | deny |
| data-engineer | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| db-specialist | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-1-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-2 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-2-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-3 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| dev-3-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| devops | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| frontend | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| integration-specialist | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| legal-advisor | subagent | tokenrouter/z-ai/glm-5.3-free | deny | deny | deny |
| mobile-dev | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| product-manager | subagent | tokenrouter/z-ai/glm-5.3-free | deny | allow | deny |
| qa-engineer | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| qa-engineer-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| security-auditor | subagent | tokenrouter/z-ai/glm-5.3-free | deny | deny | deny |
| security-auditor-1 | subagent | tokenrouter/z-ai/glm-5.3-free | deny | deny | deny |
| skill-surgeon | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| smm-strategist | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| team-lead | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| team-lead-1 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| team-lead-2 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| team-lead-3 | subagent | tokenrouter/z-ai/glm-5.3-free | allow | allow | deny |
| tech-writer | subagent | tokenrouter/z-ai/glm-5.3-free | deny | allow | deny |
| tech-writer-1 | subagent | tokenrouter/z-ai/glm-5.3-free | deny | allow | deny |

### `README.md` lines 1-140

```markdown
    1: # agent-hq
    2: 
    3: Система оркестрации команды из **30 ИИ-агентов** поверх opencode: team-lead + product-manager (dual-agent) декомпозируют задачи и делегируют 28 субагентам, всё на бесплатных моделях, с полной наблюдаемостью, самовосстановлением и параллельными worktree.
    4: 
    5: ---
    6: 
    7: ## Содержание
    8: 
    9: 1. [Что это](#что-это)
   10: 2. [Архитектура](#архитектура)
   11: 3. [Как это работает](#как-это-работает)
   12: 4. [Быстрый старт](#быстрый-старт)
   13: 5. [Модели](#модели)
   14: 6. [MCP](#mcp)
   15: 7. [Правила эффективности](#правила-эффективности)
   16: 8. [Рейтинг моделей](#рейтинг-моделей)
   17: 9. [Безопасность Windows](#безопасность-windows)
   18: 10. [Статус реализации](#статус-реализации)
   19: 11. [Эксперименты](#эксперименты)
   20: 12. [Плюсы](#плюсы)
   21: 13. [Минусы и ограничения](#минусы-и-ограничения)
   22: 14. [Что можно добавить дальше](#что-можно-добавить-дальше)
   23: 
   24: ---
   25: 
   26: ## Что это
   27: 
   28: **agent-hq** — это мультиагентная система, построенная на [opencode](https://opencode.ai). **Dual-agent delegation**: team-lead + product-manager работают вместе на каждом запросе, декомпозируют задачу и параллельно делегируют 28 специализированным субагентам. Каждый агент работает в своём контексте (git worktree), пишет результаты в общую шину (CONTEXT-BUFFER.md), а проверяющие агенты (QA, code-reviewer, security-auditor) гарантируют качество перед финальным коммитом.
   29: 
   30: Все модели бесплатные. Стоимость: $0.
   31: 
   32: ---
   33: 
   34: ## Архитектура
   35: 
   36: ### Карта репозитория
   37: 
   38: | Файл / Папка | Назначение |
   39: |---|---|
   40: | `FULL_PLAN.md` | Единый план проекта — источник истины. Все статусы, чек-листы, дорожная карта |
   41: | `AGENTS.md` | Правила работы агентов: модели, роли, протокол, retry, команды |
   42: | `CONTEXT-BUFFER.md` | Шина контекста — обмен сообщениями между агентами (последние 30 строк читаются перед задачей) |
   43: | `opencode.json` | Главный конфиг: агенты, MCP context7, команды, модули, память, workspace |
   44: | `.opencode/agents/*.json` | 30 конфигов агентов (name, model, permissions, prompt) |
   45: | `.opencode/agents/prompts/*.txt` | 30 промптов агентов (подгружаются через `{file:...}`) |
   46: | `.opencode/agents/registry.json` | Реестр агентов со specialization matrix + required_skills |
   47: | `.opencode/plugins/tracer.js` | Плагин distributed tracing → traces.jsonl |
   48: | `.opencode/plugins/scoring.js` | Плагин performance scoring → performance.jsonl |
   49: | `.agents/scripts/` | 18 скриптов — Управление: sync-agents.ps1, verify-phase.ps1, health-check.ps1, message-queue.ps1, cleanup-garbage.ps1, generate-agent-cards.ps1; Мультипроектность: create-project.ps1 (US-011), agent-registry.ps1 (пул агентов US-012), project-queue.ps1 (очереди US-013), agent-utilization.ps1 (утилизация US-014); Quality: compliance-gate.ps1, prompt-gate.ps1, model-leaderboard.ps1; Recovery: inbox-poller.ps1, run-poller.ps1, run-daemons.ps1, session-recovery.ps1, tui-cleanup.ps1 (ручной чистильщик сессий) |
   50: | `.agents/skills/` | 24 скилла: 17 для 1С + 7 core + 4 superpowers (spec/plan/implement/test) |
   51: | `.agents/tasks/` | Задачи для агентов (текстовые файлы) |
   52: | `.agents/worktrees/` | **30 git worktrees** — изолированные песочницы для каждого агента |
   53: | `.memory/` | Memory Bank: activeContext.md, progress.md, decisionLog.md, productContext.md, systemPatterns.md |
   54: | `.memory/inbox/{agent}/` | Входящие задачи агенту (JSON) |
   55: | `.memory/outbox/` | Результаты задач (JSON, status: done) |
   56: | `.memory/dead-letter/` | Сообщения с ошибками |
   57: | `.memory/archive/` | Архив сообщений старше 7 дней |
   58: | `.memory/traces/` | Логи трейсинга |
   59: | `.memory/reports/` | Отчёты (/team-report, /cost-report) |
   60: | `projects/` | Директория проектов (test-project, news-bot, pong-advanced, 1СBuh) |
   61: 
   62: ### Структура команды
   63: 
   64: ```
   65: Пользователь
   66:     │
   67:     ▼
   68: Dual-Agent: Team Lead + Product Manager (параллельно через task tool)
   69:     │
   70:     ├── task tool → 28 субагентов (параллельно)
   71:     │       │
   72:     │       ├── Разработка: dev-1×2, dev-2×2, dev-3×2, frontend, backend×2, db-specialist, mobile-dev, devops, integration-specialist, data-engineer
   73:     │       ├── Качество: qa-engineer×2, code-reviewer×2, security-auditor×2
   74:     │       ├── Управление: product-manager, tech-writer×2, skill-surgeon
   75:     │       └── Спец: legal-advisor, smm-strategist, team-lead×4
   76:     │
   77:     ├── CONTEXT-BUFFER.md (шина сообщений, self-report с SKILLS_LOADED/MCP_USED)
   78:     ├── .memory/ (Memory Bank — контекст между сессиями)
   79:     ├── .memory/inbox/{agent}/ (задачи агентам через файловые очереди)
   80:     ├── .memory/outbox/ (результаты)
   81:     ├── .agents/skills/ (24 скилла, подгружать перед работой — обязательно)
   82:     ├── .agents/locks/ (файловые блокировки для scheduler'а)
   83:     └── .agents/scripts/session-recovery.ps1 (автовосстановление при lock conflict)
   84: ```
   85: 
   86: ---
   87: 
   88: ## Как это работает
   89: 
   90: ### Основной цикл (Dual-Agent Delegation)
   91: 
   92: ```
   93: 1. Пользователь пишет задачу в TUI opencode (build/plan режим)
   94: 2. Primary agent запускает ПАРАЛЛЕЛЬНО:
   95:    task "Analyze requirements: <task>" subagent_type=product-manager
   96:    task "Create orchestration plan: <task>" subagent_type=team-lead
   97: 3. product-manager выдаёт: User Stories, Acceptance Criteria, MoSCoW, NFR, Stack
   98: 4. team-lead выдаёт: Architecture, Tech Stack, Delegation Plan, Risks
   99: 5. Оба читают вывод друг друга в CONTEXT-BUFFER.md → синхронизация
  100: 6. team-lead параллельно делегирует исполнителей через task tool:
  101:    task "Create UI: ..." subagent_type=frontend
  102:    task "Create API: ..." subagent_type=backend
  103:    task "Design DB: ..." subagent_type=db-specialist
  104:    ...
  105: 7. Каждый агент в своём worktree:
  106:    a. Читает последние 30 строк CONTEXT-BUFFER.md
  107:    b. ОБЯЗАТЕЛЬНО: skill <нужные-скиллы> → context7 (библиотеки) → sequential-thinking (>3 шага)
  108:    c. Выполняет задачу
  109:    d. Пишет self-report в CONTEXT-BUFFER.md (SKILLS_LOADED, MCP_USED, COMPLIANCE: true)
  110: 8. Проверяющие агенты (параллельно):
  111:     - qa-engineer: тесты, edge cases
  112:     - code-reviewer: ревью кода (read-only)
  113:     - security-auditor: безопасность (read-only)
  114: 9. Финальный коммит + PR
  115: ```
  116: 
  117: ### Auto-Recovery (Session Recovery)
  118: 
  119: При конфликте файловых блокировок (`Busy: FileSystem.writeFile ... info/exclude`):
  120: 
  121: ```
  122: 1. session-recovery.ps1 (фоновый демон) обнаруживает lock conflict в трейсах
  123: 2. Находит свободную копию team-lead (team-lead-1/2/3)
  124: 3. Создаёт задачу в inbox свободной копии с флагом recovery=true
  125: 4. Записывает в CONTEXT-BUFFER.md: auto-recovery delegation
  126: 5. Новая сессия поднимается на копии → продолжает работу
  127: ```
  128: 
  129: ### Inbox Poller (автозапуск воркеров)
  130: 
  131: `inbox-poller.ps1` — мониторит `.memory/inbox/{agent}/*.json` и автоматически запускает агентов:
  132: 
  133: | Флаг | Описание |
  134: |---|---|
  135: | `-Once` | Однократный прогон (проверить и выйти) |
  136: | `-IntervalSeconds N` | Интервал проверки в секундах (по умолчанию 30) |
  137: | `-DryRun` | Без реального запуска агентов (только проверка логики) |
  138: 
  139: ---
  140: 
```

### `README.md` lines 175-340

```markdown
  175: 
  176: ---
  177: 
  178: ## Модели
  179: 
  180: | Модель | Роль | Скорость | Используется |
  181: |---|---|---|---|
  182: | `tokenrouter/z-ai/glm-5.3-free` | Основная (качество, русский) | 5-6 сек | dev-1, dev-3, frontend, legal-advisor, product-manager, skill-surgeon, smm-strategist, team-lead, tech-writer, team-lead-1/2/3, dev-1-1, dev-2-1, dev-3-1, backend-1, qa-engineer-1, security-auditor-1, code-reviewer-1, tech-writer-1 |
  183: | `opencode/nemotron-3.5-lightning-free` | Быстрая (рутина) | 3-4 сек | backend, data-engineer, db-specialist, dev-2, devops, integration-specialist, mobile-dev, dev-2-1 |
  184: | `opencode/nemotron-3-ultra-free` | Запасная (глубокий анализ) | 7-8 сек | резервная / escalation |
  185: 
  186: **Запрещены** (нет в подписке): kimi-k2.x, glm-5.x, deepseek-v4-pro/flash, qwen-plus, minimax-m2.x/m3
  187: 
  188: > Платные модели запрещены. Стоимость всегда $0.
  189: 
  190: ---
  191: 
  192: ## MCP
  193: 
  194: Три сервера подключены в проектном `opencode.json` (секция `mcp`), доступны всем агентам автоматически:
  195: 
  196: | Сервер | Назначение |
  197: |--------|-----------|
  198: | **context7** | Актуальная документация библиотек в реальном времени: свежие API, примеры, миграции |
  199: | **hermes-atlas-mcp** | Каталог 100+ скиллов/тулов экосистемы Hermes Atlas — поиск и установка готовых скиллов |
  200: | **sequential-thinking** | Структурированное пошаговое планирование сложных задач (>3 шага) |
  201: 
  202: ---
  203: 
  204: ## Правила эффективности
  205: 
  206: 1. **Dual-Agent: Team Lead + Product Manager** — на КАЖДОМ запросе запускаются вместе параллельно
  207: 2. **Team Lead не пишет код** — только конфиги, документация, правки 1-2 строк
  208: 3. **Независимые задачи — строго параллельно** — один вызов task = несколько агентов одновременно
  209: 4. **Правило лимит-3**: попытки 1-2 тем же агентом (полный лог ошибок + путь к скиллу в ТЗ); попытка 3 — другой агент + более сильная модель (lightning → mimo → ultra); после третьей неудачи — эскалация пользователю со всей историей
  210: 5. **Skills-first** — подгрузить скилл из `.agents/skills/` ДО работы (skill tool); нет нужного → skill-surgeon
  211: 6. **MCP обязательно**: context7 для библиотек, sequential-thinking для >3 шагов, hermes-atlas для новых скиллов
  212: 7. **Self-report mandatory**: каждый агент пишет SKILLS_LOADED, MCP_USED, COMPLIANCE: true в CONTEXT-BUFFER.md
  213: 7. **Никаких секретов** — пароли, токены, ключи никогда в код или логи
  214: 8. **Перед сдачей** — обязательный прогон qa-engineer + code-reviewer + security-auditor
  215: 9. **PowerShell** — не использовать `&&` (сломано в Windows), использовать `;` для разделения команд
  216: 10. **CONTEXT-BUFFER.md** — перед задачей читать последние 30 строк, после — писать результат
  217: 11. **Мини-допрос** — при приёме задачи от пользователя: задать вопросы одним батчем (с вариантами ответов), зафиксировать в ТЗ, дальше работать молча до результата или blocker'а
  218: 
  219: ---
  220: 
  221: ## Рейтинг моделей
  222: 
  223: После каждой приёмки задачи тимлид записывает оценку в `.memory/ratings.jsonl`:
  224: 
  225: ```json
  226: {"model":"glm-5.3-free (mimo недоступен: квота opencode исчерпана)","agent":"dev-1","task_type":"feature","grade":8,"date":"2026-08-26"}
  227: ```
  228: 
  229: **Поля:** `model`, `agent`, `task_type` (feature/bugfix/refactor/doc), `grade` (1-10), `date`.
  230: 
  231: **Таблица лидеров:**
  232: 
  233: ```powershell
  234: .\.agents\scripts\model-leaderboard.ps1            # все записи
  235: .\.agents\scripts\model-leaderboard.ps1 -ByModel    # по моделям
  236: .\.agents\scripts\model-leaderboard.ps1 -ByAgent    # по агентам
  237: .\.agents\scripts\model-leaderboard.ps1 -ByTaskType # по типам задач
  238: ```
  239: 
  240: Тимлид сверяется с рейтингом перед делегированием — приоритет отдаётся агентам/моделям с лучшим score.
  241: 
  242: ---
  243: 
  244: ## Безопасность Windows
  245: 
  246: Скилл `.agents/skills/windows-safety/SKILL.md` **обязателен** перед любыми загрузками, установками и запуском чужих скриптов. Основные правила:
  247: 
  248: - PowerShell 5.1: нет `&&`/`||`, только `;` и `if ($LASTEXITCODE -eq 0) {...}`
  249: - Пути с кириллицей/пробелами — всегда в кавычках
  250: - Скачивание: только официальные релизы; после скачивания — `certutil -hashfile SHA256` и сверка
  251: - Бинарники — в `.agents\tools\` (в .gitignore), НЕ в корень репо
  252: - **Kaspersky-ложняки**: Bun-бинарники ловят `PDM:Trojan.Win32.Generic` → файл удалён АВ → НЕ переустанавливать молча, а доложить пользователю (тикет в ИБ на исключение папки `.agents\tools\`)
  253: 
  254: ---
  255: 
  256: ## Статус реализации
  257: 
  258: ### A. Инфраструктура ✅
  259: Git-репо, .gitignore, структура папок, **30 git worktrees** — всё на месте.
  260: 
  261: ### B. Конфигурация ✅
  262: **30 агентов** зарегистрированы в opencode.json. Dual-agent делегирование работает end-to-end.
  263: 
  264: ### C. Команды ✅
  265: `/status`, `/sync`, `/new-project`, `/cost-report`, `/team-report` — все протестированы.
  266: 
  267: ### D. Шина контекста и память ✅
  268: Memory Bank (5 файлов), CONTEXT-BUFFER.md, AGENTS.md, message-queue.ps1 — созданы и работают.
  269: 
  270: ### E. Кодовые фичи ✅
  271: - Distributed Tracing: tracer.js → traces.jsonl
  272: - Performance Scoring: scoring.js → performance.jsonl
  273: - Health Monitoring: health-check.ps1 — HEALTH: PASS
  274: - Session Recovery: session-recovery.ps1 — автовосстановление при lock conflict
  275: - Skills+MCP Enforcement: compliance-gate.ps1 в health-check
  276: - Context Compression: compaction opencode + summarization skill
  277: 
  278: ### F. Проверки и ревью ✅
  279: - verify-phase.ps1: 29/29 PASSED
  280: - Code review infra: APPROVED
  281: - Параллельный прогон агентов — работает
  282: 
  283: ### G. Inbox Poller ✅
  284: - inbox-poller.ps1: E2E тест PASS
  285: - Code review: APPROVED
  286: 
  287: ---
  288: 
  289: ## Эксперименты
  290: 
  291: | Эксперимент | Описание | Статус |
  292: |---|---|---|
  293: | **OmniRoute** | Шлюз-ротатор бесплатных моделей (350+ провайдеров, авто-fallback) | Ожидает ключей провайдеров |
  294: | **codebase-memory-mcp** | MCP-сервер для семантического поиска по кодовой базе | Пауза: Kaspersky блокирует |
  295: 
  296: ---
  297: 
  298: ## Плюсы
  299: 
  300: | Преимущество | Описание |
  301: |---|---|
  302: | **$0 стоимость** | Все модели бесплатные |
  303: | **Полная наблюдаемость** | Traces + performance + health-check + compliance |
  304: | **Самовосстановление** | Session recovery + retry protocol + escalation |
  305: | **Dual-Agent качество** | TL + PM вместе = лучшие requirements + architecture |
  306: | **Параллелизм** | 30 worktrees + task tool параллелизм |
  307: | **Память между сессиями** | Memory Bank (5 файлов) |
  308: | **Безопасность** | Read-only проверяющие, секреты запрещены |
  309: | **Автоматизация** | inbox-poller + session-recovery + scheduler |
  310: 
  311: ---
  312: 
  313: ## Минусы и ограничения
  314: 
  315: | Ограничение | Описание |
  316: |---|---|
  317: | Кэш конфига | После правки `.opencode/agents/*.json` нужно перезапускать opencode |
  318: | Нет фоновых демонов | inbox-poller / session-recovery работают вручную или по интервалу |
  319: | Кириллица в консоли | PowerShell 5.1 может отображать UTF-8 эмодзи кракозябрами |
  320: | nemotron-3-ultra-free | Проверяющие — fallback после ухода ox-alpha-free |
  321: 
  322: ---
  323: 
  324: ## Что можно добавить дальше
  325: 
  326: | Задача | Описание |
  327: |---|---|
  328: | Task Scheduler | Автоматическое назначение задач свободным агентам (registry-state.json + locks) |
  329: | Веб-дашборд | Визуализация performance.jsonl |
  330: | CI/CD | GitHub Actions с verify-phase.ps1 |
  331: | Buffer Archive | Архивация CONTEXT-BUFFER.md каждые 100 строк |
  332: | Project Isolation | create-project.ps1 создаёт worktree + назначает agents |
  333: 
  334: ---
  335: 
  336: ## Команда
  337: 
  338: Сгенерировано мультиагентной командой agent-hq.
  339: 
  340: **30 агентов** | **opencode** | **бесплатные модели** | **$0**
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 1-105

```markdown
    1: # REQUIREMENTS.md — Масштабирование до 5 параллельных проектов
    2: 
    3: > **Версия**: 2.0.0
    4: > **Дата**: 2026-09-07
    5: > **Автор**: Product Manager (Team Lead)
    6: > **Статус**: DRAFT
    7: 
    8: ---
    9: 
   10: ## Обзор проекта
   11: 
   12: agent-hqCurrently supports 2 concurrent projects (news-bot, pong-advanced) with a single shared context buffer. The goal is to scale to **5 simultaneous projects** without agent conflicts, context leaks, or idle agents. This requires a multi-tenant architecture where each project gets isolated context, memory, and agent allocation — while agents remain a shared pool with dynamic routing.
   13: 
   14: ---
   15: 
   16: ## Текущее состояние (AS-IS)
   17: 
   18: | Компонент | Состояние | Проблема |
   19: |-----------|-----------|----------|
   20: | Агенты | 19 агентов (10 base + 9 copies) в `opencode.json` | Copies существуют для параллельной работы, но нет mechanism для автоматического выделения |
   21: | Контекст | Один общий `CONTEXT-BUFFER.md` | Все проекты пишут в одну шину — конфликты, путаница |
   22: | Memory Bank | `.memory/` общий для всех | Контекст проекта A доступен агенту проекта B |
   23: | Projects | `opencode.json` → секция `projects` (2 проекта) | Нет изоляции, нет очереди, нет балансировки |
   24: | Workspace | `sandbox_per_agent: true`, `merge_strategy: git-branch` | Worktree-песочницы есть, но нет project-level изоляции |
   25: 
   26: ---
   27: 
   28: ## User Stories
   29: 
   30: ### US-011: Multi-Project Isolation — изоляция проектов
   31: 
   32: **Как** Team Lead,
   33: **я хочу** чтобы каждый из 5 проектов имел свою изолированную область (контекст, память, агенты),
   34: **чтобы** контекст одного проекта не утекал в другой и агенты разных проектов не конфликтовали.
   35: 
   36: **Acceptance Criteria:**
   37: 
   38: | # | Критерий | Проверяемость |
   39: |---|----------|---------------|
   40: | 11.1 | Каждый проект имеет свою папку `projects/{name}/` с `CONTEXT-BUFFER.md`, `KNOWLEDGE-BASE.md`, `memory/` | `ls projects/*/CONTEXT-BUFFER.md` — 5 файлов |
   41: | 11.2 | Агент проекта A не может читать/писать контекст проекта B | Попытка доступа к чужому контексту → permission denied или пустой результат |
   42: | 11.3 | Каждый проект имеет свой git worktree или ветку | `git worktree list` — 5 изолированных рабочих пространств |
   43: | 11.4 | Один агент может работать только в одном проекте одновременно | Мониторинг: нет дублирования agent ID в разных проектах |
   44: | 11.5 | Конфиг проекта (`project.json`) определяет его тип, агентов, приоритет | Файл существует и валиден для каждого из 5 проектов |
   45: 
   46: ---
   47: 
   48: ### US-012: Dynamic Agent Pool — пул агентов с балансировкой нагрузки
   49: 
   50: **Как** Team Lead,
   51: **я хочу** чтобы агенты распределялись между проектами динамически на основе нагрузки и потребностей,
   52: **чтобы** агенты не простаивали и не были заблокированы в одном проекте, когда другой нуждается в них.
   53: 
   54: **Acceptance Criteria:**
   55: 
   56: | # | Критерий | Проверяемость |
   57: |---|----------|---------------|
   58: | 12.1 | Существует `agent-registry.json` с текущим статусом каждого агента (free/busy/error) | `cat .memory/agent-registry.json` — JSON с 19 записями |
   59: | 12.2 | При назначении задачи агент выбирается из свободных по специализации | Лог: агент назначен, статус → busy |
   60: | 12.3 | После завершения задачи агент возвращается в пул (status → free) | Лог: агент освобождён |
   61: | 12.4 | Если все агенты нужной специализации заняты — задача ставится в очередь (не отбрасывается) | Задача в очереди с timestamp, не lost |
   62: | 12.5 | Load balancing: utilization > 80% при 5 проектах | Метрика из `agent-registry.json`: busy_count / total_count > 0.8 |
   63: 
   64: ---
   65: 
   66: ### US-013: Project Queue — очередь задач на проект с приоритетами
   67: 
   68: **Как** Team Lead,
   69: **я хочу** чтобы у каждого проекта была очередь задач с приоритетами (critical/high/normal/low),
   70: **чтобы** критические задачи выполнялись первыми, а очереди не блокировали другие проекты.
   71: 
   72: **Acceptance Criteria:**
   73: 
   74: | # | Критерий | Проверяемость |
   75: |---|----------|---------------|
   76: | 13.1 | Каждый проект имеет `projects/{name}/queue.json` с массивом задач | Файл существует, валидный JSON |
   77: | 13.2 | Задачи в очереди имеют поля: `id, title, priority, status, assigned_agent, created_at, started_at` | Schema check |
   78: | 13.3 | Приоритеты: `critical > high > normal > low` — критические задачи берутся первыми | Лог: critical задача назначена раньше normal |
   79: | 13.4 | Максимальное время в очереди (queue time) < 5 минут для high+ | Метрика: `started_at - created_at < 300s` для priority >= high |
   80: | 13.5 | Задачи с deadlock (агент ждёт ресурс, который держит другой агент того же проекта) обнаруживается и resolution через timeout | Timeout → reassign |
   81: 
   82: ---
   83: 
   84: ### US-014: Resource Awareness — знание кто свободен/занят
   85: 
   86: **Как** Team Lead,
   87: **я хочу** видеть в реальном времени кто из агентов свободен, кто занят, и какой проект потребляет ресурсы,
   88: **чтобы** принимать обоснованные решения о перераспределении.
   89: 
   90: **Acceptance Criteria:**
   91: 
   92: | # | Критерий | Проверяемость |
   93: |---|----------|---------------|
   94: | 14.1 | Команда `/status` показывает таблицу: агент → статус (free/busy) → проект → задача | Вывод команды содержит эту таблицу |
   95: | 14.2 | Дашборд utilization: % занятых агентов по проектам | `utilization_by_project` в метриках |
   96: | 14.3 | Alert если utilization < 50% (простой) или > 90% (перегрузка) | Лог/уведомление при нарушении |
   97: | 14.4 | История назначений (кто, когда, какой проект) — аудит-лог | Файл `agent-assignments.jsonl` растёт |
   98: 
   99: ---
  100: 
  101: ### US-015: Cross-Project Knowledge — обмен знаниями между проектами
  102: 
  103: **Как** Team Lead,
  104: **я хочу** чтобы агенты проекта B могли использовать решения/паттерны из проекта A (если это применимо),
  105: **чтобы** не изобретать велосипед и использовать накопленный опыт.
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 145-260

```markdown
  145: | Cross-project code sharing (импорт модулей между проектами) | Это нарушает изоляцию; knowledge sharing — только через паттерны/решения |
  146: | ML-based load prediction | Избыточно; rule-based балансировки достаточно на этапе 5 проектов |
  147: 
  148: ---
  149: 
  150: ## Архитектурное решение: почему копии НЕ у всех агентов
  151: 
  152: ### Текущая модель копий (как есть)
  153: 
  154: ```
  155: Агент           Копия          Зачем
  156: ─────────────   ──────────     ──────────────────────────────────
  157: dev-1           dev-1-1        Параллельная работа над разными задачами
  158: dev-2           dev-2-1        То же
  159: dev-3           dev-3-1        То же
  160: backend         backend-1      То же
  161: code-reviewer   code-reviewer-1 Ревью двух проектов параллельно
  162: qa-engineer     qa-engineer-1  QA двух проектов параллельно
  163: security-auditor security-auditor-1 Аудит двух проектов
  164: team-lead       team-lead-1/2/3 Оркестрация 3+ проектов
  165: tech-writer     tech-writer-1  Документация двух проектов
  166: ```
  167: 
  168: **Почему НЕ у всех 19 агентов есть копии:**
  169: 
  170: | Группа агентов | Кол-во | Почему без копий |
  171: |----------------|--------|-------------------|
  172: | **Узкие специалисты** (db-specialist, data-engineer, mobile-dev, integration-specialist, devops) | 5 | Работают редко (раз в несколько дней). Копия простаивала бы 90% времени. Достаточно 1 экземпляра + очередь |
  173: | **Специфичные роли** (legal-advisor, smm-strategist, skill-surgeon, product-manager) | 4 | Уникальная экспертиза, копия не даёт преимущества (один и тот же промпт/модель). Бутылочное горлышко — экспертиза, не параллелизм |
  174: | **Вспомогательные** (tech-writer — уже есть копия) | 1 | Копия есть, хватает |
  175: 
  176: **Правило:** Копия создаётся когда:
  177: 1. Агент работает часто (>3 задач/день)
  178: 2. Задачи независимы (можно параллелить)
  179: 3. Стоимость копии (простой) < стоимость ожидания
  180: 
  181: **Для 5 проектов нужно добавить копии:**
  182: - `dev-1-2`, `dev-2-2`, `dev-3-2` — ещё по 1 копии каждого dev (итого 3 dev × 3 копии = 9 dev-слотов)
  183: - `backend-2` — 2-й backend (нужен для 3+ проектов с бэкендом)
  184: - `qa-engineer-2` — 2-й QA (бутылочное горлышко приёмки)
  185: - `code-reviewer-2` — 2-й ревьюер
  186: 
  187: **Итого:** 19 base + 12 copies = 31 агент-слот. Достаточно для 5 проектов с 4-6 агентами каждый.
  188: 
  189: ---
  190: 
  191: ## Delegation Routing: как работает назначение агентов
  192: 
  193: ### Текущая модель (AS-IS)
  194: 
  195: ```
  196: Пользователь → Team Lead (primary build-агент)
  197:     ↓
  198:     task tool (вызов по имени агента)
  199:     ↓
  200:     Subagent выполняет → пишет в CONTEXT-BUFFER.md
  201:     ↓
  202:     Team Lead читает результат → следующий шаг
  203: ```
  204: 
  205: **Проблема:** Team Lead сам выбирает агента вручную. Нет awareness кто свободен.
  206: 
  207: ### Целевая модель (TO-BE): Project-Aware Delegation
  208: 
  209: ```
  210: ┌─────────────────────────────────────────────────────┐
  211: │                   TEAM LEAD (оркестратор)            │
  212: │                                                      │
  213: │  1. Получает задачу из очереди проекта               │
  214: │  2. Читает project.json проекта (тип, required_skills)│
  215: │  3. Запрашивает agent-registry: кто свободен?         │
  216: │  4. Выбирает агента по: specialization + availability │
  217: │  5. Назначает: agent.status = busy, project = X       │
  218: │  6. Вызывает task tool с agent name                   │
  219: │  7. Агент работает в isolated project context         │
  220: │  8. По завершении: agent.status = free                 │
  221: │  9. Следующая задача из очереди (или другой проект)   │
  222: └─────────────────────────────────────────────────────┘
  223: ```
  224: 
  225: ### Delegation Routing — алгоритм
  226: 
  227: ```
  228: function assignAgent(task, project):
  229:     # 1. Определяем required_specialization из task.type
  230:     required = task.required_skills  # ["backend", "api"]
  231: 
  232:     # 2. Ищем свободных агентов нужной специализации
  233:     candidates = agentRegistry.filter(
  234:         specialization IN required
  235:         AND status == "free"
  236:         AND current_project == null OR current_project == task.project
  237:     )
  238: 
  239:     # 3. Сортируем по приоритету
  240:     #    a) Тот же проект (уже знаком с контекстом)
  241:     #    b) Наименьшая загрузка за день
  242:     #    c) Лучший рейтинг (.memory/ratings.jsonl)
  243:     candidates.sort(by: [same_project, daily_load, rating])
  244: 
  245:     # 4. Если нет свободных — в очередь ожидания
  246:     if candidates.empty:
  247:         task.status = "queued"
  248:         task.queued_at = now()
  249:         return null
  250: 
  251:     # 5. Назначаем лучшего кандидата
  252:     agent = candidates[0]
  253:     agent.status = "busy"
  254:     agent.current_project = task.project
  255:     agent.current_task = task.id
  256:     task.assigned_agent = agent.name
  257:     task.status = "assigned"
  258:     task.started_at = now()
  259: 
  260:     return agent
```

### `REQUIREMENTS-PARALLEL-PROJECTS.md` lines 285-384

```markdown
  285: ---
  286: 
  287: ## Нефункциональные требования
  288: 
  289: | Категория | Требование | Метрика |
  290: |-----------|-----------|---------|
  291: | **Производительность** | Назначение агента на задачу < 2 сек | Время от `task.created` до `task.started` |
  292: | **Производительность** | Queue time < 5 мин для high+ priority | `started_at - created_at < 300s` |
  293: | **Изоляция** | Контекст проекта A недоступен агенту проекта B | Security test: попытка доступа → fail |
  294: | **Масштабируемость** | 5 проектов × 6 агентов = 30 concurrent tasks без деградации | Utilization > 80%, queue time < 5 мин |
  295: | **Надёжность** | Агент не "застревает" — timeout 15 мин на задачу | Timeout → reassign → dead-letter |
  296: | **Аудит** | Каждое назначение логируется | `agent-assignments.jsonl` |
  297: | **Обратная совместимость** | Текущие 2 проекта продолжают работать без изменений | news-bot, pong-advanced — PASS |
  298: 
  299: ---
  300: 
  301: ## Рекомендуемый Tech Stack
  302: 
  303: | Компонент | Технология | Обоснование |
  304: |-----------|-----------|-------------|
  305: | **Project Isolation** | Директории `projects/{name}/` + git worktree | Простота, нативная git изоляция, Windows-совместимость |
  306: | **Agent Registry** | JSON файл `.memory/agent-registry.json` + PowerShell/Node скрипты | Консистентно с текущей архитектурой (JSON-based memory) |
  307: | **Task Queue** | JSON файлы `projects/{name}/queue.json` + скрипт `project-queue.ps1` | Простота, нет внешних зависимостей, версионируется в git |
  308: | **Load Balancing** | Rule-based (specialization + availability + rating) | Достаточно для 5 проектов; ML — избыточно |
  309: | **Monitoring** | Расширенный `/status` + `agent-utilization.ps1` | Консистентно с текущими командами |
  310: | **Knowledge Index** | `knowledge-index.md` (markdown с frontmatter) | Читаемо людьми и агентами, версионируется в git |
  311: 
  312: ---
  313: 
  314: ## Риски и зависимости
  315: 
  316: | Риск | Описание | Митигация |
  317: |------|----------|-----------|
  318: | **R1: Дедлоки** | Агент A ждёт агента B в том же проекте, B ждёт A | Timeout 15 мин → reassign → dead-letter. Мониторинг цепочек ожидания |
  319: | **R2: Бутылочное горлышко** | Все 5 проектов хотят backend одновременно | Очередь с приоритетами; dynamic priority boost для waiters |
  320: | **R3: Context leak** | Агент случайно читает контекст другого проекта | Permission check в delegation script; isolation в prompts |
  321: | **R4: Простой агентов** | При Uneven load одни проекты простаивают | Load balancing: если utilization < 50% — перераспределяем |
  322: | **R5: Сложность** | Дополнительные скрипты и файлы | Минимум new files; расширение существующих |
  323: | **Зависимость D1** | opencode.json重大项目 → перезапуск TUI | Hot-reload не поддерживается; команда `/sync` для обновления |
  324: | **Зависимость D2** | 19 агентов + copies = 31 слот в opencode.json | Проверить лимит opencode (тестировать с 31 агентом) |
  325: 
  326: ---
  327: 
  328: ## Roadmap
  329: 
  330: ### Sprint 1 (MVP Foundation) — 10 дней
  331: 
  332: **US-011: Multi-Project Isolation**
  333: 
  334: | День | Задача | Кто |
  335: |------|--------|-----|
  336: | 1-2 | Создать `projects/{name}/` структуру для 5 проектов (шаблон) | dev-1 |
  337: | 3-4 | Изолированный CONTEXT-BUFFER.md для каждого проекта | tech-writer |
  338: | 5-6 | Git worktree для каждого проекта | devops |
  339: | 7-8 | Permission boundaries: агент не видит чужой контекст | security-auditor |
  340: | 9-10 | Тест изоляции: 2 проекта параллельно, проверка на leak | qa-engineer |
  341: 
  342: ### Sprint 2 (Dynamic Pool + Queue) — 10 дней
  343: 
  344: **US-012: Dynamic Agent Pool + US-013: Project Queue**
  345: 
  346: | День | Задача | Кто |
  347: |------|--------|-----|
  348: | 1-3 | `agent-registry.json` + скрипт обновления статусов | dev-2 |
  349: | 4-6 | `project-queue.ps1`: создание/чтение/назначение из очереди | dev-3 |
  350: | 7-8 | Delegation routing: алгоритм выбора агента | backend |
  351: | 9-10 | Интеграция: Team Lead использует delegation при назначении | team-lead |
  352: 
  353: ### Sprint 3 (Monitoring + Polish) — 7 дней
  354: 
  355: **US-014: Resource Awareness**
  356: 
  357: | День | Задача | Кто |
  358: |------|--------|-----|
  359: | 1-3 | Расширенный `/status` с таблицей агентов | dev-1 |
  360: | 4-5 | `agent-utilization.ps1`: метрики по проектам | data-engineer |
  361: | 6-7 | Alerts: utilization < 50% / > 90% | devops |
  362: 
  363: ### Sprint 4 (Knowledge) — 5 дней (Could Have)
  364: 
  365: **US-015: Cross-Project Knowledge**
  366: 
  367: | День | Задача | Кто |
  368: |------|--------|-----|
  369: | 1-2 | `knowledge-index.md` структура + шаблон | tech-writer |
  370: | 3-4 | Интеграция в delegation: проверка index перед решением | backend |
  371: | 5 | Тест: агент проекта B использует паттерн проекта A | qa-engineer |
  372: 
  373: ---
  374: 
  375: ## Definition of Done
  376: 
  377: - [ ] 5 проектов работают одновременно без конфликтов контекста
  378: - [ ] Агенты не простаивают — utilization > 80%
  379: - [ ] Queue time < 5 мин для high+ priority задач
  380: - [ ] Контекст проекта A недоступен агенту проекта B (проверено security-тестом)
  381: - [ ] `/status` показывает таблицу агентов по проектам
  382: - [ ] Все существующие проекты (news-bot, pong-advanced) продолжают работать
  383: - [ ] agent-registry.json содержит актуальные статусы всех агентов
  384: - [ ] Documentation обновлена (AGENTS.md, README.md)
```

### `opencode.json` lines 1-110

```json
    1: {
    2:   "$schema": "https://opencode.ai/config.json",
    3:   "mcp": {
    4:     "context7": {
    5:       "type": "local",
    6:       "command": [
    7:         "context7-mcp.cmd"
    8:       ],
    9:       "enabled": true
   10:     },
   11:     "hermes-atlas-mcp": {
   12:       "type": "local",
   13:       "command": [
   14:         "hermes-atlas-mcp.cmd"
   15:       ],
   16:       "enabled": true
   17:     },
   18:     "sequential-thinking": {
   19:       "type": "local",
   20:       "command": [
   21:         "mcp-server-sequential-thinking.cmd"
   22:       ],
   23:       "enabled": true
   24:     },
   25:     "serena": {
   26:       "type": "local",
   27:       "command": [
   28:         "uvx",
   29:         "--from",
   30:         "git+https://github.com/oraios/serena",
   31:         "serena",
   32:         "start-mcp-server",
   33:         "--project-from-cwd"
   34:       ],
   35:       "enabled": false,
   36:       "timeout": 30000,
   37:       "cwd": ".",
   38:       "environment": {
   39:         "HTTP_PROXY": "http://127.0.0.1:3128",
   40:         "HTTPS_PROXY": "http://127.0.0.1:3128",
   41:         "NO_PROXY": "localhost,127.0.0.1,10.*,192.168.*,*.minsk.energo.net"
   42:       }
   43:     }
   44:   },
   45:   "command": {
   46:     "new-project": {
   47:       "template": "Создай новый проект в .agents/projects/ по выбранному шаблону (full-stack/api-only/mobile/data-pipeline): структуру папок, базовые конфиги, README. Используй .agents/scripts/create-project.ps1 если есть. Спроси тип проекта если не задан.",
   48:       "description": "Создать новый проект по шаблону (full-stack/api-only/mobile/data-pipeline)."
   49:     },
   50:     "cost-report": {
   51:       "template": "Сформируй отчёт по стоимости сессий: прочитай файлы из %LOCALAPPDATA%\\opencode\\agent-hq-traces\\ (traces.jsonl и performance.jsonl). Посчитай суммарные токены/время/ошибки по агентам и сессиям. Выведи таблицей. Если данных нет — сообщи об этом.",
   52:       "description": "Отчёт по стоимости и токенам из трейсов."
   53:     },
   54:     "team-report": {
   55:       "template": "Сформируй отчёт команды agent-hq: кто работал (агенты), какие задачи (из .memory/inbox/outbox), результаты ревью, рейтинг моделей (.memory/ratings.jsonl). Сохрани в .memory/reports/team-report-<date>.md.",
   56:       "description": "Сформировать отчёт команды из трейсов и Memory Bank."
   57:     },
   58:     "sync": {
   59:       "template": "Синхронизируй состояние системы: перегенерируй .memory/activeContext.md, progress.md, decisionLog.md из CONTEXT-BUFFER.md и KNOWLEDGE-BASE.md. Обнови секцию agent в opencode.json из .opencode/agents/*.json через .agents/scripts/sync-agents.ps1. Запиши результат в CONTEXT-BUFFER.md.",
   60:       "description": "Синхронизация агентов и Memory Bank из CONTEXT-BUFFER/KNOWLEDGE-BASE."
   61:     },
   62:     "status": {
   63:       "template": "Покажи статус системы agent-hq: список агентов из registry.json, состояние Memory Bank (.memory/), активные worktrees (.agents/worktrees/), результат health-check. Запусти .agents/scripts/health-check.ps1 если есть. Ответ кратко, таблицей.\n\n## Agents & Utilization\nПосле базового статуса покажи секцию 'Agents & Utilization':\n1. Запусти `.agents/scripts/agent-registry.ps1 -List` и покажи таблицу: Агент | Статус | Проект | Задача\n2. Запусти `.agents/scripts/agent-utilization.ps1` и покажи вывод: сводка, busy по проектам, free по ролям, алерты, последние 5 назначений из аудит-лога.",
   64:       "description": "Статус системы agent-hq: агенты, utilization, Memory Bank, worktrees, здоровье."
   65:     }
   66:   },
   67:   "agents": {
   68:     "backend-1": {
   69:         "description": "Backend Specialist (copy 1) — REST/GraphQL API, бизнес-логика, middleware, авторизация для параллельной работы.",
   70:         "mode": "subagent",
   71:         "model": "tokenrouter/z-ai/glm-5.3-free",
   72:         "temperature": 0.2,
   73:         "permission": {
   74:             "bash": "allow",
   75:             "edit": "allow",
   76:             "external_directory": {
   77:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
   78:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
   79:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
   80:                 "D:\\Тест\\**": "allow"
   81:             },
   82:             "glob": "allow",
   83:             "grep": "allow",
   84:             "read": "allow",
   85:             "skill": "allow",
   86:             "task": "deny"
   87:         },
   88:         "prompt": "{file:.opencode/agents/prompts/backend-1.txt}"
   89:     }
   90: ,
   91:     "backend": {
   92:         "description": "Backend Specialist — REST/GraphQL API, бизнес-логика, middleware, авторизация.",
   93:         "mode": "subagent",
   94:         "model": "tokenrouter/z-ai/glm-5.3-free",
   95:         "temperature": 0.2,
   96:         "permission": {
   97:             "bash": "allow",
   98:             "edit": "allow",
   99:             "external_directory": {
  100:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  101:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  102:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  103:                 "D:\\Тест\\**": "allow"
  104:             },
  105:             "glob": "allow",
  106:             "grep": "allow",
  107:             "read": "allow",
  108:             "skill": "allow",
  109:             "task": "deny"
  110:         },
```

### `opencode.json` lines 610-854

```json
  610:             "skill": "allow",
  611:             "task": "deny",
  612:             "webfetch": "allow"
  613:         },
  614:         "prompt": "{file:.opencode/agents/prompts/smm-strategist.txt}"
  615:     }
  616: ,
  617:     "team-lead-1": {
  618:         "description": "Team Lead (copy 1) — оркестратор для параллельной оркестрации.",
  619:         "mode": "subagent",
  620:         "model": "tokenrouter/z-ai/glm-5.3-free",
  621:         "temperature": 0.1,
  622:         "permission": {
  623:             "bash": "allow",
  624:             "edit": "allow",
  625:             "external_directory": {
  626:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  627:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  628:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  629:                 "D:\\Тест\\**": "allow"
  630:             },
  631:             "glob": "allow",
  632:             "grep": "allow",
  633:             "question": "allow",
  634:             "read": "allow",
  635:             "skill": "allow",
  636:             "task": "deny"
  637:         },
  638:         "prompt": "{file:.opencode/agents/prompts/team-lead-1.txt}"
  639:     }
  640: ,
  641:     "team-lead-2": {
  642:         "description": "Team Lead (copy 2) — оркестратор для параллельной оркестрации.",
  643:         "mode": "subagent",
  644:         "model": "tokenrouter/z-ai/glm-5.3-free",
  645:         "temperature": 0.1,
  646:         "permission": {
  647:             "bash": "allow",
  648:             "edit": "allow",
  649:             "external_directory": {
  650:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  651:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  652:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  653:                 "D:\\Тест\\**": "allow"
  654:             },
  655:             "glob": "allow",
  656:             "grep": "allow",
  657:             "question": "allow",
  658:             "read": "allow",
  659:             "skill": "allow",
  660:             "task": "deny"
  661:         },
  662:         "prompt": "{file:.opencode/agents/prompts/team-lead-2.txt}"
  663:     }
  664: ,
  665:     "team-lead-3": {
  666:         "description": "Team Lead (copy 3) — оркестратор для параллельной оркестрации.",
  667:         "mode": "subagent",
  668:         "model": "tokenrouter/z-ai/glm-5.3-free",
  669:         "temperature": 0.1,
  670:         "permission": {
  671:             "bash": "allow",
  672:             "edit": "allow",
  673:             "external_directory": {
  674:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  675:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  676:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  677:                 "D:\\Тест\\**": "allow"
  678:             },
  679:             "glob": "allow",
  680:             "grep": "allow",
  681:             "question": "allow",
  682:             "read": "allow",
  683:             "skill": "allow",
  684:             "task": "deny"
  685:         },
  686:         "prompt": "{file:.opencode/agents/prompts/team-lead-3.txt}"
  687:     }
  688: ,
  689:     "team-lead": {
  690:         "description": "Team Lead — оркестратор мультиагентной команды. Декомпозирует задачи, назначает агентов, контролирует качество.",
  691:         "mode": "subagent",
  692:         "model": "tokenrouter/z-ai/glm-5.3-free",
  693:         "temperature": 0.1,
  694:         "permission": {
  695:             "bash": "allow",
  696:             "edit": "allow",
  697:             "external_directory": {
  698:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  699:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  700:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  701:                 "D:\\Тест\\**": "allow"
  702:             },
  703:             "glob": "allow",
  704:             "grep": "allow",
  705:             "question": "allow",
  706:             "read": "allow",
  707:             "skill": "allow",
  708:             "task": "deny"
  709:         },
  710:         "prompt": "{file:.opencode/agents/prompts/team-lead.txt}"
  711:     }
  712: ,
  713:     "tech-writer-1": {
  714:         "description": "Tech Writer (copy 1) — README, API docs, changelog, архитектурная документация для параллельной работы.",
  715:         "mode": "subagent",
  716:         "model": "tokenrouter/z-ai/glm-5.3-free",
  717:         "temperature": 0.2,
  718:         "permission": {
  719:             "bash": "deny",
  720:             "edit": "allow",
  721:             "external_directory": {
  722:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  723:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  724:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  725:                 "D:\\Тест\\**": "allow"
  726:             },
  727:             "glob": "allow",
  728:             "grep": "allow",
  729:             "read": "allow",
  730:             "task": "deny"
  731:         },
  732:         "prompt": "{file:.opencode/agents/prompts/tech-writer-1.txt}"
  733:     }
  734: ,
  735:     "tech-writer": {
  736:         "description": "Tech Writer — генерирует README, API docs, changelog, архитектурную документацию.",
  737:         "mode": "subagent",
  738:         "model": "tokenrouter/z-ai/glm-5.3-free",
  739:         "temperature": 0.2,
  740:         "permission": {
  741:             "bash": "deny",
  742:             "edit": "allow",
  743:             "external_directory": {
  744:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  745:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  746:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  747:                 "D:\\Тест\\**": "allow"
  748:             },
  749:             "glob": "allow",
  750:             "grep": "allow",
  751:             "read": "allow",
  752:             "task": "deny"
  753:         },
  754:         "prompt": "{file:.opencode/agents/prompts/tech-writer.txt}"
  755:     }
  756: 
  757:   },
  758:   "memory": {
  759:     "bank_path": ".memory/",
  760:     "archive_ttl_days": 7,
  761:     "compression": {
  762:       "enabled": true,
  763:       "max_size_kb": 50,
  764:       "strategy": "summary+archive"
  765:     }
  766:   },
  767:   "compaction": {
  768:     "auto": true,
  769:     "prune": true,
  770:     "tail_turns": 12
  771:   },
  772:   "watcher": {
  773:     "ignore": [
  774:       ".memory/**",
  775:       ".agents/worktrees/**"
  776:     ]
  777:   },
  778:   "workspace": {
  779:     "root": "D:\\Тест\\agent-hq",
  780:     "sandbox_per_agent": true,
  781:     "merge_strategy": "git-branch"
  782:   },
  783:   "projects": {
  784:     "news-bot": {
  785:       "type": "telegram-bot",
  786:       "agents": [
  787:         "backend",
  788:         "devops",
  789:         "qa-engineer",
  790:         "tech-writer"
  791:       ]
  792:     },
  793:     "pong-advanced": {
  794:       "type": "full-stack",
  795:       "agents": [
  796:         "frontend",
  797:         "backend",
  798:         "devops",
  799:         "qa-engineer"
  800:       ]
  801:     }
  802:   },
  803:   "modules": {
  804:     "memory_bank": true,
  805:     "agent_sandbox": true,
  806:     "model_router": true,
  807:     "context_compression": true,
  808:     "distributed_tracing": true,
  809:     "performance_scoring": true,
  810:     "plugins": true,
  811:     "health_monitoring": true
  812:   },
  813:   "provider": {
  814:     "tokenrouter": {
  815:       "sdk": "@ai-sdk/openai-compatible",
  816:       "options": {
  817:         "baseURL": "https://api.tokenrouter.com/v1",
  818:         "apiKey": "{env:TOKENROUTER_API_KEY}"
  819:       },
  820:       "models": {
  821:         "z-ai/glm-5.3-free": {
  822:           "name": "GLM 5.3 Free (TokenRouter)"
  823:         },
  824:         "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free": {
  825:           "name": "Nemotron 3 Nano Omni Reasoning Free (TokenRouter)"
  826:         }
  827:       }
  828:     },
  829:     "openrouter": {
  830:       "models": {
  831:         "nvidia/nemotron-3.5-lightning:free": {
  832:           "name": "Nemotron Lightning (free)"
  833:         },
  834:         "nvidia/nemotron-3-ultra-550b-a55b:free": {
  835:           "name": "Nemotron Ultra (free)"
  836:         },
  837:         "z-ai/glm-5.2:free": {
  838:           "name": "GLM 5.2 (free)"
  839:         },
  840:         "cohere/north-mini-code:free": {
  841:           "name": "North Mini Code (free)"
  842:         }
  843:       }
  844:     }
  845:   },
  846:   "permission": {
  847:     "external_directory": {
  848:       "D:\\\\Тест\\\\**": "allow",
  849:       "C:\\\\Users\\\\Ermak_DS\\\\.local\\\\share\\\\opencode\\\\**": "allow",
  850:       "C:\\\\Users\\\\Ermak_DS\\\\AppData\\\\Local\\\\opencode\\\\**": "allow",
  851:       "C:\\\\Users\\\\Ermak_DS\\\\.config\\\\opencode\\\\**": "allow"
  852:     }
  853:   }
  854: }
```

### `.github/workflows/verify.yml` lines 1-38

```yaml
    1: name: verify
    2: 
    3: on:
    4:   push:
    5:     branches: [main, master]
    6:   pull_request:
    7:     branches: [main, master]
    8:   workflow_dispatch:
    9: 
   10: jobs:
   11:   verify:
   12:     runs-on: windows-latest
   13:     steps:
   14:       - name: Checkout
   15:         uses: actions/checkout@v4
   16: 
   17:       - name: Run verify-phase.ps1
   18:         shell: pwsh
   19:         working-directory: ${{ github.workspace }}
   20:         run: |
   21:           Write-Host "=== Running agent-hq phase verification ==="
   22:           & .\.agents\scripts\verify-phase.ps1
   23:           $code = $LASTEXITCODE
   24:           if ($code -ne 0) {
   25:             Write-Host "::error::verify-phase.ps1 reported failures (exit $code)"
   26:             exit $code
   27:           }
   28:           Write-Host "=== Verification passed ==="
   29: 
   30:       - name: Upload verify log
   31:         if: always()
   32:         uses: actions/upload-artifact@v4
   33:         with:
   34:           name: verify-log
   35:           path: |
   36:             .memory/
   37:             CONTEXT-BUFFER.md
   38:           retention-days: 7
```

### `.opencode/agents/team-lead.json` lines 1-20

```json
    1: {
    2:     "name":  "team-lead",
    3:     "description":  "Team Lead — оркестратор мультиагентной команды. Декомпозирует задачи, назначает агентов, контролирует качество.",
    4:     "model":  "tokenrouter/z-ai/glm-5.3-free",
    5:     "mode":  "subagent",
    6:     "temperature":  0.1,
    7:     "permissions":  [
    8:                         "edit",
    9:                         "bash",
   10:                         "read",
   11:                         "glob",
   12:                         "grep",
   13:                         "skill",
   14:                         "question"
   15:                     ],
   16:     "division":  "Management(team-lead)",
   17:     "deliverable":  "Задачи назначены + решения записаны в буфер",
   18:     "success_metric":  "Все под-задачи выполнены со STATUS: resolved",
   19:     "prompt":  "Ты — Технический Лидер мультиагентной команды разработки. Твоя задача — не писать код, а ОРГАНИЗОВЫВАТЬ его написание.\n\n## 🔴 ОБЯЗАТЕЛЬНЫЙ ПРОТОКОЛ: DUAL-AGENT DELEGATION\n**КЖДЫЙ запрос пользователя обрабатывается ВМЕСТЕ с product-manager:**\n\n```\nВСЕГДА — первым делом:\ntask \"Analyze requirements: \u003cuser_task\u003e\" subagent_type=product-manager\ntask \"Create orchestration plan: \u003cuser_task\u003e\" subagent_type=team-lead\n```\n\n1. Ты И product-manager запускаетесь ПАРАЛЛЕЛЬНО одним сообщением\n2. Читаешь вывод друг друга в CONTEXT-BUFFER.md\n3. Синхронизируетесь: product-manager даёт requirements, ты — plan + delegation\n4. Только ПОСЛЕ синхронизации запускаешь исполнителей\n\n## Обязательный протокол\n1. **Перед началом**: прочитай последние 30 строк `CONTEXT-BUFFER.md`\n\n## ИНСТРУМЕНТЫ MCP (обязательно применять)\n- context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.\n- sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.\n- hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.\nЕсли инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе.\n\n\n2. **После каждого этапа**: запиши update в `CONTEXT-BUFFER.md`\n3. **При блокере**: запиши blocker в `CONTEXT-BUFFER.md`, эскалируй пользователю\n\n## Workflow\n\n### 1. DUAL-AGENT ANALYSIS (обязательно для КАЖДОЙ задачи)\n```\ntask \"Analyze requirements: \u003cuser_task\u003e\" subagent_type=product-manager\ntask \"Create orchestration plan: \u003cuser_task\u003e\" subagent_type=team-lead\n```\n\n- product-manager выдаёт: User Stories, Acceptance Criteria, MoSCoW, NFR\n- Ты выдаёшь: Architecture, Tech Stack, Delegation Plan, Risks\n- Синхронизация через CONTEXT-BUFFER.md (читаешь вывод друг друга)\n\n### 2. Проработка требований (если нужно)\nЕсли product-manager выдал вопросы — уточни у пользователя через question tool\n\n### 3. Поиск скиллов (если нужно)\n```\ntask \"Найти скиллы для: \u003cтехнологии\u003e\" subagent_type=skill-surgeon\n```\n\n### 4. ПАРАЛЛЕЛЬНЫЙ запуск разработчиков\nВАЖНО: независимые задачи запускай в ОДНОМ сообщении — они выполнятся одновременно:\n\n```\nДля full-stack:\ntask \"Создать UI: \u003cописание\u003e\" subagent_type=frontend\ntask \"Создать API: \u003cописание\u003e\" subagent_type=backend\ntask \"Спроектировать БД: \u003cописание\u003e\" subagent_type=db-specialist\ntask \"Настроить инфраструктуру: \u003cописание\u003e\" subagent_type=devops\n\nДля API-only:\ntask \"Создать API: \u003cописание\u003e\" subagent_type=backend\ntask \"Спроектировать БД: \u003cописание\u003e\" subagent_type=db-specialist\n\nДля mobile:\ntask \"Создать мобильное приложение: \u003cописание\u003e\" subagent_type=mobile-dev\ntask \"Создать API: \u003cописание\u003e\" subagent_type=backend\n\nДля интеграций:\ntask \"Настроить интеграцию: \u003cописание\u003e\" subagent_type=integration-specialist\ntask \"Создать API-обёртку: \u003cописание\u003e\" subagent_type=backend\n\nДля данных:\ntask \"Создать ETL пайплайн: \u003cописание\u003e\" subagent_type=data-engineer\ntask \"Спроектировать DWH: \u003cописание\u003e\" subagent_type=db-specialist\n```\n\n### 5. Интеграция результатов\nКогда все разработчики вернули результат:\n- Собери воедино\n- Проверь совместимость\n- Если конфликты — разреши, уточнив у агентов\n\n### 6. Контроль качества (параллельно)\n```\ntask \"Написать тесты для: \u003cкомпоненты\u003e\" subagent_type=qa-engineer\ntask \"Проверить безопасность: \u003cкомпоненты\u003e\" subagent_type=security-auditor\n```\n\n### 7. Ревью\n```\ntask \"Code review для: \u003cкомпоненты\u003e\" subagent_type=code-reviewer\n```\n\n### 8. Документация\n```\ntask \"Создать документацию для: \u003cпроект\u003e\" subagent_type=tech-writer\n```\n\n### 9. Финал\n- Собери всё вместе\n- Покажи пользователю результат: что сделано, какими агентами, результаты тестов и ревью\n- Запиши итоговый update в `CONTEXT-BUFFER.md`\n\n## Retry-протокол (ОТКАТ + ЭСКАЛАЦИЯ)\n1. Агент вернул ошибку или завис → запиши blocker в CONTEXT-BUFFER.md\n2. **СОСТОЯНИЕ ОТКАТЫВАЕТСЯ**: откати изменения агента до его вмешательства (git checkout/restore, удали созданные им файлы)\n3. Проанализируй ошибку, уточни prompt\n4. Передай задачу **ДРУГОМУ агенту с более сильной моделью** (не тому же!):\n   ```\n   glm-5.3 (устаревшее упоминание удалено) →  →  →  → glm-5.3 → пользователь\n   ```\n5. Максимум 2 попытки на агента. После 2 неудач — откат + следующий в иерархии\n6. Иерархия исчерпана → эскалируй пользователю с полным контекстом ошибок\n\n## Auto-Recovery (NEW)\nПри ошибке \"Busy: FileSystem.writeFile\" / lock conflict:\n- session-recovery.ps1 переделегирует на свободную копию (team-lead-1/2/3)\n- Ты НЕ должны это обрабатывать вручную\n\n## Правило скиллов\n- Каждому агенту перед задачей напоминай подгрузить нужные скиллы через Skill tool (docker, git-workflow, code-review, api-design, clean-code, tdd)\n- Если нужного скилла нет — вызови skill-surgeon\n\n## Использование opencode.json команд\n- `/new-project` — создание проекта из шаблона (запусти create-project.ps1)\n- `/cost-report` — отчёт о расходах\n- `/team-report` — отчёт по работе команды"
   20: }
```

### `.opencode/agents/product-manager.json` lines 1-16

```json
    1: {
    2:   "name": "product-manager",
    3:   "description": "Product Manager — превращает размытые требования в user stories, acceptance criteria, MoSCoW.",
    4:   "model": "tokenrouter/z-ai/glm-5.3-free",
    5:   "mode": "subagent",
    6:   "temperature": 0.2,
    7:   "permissions": [
    8:     "edit",
    9:     "read",
   10:     "question"
   11:   ],
   12:   "division": "Docs&PM(product-manager)",
   13:   "deliverable": "Продуктовый спец + пользовательские истории, acceptance",
   14:   "success_metric": "Спецификация одобрена, дорожная карта обновлена",
   15:   "prompt": "Ты — Product Manager мультиагентной команды. Твоя задача — превращать размытые хотелки в чёткие требования.\n\n## 🔴 ОБЯЗАТЕЛЬНЫЙ ПРОТОКОЛ: DUAL-AGENT DELEGATION\n**Ты работаешь ВМЕСТЕ с team-lead на КАЖДОМ запросе:**\n\n```\nВСЕГДА — первым делом (параллельно с team-lead):\ntask \"Analyze requirements: <user_task>\" subagent_type=product-manager\ntask \"Create orchestration plan: <user_task>\" subagent_type=team-lead\n```\n\n1. Ты И team-lead запускаетесь ПАРАЛЛЕЛЬНО\n2. Читаешь вывод друг друга в CONTEXT-BUFFER.md\n3. Ты даёшь: requirements, user stories, AC, MoSCoW\n4. Team-lead даёт: architecture, tech stack, delegation plan\n5. Синхронизируетесь через CONTEXT-BUFFER.md\n\n## Обязательный протокол\n1. **Перед началом**: прочитай последние 30 строк `CONTEXT-BUFFER.md`\n2. Запиши результат с TYPE: update, STATUS: resolved\n\n## Что ты делаешь\n\n### 1. Получаешь задачу от пользователя (параллельно с team-lead)\nPrimary agent запускает вас обоих одновременно.\n\n### 2. Структурируешь требования\n\nВыдай в формате:\n\n```markdown\n## Обзор проекта\n<2-3 предложения — что делаем и зачем>\n\n## User Stories\n\n### US-001: <название>\n**Как** <роль>,\n**я хочу** <действие>,\n**чтобы** <цель>.\n\n**Acceptance Criteria:**\n- [ ] Критерий 1\n- [ ] Критерий 2\n- [ ] Критерий 3\n\n### US-002: ...\n\n## Приоритизация (MoSCoW)\n\n### Must Have (MVP)\n- US-001\n- US-002\n\n### Should Have\n- US-003\n\n### Could Have\n- US-004\n\n### Won't Have (this release)\n- US-005\n\n## Нефункциональные требования\n- **Производительность**: ...\n- **Безопасность**: ...\n- **Масштабируемость**: ...\n- **Доступность**: ...\n\n## Технологический стек (рекомендация)\n- **Frontend**: <стек>\n- **Backend**: <стек>\n- **Database**: <стек>\n- **Infrastructure**: <стек>\n\n## Риски и зависимости\n- Риск 1: <описание> → митигация: ...\n- Зависимость 1: <от чего/кого зависит>\n\n## Roadmap\n1. **Sprint 1 (MVP)**: US-001, US-002 — <срок>\n2. **Sprint 2**: US-003 — <срок>\n3. **Sprint 3**: US-004 — <срок>\n```\n\n### 3. Критерии хороших требований\n- User Story понятна без дополнительных вопросов\n- Acceptance Criteria проверяемы (можно написать тест)\n- Приоритеты реалистичны (MVP — минимум для запуска)\n- Стек обоснован (почему выбрали, а не альтернативу)\n\n### 4. Синхронизация с team-lead\n- Читай вывод team-lead в CONTEXT-BUFFER.md\n- Если team-lead задал вопросы через question tool — отвечай\n- Твои requirements → basis для delegation plan team-lead'а\n\n## Протокол ОТКАТА (обязателен)\n- Максимум 2 попытки. Откат при неудаче. Запиши blocker.\n\n## Правило СКИЛЛОВ (обязательно)\n- Подгружай нужные скиллы ПЕРЕД работой.\n\n## ИНСТРУМЕНТЫ MCP (обязательно применять)\n- context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.\n- sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.\n- hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.\nЕсли инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе."
   16: }
```

### `.opencode/agents/prompts/team-lead.txt` lines 1-127

```text
    1: Ты — Технический Лидер мультиагентной команды разработки. Твоя задача — не писать код, а ОРГАНИЗОВЫВАТЬ его написание.
    2: 
    3: ## 🔴 ОБЯЗАТЕЛЬНЫЙ ПРОТОКОЛ: DUAL-AGENT DELEGATION
    4: **КЖДЫЙ запрос пользователя обрабатывается ВМЕСТЕ с product-manager:**
    5: 
    6: ```
    7: ВСЕГДА — первым делом:
    8: task "Analyze requirements: <user_task>" subagent_type=product-manager
    9: task "Create orchestration plan: <user_task>" subagent_type=team-lead
   10: ```
   11: 
   12: 1. Ты И product-manager запускаетесь ПАРАЛЛЕЛЬНО одним сообщением
   13: 2. Читаешь вывод друг друга в CONTEXT-BUFFER.md
   14: 3. Синхронизируетесь: product-manager даёт requirements, ты — plan + delegation
   15: 4. Только ПОСЛЕ синхронизации запускаешь исполнителей
   16: 
   17: ## Обязательный протокол
   18: 1. **Перед началом**: прочитай последние 30 строк `CONTEXT-BUFFER.md`
   19: 
   20: ## ИНСТРУМЕНТЫ MCP (обязательно применять)
   21: - context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.
   22: - sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.
   23: - hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.
   24: Если инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе.
   25: 
   26: 
   27: 2. **После каждого этапа**: запиши update в `CONTEXT-BUFFER.md`
   28: 3. **При блокере**: запиши blocker в `CONTEXT-BUFFER.md`, эскалируй пользователю
   29: 
   30: ## Workflow
   31: 
   32: ### 1. DUAL-AGENT ANALYSIS (обязательно для КАЖДОЙ задачи)
   33: ```
   34: task "Analyze requirements: <user_task>" subagent_type=product-manager
   35: task "Create orchestration plan: <user_task>" subagent_type=team-lead
   36: ```
   37: 
   38: - product-manager выдаёт: User Stories, Acceptance Criteria, MoSCoW, NFR
   39: - Ты выдаёшь: Architecture, Tech Stack, Delegation Plan, Risks
   40: - Синхронизация через CONTEXT-BUFFER.md (читаешь вывод друг друга)
   41: 
   42: ### 2. Проработка требований (если нужно)
   43: Если product-manager выдал вопросы — уточни у пользователя через question tool
   44: 
   45: ### 3. Поиск скиллов (если нужно)
   46: ```
   47: task "Найти скиллы для: <технологии>" subagent_type=skill-surgeon
   48: ```
   49: 
   50: ### 4. ПАРАЛЛЕЛЬНЫЙ запуск разработчиков
   51: ВАЖНО: независимые задачи запускай в ОДНОМ сообщении — они выполнятся одновременно:
   52: 
   53: ```
   54: Для full-stack:
   55: task "Создать UI: <описание>" subagent_type=frontend
   56: task "Создать API: <описание>" subagent_type=backend
   57: task "Спроектировать БД: <описание>" subagent_type=db-specialist
   58: task "Настроить инфраструктуру: <описание>" subagent_type=devops
   59: 
   60: Для API-only:
   61: task "Создать API: <описание>" subagent_type=backend
   62: task "Спроектировать БД: <описание>" subagent_type=db-specialist
   63: 
   64: Для mobile:
   65: task "Создать мобильное приложение: <описание>" subagent_type=mobile-dev
   66: task "Создать API: <описание>" subagent_type=backend
   67: 
   68: Для интеграций:
   69: task "Настроить интеграцию: <описание>" subagent_type=integration-specialist
   70: task "Создать API-обёртку: <описание>" subagent_type=backend
   71: 
   72: Для данных:
   73: task "Создать ETL пайплайн: <описание>" subagent_type=data-engineer
   74: task "Спроектировать DWH: <описание>" subagent_type=db-specialist
   75: ```
   76: 
   77: ### 5. Интеграция результатов
   78: Когда все разработчики вернули результат:
   79: - Собери воедино
   80: - Проверь совместимость
   81: - Если конфликты — разреши, уточнив у агентов
   82: 
   83: ### 6. Контроль качества (параллельно)
   84: ```
   85: task "Написать тесты для: <компоненты>" subagent_type=qa-engineer
   86: task "Проверить безопасность: <компоненты>" subagent_type=security-auditor
   87: ```
   88: 
   89: ### 7. Ревью
   90: ```
   91: task "Code review для: <компоненты>" subagent_type=code-reviewer
   92: ```
   93: 
   94: ### 8. Документация
   95: ```
   96: task "Создать документацию для: <проект>" subagent_type=tech-writer
   97: ```
   98: 
   99: ### 9. Финал
  100: - Собери всё вместе
  101: - Покажи пользователю результат: что сделано, какими агентами, результаты тестов и ревью
  102: - Запиши итоговый update в `CONTEXT-BUFFER.md`
  103: 
  104: ## Retry-протокол (ОТКАТ + ЭСКАЛАЦИЯ)
  105: 1. Агент вернул ошибку или завис → запиши blocker в CONTEXT-BUFFER.md
  106: 2. **СОСТОЯНИЕ ОТКАТЫВАЕТСЯ**: откати изменения агента до его вмешательства (git checkout/restore, удали созданные им файлы)
  107: 3. Проанализируй ошибку, уточни prompt
  108: 4. Передай задачу **ДРУГОМУ агенту с более сильной моделью** (не тому же!):
  109:    ```
  110:    glm-5.3 (устаревшее упоминание удалено) →  →  →  → glm-5.3 → пользователь
  111:    ```
  112: 5. Максимум 2 попытки на агента. После 2 неудач — откат + следующий в иерархии
  113: 6. Иерархия исчерпана → эскалируй пользователю с полным контекстом ошибок
  114: 
  115: ## Auto-Recovery (NEW)
  116: При ошибке "Busy: FileSystem.writeFile" / lock conflict:
  117: - session-recovery.ps1 переделегирует на свободную копию (team-lead-1/2/3)
  118: - Ты НЕ должны это обрабатывать вручную
  119: 
  120: ## Правило скиллов
  121: - Каждому агенту перед задачей напоминай подгрузить нужные скиллы через Skill tool (docker, git-workflow, code-review, api-design, clean-code, tdd)
  122: - Если нужного скилла нет — вызови skill-surgeon
  123: 
  124: ## Использование opencode.json команд
  125: - `/new-project` — создание проекта из шаблона (запусти create-project.ps1)
  126: - `/cost-report` — отчёт о расходах
  127: - `/team-report` — отчёт по работе команды
```

### `.opencode/agents/prompts/product-manager.txt` lines 1-107

```text
    1: Ты — Product Manager мультиагентной команды. Твоя задача — превращать размытые хотелки в чёткие требования.
    2: 
    3: ## 🔴 ОБЯЗАТЕЛЬНЫЙ ПРОТОКОЛ: DUAL-AGENT DELEGATION
    4: **Ты работаешь ВМЕСТЕ с team-lead на КАЖДОМ запросе:**
    5: 
    6: ```
    7: ВСЕГДА — первым делом (параллельно с team-lead):
    8: task "Analyze requirements: <user_task>" subagent_type=product-manager
    9: task "Create orchestration plan: <user_task>" subagent_type=team-lead
   10: ```
   11: 
   12: 1. Ты И team-lead запускаетесь ПАРАЛЛЕЛЬНО
   13: 2. Читаешь вывод друг друга в CONTEXT-BUFFER.md
   14: 3. Ты даёшь: requirements, user stories, AC, MoSCoW
   15: 4. Team-lead даёт: architecture, tech stack, delegation plan
   16: 5. Синхронизируетесь через CONTEXT-BUFFER.md
   17: 
   18: ## Обязательный протокол
   19: 1. **Перед началом**: прочитай последние 30 строк `CONTEXT-BUFFER.md`
   20: 2. Запиши результат с TYPE: update, STATUS: resolved
   21: 
   22: ## Что ты делаешь
   23: 
   24: ### 1. Получаешь задачу от пользователя (параллельно с team-lead)
   25: Primary agent запускает вас обоих одновременно.
   26: 
   27: ### 2. Структурируешь требования
   28: 
   29: Выдай в формате:
   30: 
   31: ```markdown
   32: ## Обзор проекта
   33: <2-3 предложения — что делаем и зачем>
   34: 
   35: ## User Stories
   36: 
   37: ### US-001: <название>
   38: **Как** <роль>,
   39: **я хочу** <действие>,
   40: **чтобы** <цель>.
   41: 
   42: **Acceptance Criteria:**
   43: - [ ] Критерий 1
   44: - [ ] Критерий 2
   45: - [ ] Критерий 3
   46: 
   47: ### US-002: ...
   48: 
   49: ## Приоритизация (MoSCoW)
   50: 
   51: ### Must Have (MVP)
   52: - US-001
   53: - US-002
   54: 
   55: ### Should Have
   56: - US-003
   57: 
   58: ### Could Have
   59: - US-004
   60: 
   61: ### Won't Have (this release)
   62: - US-005
   63: 
   64: ## Нефункциональные требования
   65: - **Производительность**: ...
   66: - **Безопасность**: ...
   67: - **Масштабируемость**: ...
   68: - **Доступность**: ...
   69: 
   70: ## Технологический стек (рекомендация)
   71: - **Frontend**: <стек>
   72: - **Backend**: <стек>
   73: - **Database**: <стек>
   74: - **Infrastructure**: <стек>
   75: 
   76: ## Риски и зависимости
   77: - Риск 1: <описание> → митигация: ...
   78: - Зависимость 1: <от чего/кого зависит>
   79: 
   80: ## Roadmap
   81: 1. **Sprint 1 (MVP)**: US-001, US-002 — <срок>
   82: 2. **Sprint 2**: US-003 — <срок>
   83: 3. **Sprint 3**: US-004 — <срок>
   84: ```
   85: 
   86: ### 3. Критерии хороших требований
   87: - User Story понятна без дополнительных вопросов
   88: - Acceptance Criteria проверяемы (можно написать тест)
   89: - Приоритеты реалистичны (MVP — минимум для запуска)
   90: - Стек обоснован (почему выбрали, а не альтернативу)
   91: 
   92: ### 4. Синхронизация с team-lead
   93: - Читай вывод team-lead в CONTEXT-BUFFER.md
   94: - Если team-lead задал вопросы через question tool — отвечай
   95: - Твои requirements → basis для delegation plan team-lead'а
   96: 
   97: ## Протокол ОТКАТА (обязателен)
   98: - Максимум 2 попытки. Откат при неудаче. Запиши blocker.
   99: 
  100: ## Правило СКИЛЛОВ (обязательно)
  101: - Подгружай нужные скиллы ПЕРЕД работой.
  102: 
  103: ## ИНСТРУМЕНТЫ MCP (обязательно применять)
  104: - context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.
  105: - sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.
  106: - hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.
  107: Если инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе.
```

### `.agents/scripts/agent-registry.ps1` lines 1-160

```powershell
    1: ﻿# agent-registry.ps1 - CLI management for agent-registry.json
    2: # US-012 Dynamic Agent Pool
    3: #
    4: # Parameters:
    5: #   -Init                              Regenerate registry from .opencode/agents/registry.json
    6: #   -List [-Status free|busy|error] [-Json]  List agents
    7: #   -Reserve -Agent <name> -Project <project> -Task <taskId>  Reserve an agent
    8: #   -Release -Agent <name>             Release an agent
    9: #   -SetStatus -Agent <name> -Status <free|busy|error>  Set status manually
   10: #   -Acquire -Specialization <sp1,sp2> -Project <name>  Auto-acquire best agent
   11: 
   12: param(
   13:     [switch]$Init,
   14:     [switch]$List,
   15:     [string]$Status,
   16:     [switch]$Json,
   17:     [switch]$Reserve,
   18:     [string]$Agent,
   19:     [string]$Project,
   20:     [string]$Task,
   21:     [switch]$Release,
   22:     [switch]$SetStatus,
   23:     [switch]$Acquire,
   24:     [string]$Specialization
   25: )
   26: 
   27: $ErrorActionPreference = "Stop"
   28: 
   29: # --------------------------------------------------
   30: # Path resolution: script is in .agents/scripts/
   31: # Project root is two levels up
   32: # --------------------------------------------------
   33: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   34: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   35: 
   36: $RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
   37: $BackupPath = $RegistryPath + ".bak"
   38: $RatingsPath = Join-Path $projectRoot ".memory\ratings.jsonl"
   39: $SourceRegistryPath = Join-Path $projectRoot ".opencode\agents\registry.json"
   40: 
   41: # UTF-8 without BOM encoding
   42: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   43: 
   44: # --------------------------------------------------
   45: # Helper: Load registry JSON
   46: # --------------------------------------------------
   47: function Load-Registry {
   48:     if (-not (Test-Path $RegistryPath)) {
   49:         Write-Error "Registry file not found: $RegistryPath"
   50:         return $null
   51:     }
   52:     try {
   53:         $content = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom)
   54:         $registry = $content | ConvertFrom-Json
   55:         return $registry
   56:     } catch {
   57:         Write-Error "Failed to parse registry JSON: $_"
   58:         return $null
   59:     }
   60: }
   61: 
   62: # --------------------------------------------------
   63: # Helper: Save registry JSON with backup and validation
   64: # Creates .bak before writing, writes UTF-8 no BOM,
   65: # validates after write, restores from .bak on failure.
   66: # Uses exclusive file handle during write.
   67: # --------------------------------------------------
   68: function Save-Registry {
   69:     param([object]$data)
   70: 
   71:     # 1. Create backup before writing
   72:     if (Test-Path $RegistryPath) {
   73:         try {
   74:             Copy-Item -Path $RegistryPath -Destination $BackupPath -Force -ErrorAction Stop
   75:         } catch {
   76:             # Backup creation failure is not fatal; proceed to write
   77:         }
   78:     }
   79: 
   80:     # 2. Serialize to JSON
   81:     $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress
   82: 
   83:     # 3. Write with exclusive lock (FileShare None) and UTF-8 no BOM
   84:     $handle = [System.IO.File]::Open($RegistryPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
   85:     try {
   86:         $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
   87:         $writer.Write($jsonContent)
   88:         $writer.Flush()
   89:     } finally {
   90:         $handle.Close()
   91:     }
   92: 
   93:     # 4. Validate JSON after write
   94:     try {
   95:         $null = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom) | ConvertFrom-Json
   96:         return $true
   97:     } catch {
   98:         # 5. Restore from backup if JSON is invalid
   99:         # NOTE: Write-Warning (НЕ Write-Error) — при $ErrorActionPreference="Stop"
  100:         # Write-Error terminating-ошибка, которая прервёт скрипт раньше return $false
  101:         if (Test-Path $BackupPath) {
  102:             try {
  103:                 Copy-Item -Path $BackupPath -Destination $RegistryPath -Force -ErrorAction Stop
  104:             } catch {
  105:                 Write-Warning "Failed to restore registry from backup: $_"
  106:             }
  107:         }
  108:         Write-Warning "Registry JSON invalid after write, restored from backup"
  109:         return $false
  110:     }
  111: }
  112: 
  113: # --------------------------------------------------
  114: # Helper: Read ratings from .memory/ratings.jsonl
  115: # Returns hashtable: agent_name -> average grade (double)
  116: # Each line is a JSON object with "agent" and "grade" fields
  117: # --------------------------------------------------
  118: function Get-AgentRatings {
  119:     $ratings = @{}
  120: 
  121:     if (-not (Test-Path $RatingsPath)) {
  122:         return $ratings
  123:     }
  124: 
  125:     try {
  126:         $content = [System.IO.File]::ReadAllText($RatingsPath, $utf8NoBom)
  127:         $lines = $content -split "`n" | Where-Object { $_.Trim() -ne "" }
  128: 
  129:         $agentGrades = @{}
  130: 
  131:         foreach ($line in $lines) {
  132:             try {
  133:                 $obj = $line | ConvertFrom-Json
  134:                 $agentName = $obj.agent
  135:                 $grade = [double]$obj.grade
  136: 
  137:                 if ($agentName) {
  138:                     if (-not $agentGrades.ContainsKey($agentName)) {
  139:                         $agentGrades[$agentName] = @()
  140:                     }
  141:                     $agentGrades[$agentName] += $grade
  142:                 }
  143:             } catch {
  144:                 # Skip malformed lines
  145:             }
  146:         }
  147: 
  148:         # Compute averages
  149:         foreach ($agentName in $agentGrades.Keys) {
  150:             $grades = $agentGrades[$agentName]
  151:             $sum = 0.0
  152:             foreach ($g in $grades) { $sum += $g }
  153:             $ratings[$agentName] = $sum / $grades.Count
  154:         }
  155:     } catch {
  156:         # File read error; return empty ratings
  157:     }
  158: 
  159:     return $ratings
  160: }
```

### `.agents/scripts/agent-registry.ps1` lines 198-268

```powershell
  198: # --------------------------------------------------
  199: # Reserve agent: free -> busy + project + task + last_assignment + daily_load++
  200: # --------------------------------------------------
  201: function Reserve-Agent {
  202:     param([string]$AgentName, [string]$ProjectName, [string]$TaskId)
  203: 
  204:     $registry = Load-Registry
  205:     if (-not $registry) {
  206:         Write-Error "Could not load registry"
  207:         exit 1
  208:     }
  209: 
  210:     if (-not $registry.agents.PSObject.Properties[$AgentName]) {
  211:         Write-Error "Agent '$AgentName' not found in registry"
  212:         exit 1
  213:     }
  214: 
  215:     $agent = $registry.agents.$AgentName
  216: 
  217:     if ($agent.status -ne "free") {
  218:         Write-Error "Agent '$AgentName' is not free (status: $($agent.status))"
  219:         exit 1
  220:     }
  221: 
  222:     $agent.status = "busy"
  223:     $agent.current_project = $ProjectName
  224:     $agent.current_task = $TaskId
  225:     $agent.last_assignment = "$ProjectName-$TaskId"
  226:     $agent.daily_load++
  227: 
  228:     if (-not (Save-Registry $registry)) {
  229:         # Rollback не нужен: Save-Registry уже восстановил файл из .bak.
  230:         # In-memory откат $agent бессмысленен — объект не сохраняется.
  231:         Write-Error "Failed to save registry, rolled back from backup"
  232:         exit 1
  233:     }
  234: 
  235:     Write-Output "Agent '$AgentName' reserved for project '$ProjectName', task '$TaskId'"
  236: }
  237: 
  238: # --------------------------------------------------
  239: # Release agent: sets free, cleans project/task
  240: # --------------------------------------------------
  241: function Release-Agent {
  242:     param([string]$AgentName)
  243: 
  244:     $registry = Load-Registry
  245:     if (-not $registry) {
  246:         exit 1
  247:     }
  248: 
  249:     if (-not $registry.agents.PSObject.Properties[$AgentName]) {
  250:         Write-Error "Agent '$AgentName' not found in registry"
  251:         exit 1
  252:     }
  253: 
  254:     $agent = $registry.agents.$AgentName
  255: 
  256:     $agent.status = "free"
  257:     $agent.current_project = $null
  258:     $agent.current_task = $null
  259:     $agent.last_assignment = $null
  260:     # daily_load not decremented (daily counter)
  261: 
  262:     if (-not (Save-Registry $registry)) {
  263:         Write-Error "Failed to save registry after release"
  264:         exit 1
  265:     }
  266: 
  267:     Write-Output "Agent '$AgentName' released, status set to free"
  268: }
```

### `.agents/scripts/agent-registry.ps1` lines 303-565

```powershell
  303: # Init: regenerate registry from .opencode/agents/registry.json
  304: # Preserves daily_load and last_assignment from existing registry
  305: # --------------------------------------------------
  306: function Init-Registry {
  307:     if (-not (Test-Path $SourceRegistryPath)) {
  308:         Write-Error "Source registry not found: $SourceRegistryPath"
  309:         exit 1
  310:     }
  311: 
  312:     $sourceContent = [System.IO.File]::ReadAllText($SourceRegistryPath, $utf8NoBom)
  313:     $sourceData = $sourceContent | ConvertFrom-Json
  314: 
  315:     # Load existing registry to preserve daily_load and last_assignment
  316:     $existingAgents = @{}
  317:     if (Test-Path $RegistryPath) {
  318:         $existingRegistry = Load-Registry
  319:         if ($existingRegistry -and $existingRegistry.agents) {
  320:             foreach ($name in $existingRegistry.agents.PSObject.Properties.Name) {
  321:                 $existingAgents[$name] = $existingRegistry.agents.$name
  322:             }
  323:         }
  324:     }
  325: 
  326:     $newAgents = @{}
  327: 
  328:     foreach ($name in $sourceData.agents.PSObject.Properties.Name) {
  329:         $sourceAgent = $sourceData.agents.$name
  330: 
  331:         # Build specialization: primary + secondary from source
  332:         $spec = @()
  333:         if ($sourceAgent.specialization) {
  334:             $primary = @()
  335:             $secondary = @()
  336:             if ($sourceAgent.specialization.primary) {
  337:                 $primary = @($sourceAgent.specialization.primary)
  338:             }
  339:             if ($sourceAgent.specialization.secondary) {
  340:                 $secondary = @($sourceAgent.specialization.secondary)
  341:             }
  342:             $spec = @($primary + $secondary)
  343:         }
  344: 
  345:         # Preserve daily_load and last_assignment from existing registry
  346:         $dailyLoad = 0
  347:         $lastAssgn = $null
  348:         if ($existingAgents.ContainsKey($name)) {
  349:             $existing = $existingAgents[$name]
  350:             if ($existing.daily_load -ne $null) {
  351:                 $dailyLoad = [int]$existing.daily_load
  352:             }
  353:             $lastAssgn = $existing.last_assignment
  354:         }
  355: 
  356:         $agentObj = [PSCustomObject]@{
  357:             name             = $name
  358:             role             = $sourceAgent.role
  359:             specialization   = $spec
  360:             status           = "free"
  361:             current_project  = $null
  362:             current_task     = $null
  363:             last_assignment  = $lastAssgn
  364:             daily_load       = $dailyLoad
  365:         }
  366: 
  367:         $newAgents[$name] = $agentObj
  368:     }
  369: 
  370:     $newRegistry = [PSCustomObject]@{ agents = $newAgents }
  371: 
  372:     if (-not (Save-Registry $newRegistry)) {
  373:         Write-Error "Failed to save initialized registry"
  374:         exit 1
  375:     }
  376: 
  377:     $count = $newAgents.Count
  378:     Write-Output "Registry initialized from source ($count agents), preserving daily_load and last_assignment"
  379: }
  380: 
  381: # --------------------------------------------------
  382: # Acquire agent: select best based on specialization algorithm
  383: # - Filters: free + specialization IN required
  384: # - Sorts: same_project first, daily_load asc, rating desc (higher is better)
  385: # - Reads rating from .memory/ratings.jsonl (average grade, default 5.0)
  386: # - Reserves best agent, outputs its name
  387: # - Exit 2 if no free agent matches
  388: # --------------------------------------------------
  389: function Acquire-Agent {
  390:     param([string]$RequiredSpec, [string]$ProjectName)
  391: 
  392:     $requiredSps = $RequiredSpec -split ',' | ForEach-Object { $_.Trim() }
  393:     $requiredSps = $requiredSps | Where-Object { $_ -ne "" }
  394: 
  395:     $registry = Load-Registry
  396:     if (-not $registry) {
  397:         Write-Error "Could not load registry"
  398:         exit 1
  399:     }
  400: 
  401:     # Load agent ratings
  402:     $ratings = Get-AgentRatings
  403: 
  404:     # Filter: free agents with at least one matching specialization
  405:     $candidates = @()
  406: 
  407:     foreach ($name in $registry.agents.PSObject.Properties.Name) {
  408:         $agent = $registry.agents.$name
  409: 
  410:         if ($agent.status -ne "free") { continue }
  411: 
  412:         # Check specialization match
  413:         $agentSps = @()
  414:         if ($agent.specialization) {
  415:             $agentSps = @($agent.specialization)
  416:         }
  417:         $hasMatch = $false
  418:         foreach ($req in $requiredSps) {
  419:             foreach ($sp in $agentSps) {
  420:                 if ($sp -eq $req) {
  421:                     $hasMatch = $true
  422:                     break
  423:                 }
  424:             }
  425:             if ($hasMatch) { break }
  426:         }
  427:         if (-not $hasMatch) { continue }
  428: 
  429:         # Count matching specializations (more matches = better fit)
  430:         $matchCount = 0
  431:         foreach ($req in $requiredSps) {
  432:             foreach ($sp in $agentSps) {
  433:                 if ($sp -eq $req) { $matchCount++; break }
  434:             }
  435:         }
  436: 
  437:         # same_project: 0 if agent has no current project or same project, 1 otherwise
  438:         $sameProjNum = 0
  439:         if ($agent.current_project -and $agent.current_project -ne $ProjectName) {
  440:             $sameProjNum = 1
  441:         }
  442: 
  443:         # Get rating (default 5.0)
  444:         $rating = 5.0
  445:         if ($ratings.ContainsKey($name)) {
  446:             $rating = $ratings[$name]
  447:         }
  448: 
  449:         $candidates += [PSCustomObject]@{
  450:             Name        = $name
  451:             SameProj    = $sameProjNum
  452:             MatchCount  = $matchCount
  453:             DailyLoad   = [int]$agent.daily_load
  454:             Rating      = $rating
  455:         }
  456:     }
  457: 
  458:     if ($candidates.Count -eq 0) {
  459:         [Console]::Error.WriteLine("NO_FREE_AGENT: No free agent with specializations: $($requiredSps -join ', ') for project '$ProjectName'")
  460:         exit 2
  461:     }
  462: 
  463:     # Sort by composite score:
  464:     # same_project=0 better; matchCount higher better; daily_load lower better; rating higher better
  465:     # Composite formula (lower = better):
  466:     #   sameProj*1000000 - matchCount*10000 + dailyLoad*100 - rating*10
  467:     $scored = $candidates | ForEach-Object {
  468:         $score = [double]$_.SameProj * 1000000 - [double]$_.MatchCount * 10000 + [double]$_.DailyLoad * 100 - [double]$_.Rating * 10
  469:         [PSCustomObject]@{
  470:             Name      = $_.Name
  471:             Score     = $score
  472:             SameProj  = $_.SameProj
  473:             MatchCount = $_.MatchCount
  474:             DailyLoad = $_.DailyLoad
  475:             Rating    = $_.Rating
  476:         }
  477:     }
  478:     $sorted = $scored | Sort-Object Score
  479: 
  480:     $best = $sorted[0]
  481:     $agentName = $best.Name
  482: 
  483:     # Double-check agent is still free
  484:     $agent = $registry.agents.$agentName
  485:     if ($agent.status -ne "free") {
  486:         Write-Error "Agent '$agentName' is no longer free (race condition)"
  487:         exit 2
  488:     }
  489: 
  490:     # Reserve
  491:     $agent.status = "busy"
  492:     $agent.current_project = $ProjectName
  493:     $agent.current_task = "$ProjectName-acquire"
  494:     $agent.last_assignment = "$ProjectName-acquire"
  495:     $agent.daily_load++
  496: 
  497:     if (-not (Save-Registry $registry)) {
  498:         # Rollback не нужен: Save-Registry уже восстановил файл из .bak.
  499:         # In-memory откат $agent бессмысленен — объект не сохраняется.
  500:         Write-Error "Failed to save registry after acquire, rolled back from backup"
  501:         exit 1
  502:     }
  503: 
  504:     Write-Output "$agentName"
  505: }
  506: 
  507: # --------------------------------------------------
  508: # Main dispatch
  509: # --------------------------------------------------
  510: 
  511: if ($Init) {
  512:     Init-Registry
  513:     exit 0
  514: }
  515: 
  516: if ($List) {
  517:     List-Agents -FilterStatus $Status
  518:     exit 0
  519: }
  520: 
  521: if ($Reserve) {
  522:     if (-not $Agent -or -not $Project -or -not $Task) {
  523:         Write-Error "Reserve requires -Agent, -Project, and -Task parameters"
  524:         exit 1
  525:     }
  526:     Reserve-Agent -AgentName $Agent -ProjectName $Project -TaskId $Task
  527:     exit 0
  528: }
  529: 
  530: if ($Release) {
  531:     if (-not $Agent) {
  532:         Write-Error "Release requires -Agent parameter"
  533:         exit 1
  534:     }
  535:     Release-Agent -AgentName $Agent
  536:     exit 0
  537: }
  538: 
  539: if ($SetStatus) {
  540:     if (-not $Agent -or -not $Status) {
  541:         Write-Error "SetStatus requires -Agent and -Status parameters"
  542:         exit 1
  543:     }
  544:     Set-Status-Agent -AgentName $Agent -NewStatus $Status
  545:     exit 0
  546: }
  547: 
  548: if ($Acquire) {
  549:     if (-not $Specialization -or -not $Project) {
  550:         Write-Error "Acquire requires -Specialization and -Project parameters"
  551:         exit 1
  552:     }
  553:     Acquire-Agent -RequiredSpec $Specialization -ProjectName $Project
  554:     exit 0
  555: }
  556: 
  557: # Default: show usage
  558: Write-Output "Usage:"
  559: Write-Output "  agent-registry.ps1 -Init"
  560: Write-Output "  agent-registry.ps1 -List [-Status free|busy|error] [-Json]"
  561: Write-Output "  agent-registry.ps1 -Reserve -Agent <name> -Project <project> -Task <taskId>"
  562: Write-Output "  agent-registry.ps1 -Release -Agent <name>"
  563: Write-Output "  agent-registry.ps1 -SetStatus -Agent <name> -Status <free|busy|error>"
  564: Write-Output "  agent-registry.ps1 -Acquire -Specialization <sp1,sp2> -Project <name>"
  565: exit 1
```

### `.agents/scripts/project-queue.ps1` lines 1-215

```powershell
    1: # project-queue.ps1 - CLI task queue management for projects
    2: # US-013 Project Queue
    3: #
    4: # Parameters:
    5: #   -Add -Project <name> -Title "<task>" [-Priority critical|high|normal|low] [-Agent <name>]
    6: #   -List -Project <name> [-Status queued|assigned|in_progress|done|dead]
    7: #   -Next -Project <name>
    8: #   -Complete -Project <name> -Task <id>
    9: #   -Dead -Project <name> -Task <id> -Reason "<why>"
   10: #   -Stats -Project <name>
   11: #   -StaleCheck -Project <name>
   12: 
   13: param(
   14:     [switch]$Add,
   15:     [switch]$List,
   16:     [switch]$Next,
   17:     [switch]$Complete,
   18:     [switch]$Dead,
   19:     [switch]$Stats,
   20:     [switch]$StaleCheck,
   21:     [string]$Project,
   22:     [string]$Title,
   23:     [string]$Priority = "normal",
   24:     [string]$Agent,
   25:     [string]$Task,
   26:     [string]$Reason,
   27:     [string]$Status
   28: )
   29: 
   30: $ErrorActionPreference = "Stop"
   31: 
   32: # --------------------------------------------------
   33: # Path resolution: script is in .agents/scripts/
   34: # Project root is two levels up
   35: # --------------------------------------------------
   36: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   37: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   38: 
   39: $ProjectsRoot = Join-Path $projectRoot "projects"
   40: 
   41: # UTF-8 without BOM encoding
   42: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   43: 
   44: # Priority ordering: lower number = higher priority
   45: $PriorityOrder = @{
   46:     "critical" = 0
   47:     "high"     = 1
   48:     "normal"   = 2
   49:     "low"      = 3
   50: }
   51: 
   52: # --------------------------------------------------
   53: # Helper: Get queue.json path for project
   54: # --------------------------------------------------
   55: function Get-QueuePath {
   56:     param([string]$ProjectName)
   57:     # Security: whitelist project name + path traversal guard
   58:     if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
   59:         throw "Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-"
   60:     }
   61:     $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectsRoot "$ProjectName\queue.json"))
   62:     $rootFull = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\') + '\'
   63:     if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
   64:         throw "Path traversal detected: '$ProjectName' escapes projects root"
   65:     }
   66:     return $full
   67: }
   68: 
   69: # --------------------------------------------------
   70: # Helper: Get list of existing project names
   71: # --------------------------------------------------
   72: function Get-ExistingProjects {
   73:     $projects = @()
   74:     if (Test-Path $ProjectsRoot) {
   75:         $dirs = Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue
   76:         foreach ($d in $dirs) {
   77:             $projects += $d.Name
   78:         }
   79:     }
   80:     return $projects
   81: }
   82: 
   83: # --------------------------------------------------
   84: # Helper: Load queue JSON
   85: # Returns PSCustomObject with .tasks array
   86: # --------------------------------------------------
   87: function Load-Queue {
   88:     param([string]$ProjectName)
   89: 
   90:     $queuePath = Get-QueuePath -ProjectName $ProjectName
   91: 
   92:     if (-not (Test-Path $queuePath)) {
   93:         $existing = Get-ExistingProjects
   94:         if ($existing.Count -gt 0) {
   95:             Write-Error "Queue file not found: $queuePath`nExisting projects: $($existing -join ', ')"
   96:         } else {
   97:             Write-Error "Queue file not found: $queuePath`nNo projects found in $ProjectsRoot"
   98:         }
   99:         return $null
  100:     }
  101: 
  102:     try {
  103:         $content = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom)
  104:         $queue = $content | ConvertFrom-Json
  105:         # Ensure tasks array exists
  106:         if (-not $queue.tasks) {
  107:             $queue | Add-Member -MemberType NoteProperty -Name "tasks" -Value @() -Force
  108:         }
  109:         return $queue
  110:     } catch {
  111:         Write-Error "Failed to parse queue JSON for project '$ProjectName': $_"
  112:         return $null
  113:     }
  114: }
  115: 
  116: # --------------------------------------------------
  117: # Helper: Save queue JSON with backup and validation
  118: # Creates .bak before writing, writes UTF-8 no BOM,
  119: # validates after write, restores from .bak on failure.
  120: # --------------------------------------------------
  121: function Save-Queue {
  122:     param(
  123:         [string]$ProjectName,
  124:         [object]$data
  125:     )
  126: 
  127:     $queuePath = Get-QueuePath -ProjectName $ProjectName
  128: 
  129:     # 1. Create backup before writing
  130:     if (Test-Path $queuePath) {
  131:         $bakPath = $queuePath + ".bak"
  132:         try {
  133:             Copy-Item -Path $queuePath -Destination $bakPath -Force -ErrorAction Stop
  134:         } catch {
  135:             # Backup creation failure is not fatal; proceed to write
  136:         }
  137:     }
  138: 
  139:     # 2. Serialize to JSON
  140:     $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress
  141: 
  142:     # 3. Write with exclusive lock and UTF-8 no BOM
  143:     $handle = [System.IO.File]::Open($queuePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  144:     try {
  145:         $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
  146:         $writer.Write($jsonContent)
  147:         $writer.Flush()
  148:     } finally {
  149:         $handle.Close()
  150:     }
  151: 
  152:     # 4. Validate JSON after write
  153:     try {
  154:         $null = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom) | ConvertFrom-Json
  155:         return $true
  156:     } catch {
  157:         # 5. Restore from backup if JSON is invalid
  158:         # NOTE: Write-Warning (НЕ Write-Error) — при $ErrorActionPreference="Stop"
  159:         # Write-Error terminating-ошибка, которая прервёт скрипт раньше return $false
  160:         $bakPath = $queuePath + ".bak"
  161:         if (Test-Path $bakPath) {
  162:             try {
  163:                 Copy-Item -Path $bakPath -Destination $queuePath -Force -ErrorAction Stop
  164:             } catch {
  165:                 Write-Warning "Failed to restore queue from backup: $_"
  166:             }
  167:         }
  168:         Write-Warning "Queue JSON invalid after write, restored from backup"
  169:         return $false
  170:     }
  171: }
  172: 
  173: # --------------------------------------------------
  174: # Helper: Generate next task ID (tq-NNN)
  175: # --------------------------------------------------
  176: function Get-NextTaskId {
  177:     param([object]$Queue)
  178: 
  179:     $maxNum = 0
  180:     if ($Queue.tasks -and $Queue.tasks.Count -gt 0) {
  181:         foreach ($t in $Queue.tasks) {
  182:             if ($t.id -match "^tq-(\d+)$") {
  183:                 $num = [int]$Matches[1]
  184:                 if ($num -gt $maxNum) { $maxNum = $num }
  185:             }
  186:         }
  187:     }
  188:     $nextNum = $maxNum + 1
  189:     return "tq-{0:D3}" -f $nextNum
  190: }
  191: 
  192: # --------------------------------------------------
  193: # Helper: Get current ISO timestamp
  194: # --------------------------------------------------
  195: function Get-Now {
  196:     return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
  197: }
  198: 
  199: # --------------------------------------------------
  200: # Helper: Validate priority
  201: # --------------------------------------------------
  202: function Test-ValidPriority {
  203:     param([string]$P)
  204:     return ($P -eq "critical" -or $P -eq "high" -or $P -eq "normal" -or $P -eq "low")
  205: }
  206: 
  207: # --------------------------------------------------
  208: # Helper: Validate status
  209: # --------------------------------------------------
  210: function Test-ValidStatus {
  211:     param([string]$S)
  212:     return ($S -eq "queued" -or $S -eq "assigned" -or $S -eq "in_progress" -or $S -eq "done" -or $S -eq "dead")
  213: }
  214: 
  215: # --------------------------------------------------
```

### `.agents/scripts/project-queue.ps1` lines 216-424

```powershell
  216: # -Add: Add a task to the queue
  217: # --------------------------------------------------
  218: function Add-Task {
  219:     param(
  220:         [string]$ProjectName,
  221:         [string]$TaskTitle,
  222:         [string]$TaskPriority,
  223:         [string]$TaskAgent
  224:     )
  225: 
  226:     if (-not (Test-ValidPriority $TaskPriority)) {
  227:         Write-Error "Invalid priority '$TaskPriority'. Must be one of: critical, high, normal, low"
  228:         exit 1
  229:     }
  230: 
  231:     $queue = Load-Queue -ProjectName $ProjectName
  232:     if (-not $queue) { exit 1 }
  233: 
  234:     $taskId = Get-NextTaskId -Queue $queue
  235:     $now = Get-Now
  236: 
  237:     $taskObj = [PSCustomObject]@{
  238:         id              = $taskId
  239:         title           = $TaskTitle
  240:         priority        = $TaskPriority
  241:         status          = if ($TaskAgent) { "assigned" } else { "queued" }
  242:         assigned_agent  = $TaskAgent
  243:         created_at      = $now
  244:         started_at      = $null
  245:         completed_at    = $null
  246:         retries         = 0
  247:     }
  248: 
  249:     # Add to tasks array
  250:     $tasksList = @($queue.tasks)
  251:     $tasksList += $taskObj
  252:     $queue.tasks = $tasksList
  253: 
  254:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  255:         Write-Error "Failed to save queue after adding task"
  256:         exit 1
  257:     }
  258: 
  259:     Write-Output "Task '$taskId' added to project '$ProjectName' (priority: $TaskPriority, status: $($taskObj.status))"
  260: }
  261: 
  262: # --------------------------------------------------
  263: # -List: List tasks in the queue
  264: # --------------------------------------------------
  265: function List-Tasks {
  266:     param(
  267:         [string]$ProjectName,
  268:         [string]$FilterStatus
  269:     )
  270: 
  271:     if ($FilterStatus -and -not (Test-ValidStatus $FilterStatus)) {
  272:         Write-Error "Invalid status '$FilterStatus'. Must be one of: queued, assigned, in_progress, done, dead"
  273:         exit 1
  274:     }
  275: 
  276:     $queue = Load-Queue -ProjectName $ProjectName
  277:     if (-not $queue) { exit 1 }
  278: 
  279:     $tasks = @($queue.tasks)
  280: 
  281:     # Filter by status if specified
  282:     if ($FilterStatus) {
  283:         $tasks = $tasks | Where-Object { $_.status -eq $FilterStatus }
  284:     }
  285: 
  286:     if ($tasks.Count -eq 0) {
  287:         Write-Output "No tasks found$(if ($FilterStatus) { " with status '$FilterStatus'" }) in project '$ProjectName'"
  288:         return
  289:     }
  290: 
  291:     Write-Output "Id | Priority | Status | Agent | Title"
  292:     Write-Output "--- | --- | --- | --- | ---"
  293:     foreach ($t in $tasks) {
  294:         $agent = if ($t.assigned_agent) { $t.assigned_agent } else { "" }
  295:         Write-Output "$($t.id) | $($t.priority) | $($t.status) | $agent | $($t.title)"
  296:     }
  297: }
  298: 
  299: # --------------------------------------------------
  300: # -Next: Get next task by priority (critical > high > normal > low, FIFO within same priority)
  301: # Sets status to in_progress, sets started_at, outputs task JSON
  302: # --------------------------------------------------
  303: function Get-NextTask {
  304:     param([string]$ProjectName)
  305: 
  306:     $queue = Load-Queue -ProjectName $ProjectName
  307:     if (-not $queue) { exit 1 }
  308: 
  309:     # Filter to queued or assigned tasks only
  310:     $pending = @($queue.tasks | Where-Object { $_.status -eq "queued" -or $_.status -eq "assigned" })
  311: 
  312:     if ($pending.Count -eq 0) {
  313:         Write-Output "No pending tasks in project '$ProjectName'"
  314:         return
  315:     }
  316: 
  317:     # Sort by priority (lower number = higher priority), then by created_at (FIFO)
  318:     $sorted = $pending | Sort-Object {
  319:         $prio = $PriorityOrder[$_.priority]
  320:         if ($null -eq $prio) { 99 } else { $prio }
  321:     }, { $_.created_at }
  322: 
  323:     $nextTask = $sorted[0]
  324: 
  325:     # Update task in queue
  326:     $nextTask.status = "in_progress"
  327:     $nextTask.started_at = Get-Now
  328: 
  329:     # Save queue
  330:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  331:         Write-Error "Failed to save queue after taking next task"
  332:         exit 1
  333:     }
  334: 
  335:     # Output task as JSON
  336:     $nextTask | ConvertTo-Json -Depth 10 -Compress
  337: }
  338: 
  339: # --------------------------------------------------
  340: # -Complete: Mark task as done, release agent if assigned
  341: # --------------------------------------------------
  342: function Complete-Task {
  343:     param(
  344:         [string]$ProjectName,
  345:         [string]$TaskId
  346:     )
  347: 
  348:     $queue = Load-Queue -ProjectName $ProjectName
  349:     if (-not $queue) { exit 1 }
  350: 
  351:     $found = $false
  352:     foreach ($t in $queue.tasks) {
  353:         if ($t.id -eq $TaskId) {
  354:             $t.status = "done"
  355:             $t.completed_at = Get-Now
  356: 
  357:             # Release agent if one was assigned
  358:             if ($t.assigned_agent) {
  359:                 $agentRegistryPath = Join-Path $scriptDir "agent-registry.ps1"
  360:                 if (Test-Path $agentRegistryPath) {
  361:                     try {
  362:                         & $agentRegistryPath -Release -Agent $t.assigned_agent
  363:                     } catch {
  364:                         Write-Warning "Failed to release agent '$($t.assigned_agent)': $_"
  365:                     }
  366:                 } else {
  367:                     Write-Warning "agent-registry.ps1 not found at $agentRegistryPath, skipping agent release"
  368:                 }
  369:             }
  370: 
  371:             $found = $true
  372:             break
  373:         }
  374:     }
  375: 
  376:     if (-not $found) {
  377:         Write-Error "Task '$TaskId' not found in project '$ProjectName'"
  378:         exit 1
  379:     }
  380: 
  381:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  382:         Write-Error "Failed to save queue after completing task"
  383:         exit 1
  384:     }
  385: 
  386:     Write-Output "Task '$TaskId' marked as done in project '$ProjectName'"
  387: }
  388: 
  389: # --------------------------------------------------
  390: # -Dead: Mark task as dead with reason
  391: # --------------------------------------------------
  392: function Dead-Task {
  393:     param(
  394:         [string]$ProjectName,
  395:         [string]$TaskId,
  396:         [string]$TaskReason
  397:     )
  398: 
  399:     $queue = Load-Queue -ProjectName $ProjectName
  400:     if (-not $queue) { exit 1 }
  401: 
  402:     $found = $false
  403:     foreach ($t in $queue.tasks) {
  404:         if ($t.id -eq $TaskId) {
  405:             $t.status = "dead"
  406:             $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value $TaskReason -Force
  407:             $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
  408:             $found = $true
  409:             break
  410:         }
  411:     }
  412: 
  413:     if (-not $found) {
  414:         Write-Error "Task '$TaskId' not found in project '$ProjectName'"
  415:         exit 1
  416:     }
  417: 
  418:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  419:         Write-Error "Failed to save queue after marking task dead"
  420:         exit 1
  421:     }
  422: 
  423:     Write-Output "Task '$TaskId' marked as dead in project '$ProjectName' (reason: $TaskReason)"
  424: }
```

### `.agents/scripts/project-queue.ps1` lines 458-600

```powershell
  458: # -StaleCheck: Find in_progress tasks older than 15 min
  459: # retries < 2 -> retries++, status = queued, started_at = null
  460: # retries >= 2 -> status = dead
  461: # --------------------------------------------------
  462: function Invoke-StaleCheck {
  463:     param([string]$ProjectName)
  464: 
  465:     $queue = Load-Queue -ProjectName $ProjectName
  466:     if (-not $queue) { exit 1 }
  467: 
  468:     $now = Get-Date
  469:     $staleThreshold = New-TimeSpan -Minutes 15
  470:     $changed = 0
  471: 
  472:     foreach ($t in $queue.tasks) {
  473:         if ($t.status -ne "in_progress") { continue }
  474:         if (-not $t.started_at) { continue }
  475: 
  476:         try {
  477:             $startedAt = [DateTime]::Parse($t.started_at)
  478:         } catch {
  479:             continue
  480:         }
  481: 
  482:         $elapsed = $now - $startedAt
  483:         if ($elapsed -gt $staleThreshold) {
  484:             $retries = [int]$t.retries
  485: 
  486:             if ($retries -ge 2) {
  487:                 # Max retries reached -> dead
  488:                 $t.status = "dead"
  489:                 $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value "Stale: exceeded max retries (2) after 15min timeout" -Force
  490:                 $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
  491:                 Write-Output "Task '$($t.id)' marked dead (max retries reached)"
  492:             } else {
  493:                 # Retry: back to queued
  494:                 $t.retries = $retries + 1
  495:                 $t.status = "queued"
  496:                 $t.started_at = $null
  497:                 Write-Output "Task '$($t.id)' stale (>15min), retries=$($t.retries), moved back to queue"
  498:             }
  499:             $changed++
  500:         }
  501:     }
  502: 
  503:     if ($changed -eq 0) {
  504:         Write-Output "No stale tasks found in project '$ProjectName'"
  505:         return
  506:     }
  507: 
  508:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  509:         Write-Error "Failed to save queue after stale check"
  510:         exit 1
  511:     }
  512: 
  513:     Write-Output "Stale check complete: $changed task(s) processed in project '$ProjectName'"
  514: }
  515: 
  516: # --------------------------------------------------
  517: # Main dispatch
  518: # --------------------------------------------------
  519: 
  520: if ($Add) {
  521:     if (-not $Project -or -not $Title) {
  522:         Write-Error "Add requires -Project and -Title parameters"
  523:         exit 1
  524:     }
  525:     if (-not (Test-ValidPriority $Priority)) {
  526:         Write-Error "Invalid priority '$Priority'. Must be one of: critical, high, normal, low"
  527:         exit 1
  528:     }
  529:     Add-Task -ProjectName $Project -TaskTitle $Title -TaskPriority $Priority -TaskAgent $Agent
  530:     exit 0
  531: }
  532: 
  533: if ($List) {
  534:     if (-not $Project) {
  535:         Write-Error "List requires -Project parameter"
  536:         exit 1
  537:     }
  538:     List-Tasks -ProjectName $Project -FilterStatus $Status
  539:     exit 0
  540: }
  541: 
  542: if ($Next) {
  543:     if (-not $Project) {
  544:         Write-Error "Next requires -Project parameter"
  545:         exit 1
  546:     }
  547:     Get-NextTask -ProjectName $Project
  548:     exit 0
  549: }
  550: 
  551: if ($Complete) {
  552:     if (-not $Project -or -not $Task) {
  553:         Write-Error "Complete requires -Project and -Task parameters"
  554:         exit 1
  555:     }
  556:     Complete-Task -ProjectName $Project -TaskId $Task
  557:     exit 0
  558: }
  559: 
  560: if ($Dead) {
  561:     if (-not $Project -or -not $Task) {
  562:         Write-Error "Dead requires -Project and -Task parameters"
  563:         exit 1
  564:     }
  565:     if (-not $Reason) {
  566:         Write-Error "Dead requires -Reason parameter"
  567:         exit 1
  568:     }
  569:     Dead-Task -ProjectName $Project -TaskId $Task -TaskReason $Reason
  570:     exit 0
  571: }
  572: 
  573: if ($Stats) {
  574:     if (-not $Project) {
  575:         Write-Error "Stats requires -Project parameter"
  576:         exit 1
  577:     }
  578:     Show-Stats -ProjectName $Project
  579:     exit 0
  580: }
  581: 
  582: if ($StaleCheck) {
  583:     if (-not $Project) {
  584:         Write-Error "StaleCheck requires -Project parameter"
  585:         exit 1
  586:     }
  587:     Invoke-StaleCheck -ProjectName $Project
  588:     exit 0
  589: }
  590: 
  591: # Default: show usage
  592: Write-Output "Usage:"
  593: Write-Output "  project-queue.ps1 -Add -Project <name> -Title ""<task>"" [-Priority critical|high|normal|low] [-Agent <name>]"
  594: Write-Output "  project-queue.ps1 -List -Project <name> [-Status queued|assigned|in_progress|done|dead]"
  595: Write-Output "  project-queue.ps1 -Next -Project <name>"
  596: Write-Output "  project-queue.ps1 -Complete -Project <name> -Task <id>"
  597: Write-Output "  project-queue.ps1 -Dead -Project <name> -Task <id> -Reason ""<why>"""
  598: Write-Output "  project-queue.ps1 -Stats -Project <name>"
  599: Write-Output "  project-queue.ps1 -StaleCheck -Project <name>"
  600: exit 1
```

### `.agents/scripts/inbox-poller.ps1` lines 1-357

```powershell
    1: ﻿# Inbox Poller for agent-hq — auto-launches inbox workers
    2: # Monitors .memory\inbox\{agent}\*.json and processes messages via opencode
    3: 
    4: param(
    5:     [switch]$Once,
    6:     [int]$IntervalSeconds = 30,
    7:     [switch]$DryRun
    8: )
    9: 
   10: $Base = "D:\Тест\agent-hq"
   11: $Memory = Join-Path $Base ".memory"
   12: $Inbox = Join-Path $Memory "inbox"
   13: $Outbox = Join-Path $Memory "outbox"
   14: $Archive = Join-Path $Memory "archive"
   15: $DeadLetter = Join-Path $Memory "dead-letter"
   16: $Traces = Join-Path $Memory "traces"
   17: $TasksDir = Join-Path $Base ".agents\tasks"
   18: 
   19: # --- Global constants (DRY: magic numbers & encoding) ---
   20: $script:Utf8NoBom = [System.Text.Encoding]::GetEncoding(65001)
   21: $maxResponseLength = 4000
   22: 
   23: # Ensure required directories exist
   24: @($Inbox, $Outbox, $Archive, $DeadLetter, $Traces, $TasksDir) | ForEach-Object {
   25:     if (-not (Test-Path $_)) {
   26:         New-Item -ItemType Directory -Path $_ -Force | Out-Null
   27:     }
   28: }
   29: 
   30: # Logging function: Write-Host with timestamp + append to .memory\traces\poller.log
   31: function Write-Log {
   32:     param($msg)
   33:     try {
   34:         $date = Get-Date -Format "HH:mm:ss"
   35:         $logLine = "$date $msg"
   36:         Write-Host $logLine
   37:         $logPath = Join-Path $Traces "poller.log"
   38:         [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $script:Utf8NoBom)
   39:     } catch {
   40:         # Fallback: if file logging fails, at least Write-Host already worked above
   41:         Write-Host "$(Get-Date -Format 'HH:mm:ss') [LOG-ERROR] Failed to write log: $($_.Exception.Message)"
   42:     }
   43: }
   44: 
   45: # Global mutex to prevent concurrent execution
   46: $mutexName = "agent-hq-poller-mutex"
   47: $mutex = New-Object System.Threading.Mutex($false, $mutexName)
   48: $bCreated = $mutex.WaitOne(0)
   49: if (-not $bCreated) {
   50:     Write-Log "❌ Another instance is already running. Exit 1."
   51:     exit 1
   52: }
   53: 
   54: # Guard: check opencode in PATH
   55: if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
   56:     Write-Log "❌ opencode not found in PATH. Install opencode or add to PATH. Exit 1."
   57:     exit 1
   58: }
   59: 
   60: # Syntax check using PSParser
   61: $scriptPath = $MyInvocation.MyCommand.Definition
   62: try {
   63:     $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $scriptPath), [ref]$null) | Out-Null
   64:     Write-Log "✅ Syntax check passed (PSParser)"
   65: } catch {
   66:     Write-Log "❌ Syntax check failed (PSParser). Exit 1."
   67:     exit 1
   68: }
   69: 
   70: # --- DRY: Save TZ copy BEFORE the main loop (was dead code after infinite loop) ---
   71: $tzCopyPath = (Join-Path $TasksDir "task-inbox-poller.txt")
   72: if (-not (Test-Path $tzCopyPath)) {
   73:     Write-Log "📄 Saving TZ copy to: $tzCopyPath"
   74:     try {
   75:         $scriptContent = Get-Content -Path $scriptPath -ErrorAction Stop
   76:         [System.IO.File]::WriteAllText($tzCopyPath, ($scriptContent -join "`n"), $script:Utf8NoBom)
   77:         Write-Log "✅ TZ copy saved successfully"
   78:     } catch {
   79:         Write-Log "⚠️ Failed to save TZ copy: $($_.Exception.Message)"
   80:     }
   81: }
   82: 
   83: # Guard: empty payload → immediately dead-letter
   84: function Check-Payload {
   85:     param($msg)
   86:     if (-not $msg.payload -or $msg.payload -eq "" -or $msg.payload -eq $null) {
   87:         return $true
   88:     }
   89:     return $false
   90: }
   91: 
   92: # Format date helper: yyyy-MM-ddTHH:mm:ss
   93: function Format-DateTime {
   94:     return ("{0:yyyy-MM-ddTHH:mm:ss}" -f (Get-Date))
   95: }
   96: 
   97: # --- DRY: Dead-letter creation extracted from two copy-pasted blocks ---
   98: function Send-DeadLetter {
   99:     param(
  100:         [string]$messageId,
  101:         [string]$from,
  102:         [string]$targetAgent,
  103:         [string]$priority,
  104:         [string]$payload,
  105:         [string]$startedAt,
  106:         [string]$response,
  107:         [string]$filePath
  108:     )
  109:     $dlFinishedAt = Format-DateTime
  110:     $dlMsg = @{
  111:         id = $messageId
  112:         from = $from
  113:         to = $targetAgent
  114:         type = "failed"
  115:         priority = $priority
  116:         payload = $payload
  117:         status = "failed"
  118:         startedAt = $startedAt
  119:         finishedAt = $dlFinishedAt
  120:         response = $response
  121:     }
  122:     $jsonDL = $dlMsg | ConvertTo-Json -Depth 4
  123:     [System.IO.File]::WriteAllText((Join-Path $DeadLetter "$($messageId).json"), $jsonDL, $script:Utf8NoBom)
  124: 
  125:     # Remove original inbox file
  126:     try {
  127:         Remove-Item $filePath -Force
  128:     } catch {
  129:         Write-Log "⚠️ Failed to remove inbox file during dead-letter: $($_.Exception.Message)"
  130:     }
  131:     Write-Log "📂 Moved to dead-letter: $messageId"
  132: }
  133: 
  134: # --- DRY: Success handler extracted from two copy-pasted blocks ---
  135: function Complete-InboxFile {
  136:     param(
  137:         [string]$messageId,
  138:         [string]$from,
  139:         [string]$targetAgent,
  140:         [string]$priority,
  141:         [string]$payload,
  142:         [string]$startedAt,
  143:         [string]$response,
  144:         [string]$filePath,
  145:         [string]$fullFileName
  146:     )
  147:     # Truncate overly long responses
  148:     if ($response.Length -gt $maxResponseLength) {
  149:         $response = $response.Substring(0, $maxResponseLength)
  150:     }
  151: 
  152:     $outboxMsg = @{
  153:         id = $messageId
  154:         from = $from
  155:         to = $targetAgent
  156:         type = "result"
  157:         priority = $priority
  158:         payload = $payload
  159:         status = "done"
  160:         startedAt = $startedAt
  161:         finishedAt = Format-DateTime
  162:         response = $response
  163:     }
  164: 
  165:     $jsonOut = $outboxMsg | ConvertTo-Json -Depth 4
  166:     [System.IO.File]::WriteAllText((Join-Path $Outbox "$($messageId).json"), $jsonOut, $script:Utf8NoBom)
  167: 
  168:     # Move original inbox file to archive: {agent}-{original_name}
  169:     $archiveName = "$($targetAgent)-$($fullFileName)"
  170:     $archivePath = Join-Path $Archive $archiveName
  171:     try {
  172:         Move-Item $filePath $archivePath -Force
  173:     } catch {
  174:         Write-Log "⚠️ Failed to move to archive: $archiveName — $($_.Exception.Message)"
  175:     }
  176:     Write-Log "✅ Done: $messageId -> archived by $targetAgent"
  177: }
  178: 
  179: # Process a single inbox file
  180: function Process-InboxFile {
  181:     param($filePath, $agentName)
  182: 
  183:     $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
  184:     $fullFileName = [System.IO.Path]::GetFileName($filePath)
  185: 
  186:     try {
  187:         $content = Get-Content $filePath -Encoding UTF8
  188:         $msg = $content | ConvertFrom-Json -ErrorAction Stop
  189:     } catch {
  190:         Write-Log "❌ Failed to parse JSON: $($fileName)"
  191:         # Move to dead-letter
  192:         $dest = Join-Path $DeadLetter "$($fileName).json"
  193:         try {
  194:             Move-Item $filePath $dest -Force
  195:         } catch {
  196:             Write-Log "⚠️ Failed to move parse-error file to dead-letter: $($_.Exception.Message)"
  197:         }
  198:         Write-Log "⚠️ Moved to dead-letter due to parse error: $fileName"
  199:         return
  200:     }
  201: 
  202:     # Extract message fields with safe defaults (BUG-001: -or returns Boolean, not value)
  203:     if ($msg.id) { $messageId = $msg.id } else { $messageId = $fileName }
  204:     if ($msg.from) { $from = $msg.from } else { $from = "" }
  205:     if ($msg.to) { $to = $msg.to } else { $to = "" }
  206:     if ($msg.type) { $type = $msg.type } else { $type = "" }
  207:     if ($msg.priority) { $priority = $msg.priority } else { $priority = "normal" }
  208:     if ($msg.payload) { $payload = $msg.payload } else { $payload = "" }
  209:     if ($msg.created) { $created = $msg.created } else { $created = Format-DateTime }
  210: 
  211:     # Determine target agent: field `to`, otherwise folder name
  212:     if ($to -and $to -ne "") {
  213:         $targetAgent = $to
  214:     } else {
  215:         $targetAgent = $agentName
  216:     }
  217: 
  218:     $startedAt = Format-DateTime
  219: 
  220:     # Guard: empty payload → immediately dead-letter
  221:     if (Check-Payload $msg) {
  222:         Write-Log "💀 Empty payload — immediately dead-letter: $($messageId)"
  223:         Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
  224:             -priority $priority -payload $payload -startedAt $startedAt `
  225:             -response "Empty payload — no task to process" -filePath $filePath
  226:         return
  227:     }
  228: 
  229:     # Generate prompt (FIX: hardcoded path replaced with Join-Path)
  230:     $contextBufferPath = Join-Path $Base "CONTEXT-BUFFER.md"
  231:     $prompt = "You received a task from agent-hq bus. Read the last 30 lines of $contextBufferPath (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. TASK: $payload"
  232: 
  233:     if ($DryRun) {
  234:         Write-Log "🔍 Dry run: would process with agent '$targetAgent'"
  235:         Write-Log "🔍 Dry run prompt: $prompt"
  236:         return
  237:     }
  238: 
  239:     # Call opencode run --agent <name> "<prompt>" with 15-min hard timeout
  240:     # (prevents a hung agent from blocking the whole poller cycle forever)
  241:     Write-Log "🚀 Calling opencode run for agent: $targetAgent (timeout: 900s)"
  242:     $result = $null
  243:     $job = Start-Job -ScriptBlock {
  244:         param($agent, $taskPrompt)
  245:         & opencode run --agent $agent $taskPrompt 2>&1
  246:     } -ArgumentList $targetAgent, $prompt
  247:     $completed = Wait-Job -Job $job -Timeout 900
  248:     if ($completed) {
  249:         $result = Receive-Job -Job $job
  250:         $exitCode = 0
  251:         if (-not $result) { $exitCode = 1 }
  252:     } else {
  253:         Stop-Job -Job $job -Force
  254:         Write-Log "⏱️ TIMEOUT 900s: agent '$targetAgent' hung — job killed"
  255:         $result = "TIMEOUT: agent '$targetAgent' did not respond in 900 seconds"
  256:         $exitCode = 124
  257:     }
  258:     Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  259: 
  260:     $finishedAt = Format-DateTime
  261: 
  262:     if ($exitCode -eq 0 -and $result) {
  263:         # Success — write to outbox and archive
  264:         Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
  265:             -priority $priority -payload $payload -startedAt $startedAt `
  266:             -response $result -filePath $filePath -fullFileName $fullFileName
  267:     } else {
  268:         # Failed — 1 retry (also with timeout)
  269:         Write-Log "❌ First attempt failed (exit code: $exitCode), retrying..."
  270:         $result2 = $null
  271:         $job2 = Start-Job -ScriptBlock {
  272:             param($agent, $taskPrompt)
  273:             & opencode run --agent $agent $taskPrompt 2>&1
  274:         } -ArgumentList $targetAgent, $prompt
  275:         $completed2 = Wait-Job -Job $job2 -Timeout 900
  276:         if ($completed2) {
  277:             $result2 = Receive-Job -Job $job2
  278:             $exitCode2 = 0
  279:             if (-not $result2) { $exitCode2 = 1 }
  280:         } else {
  281:             Stop-Job -Job $job2 -Force
  282:             Write-Log "⏱️ TIMEOUT 900s on retry: agent '$targetAgent' hung — job killed"
  283:             $result2 = "TIMEOUT: retry of agent '$targetAgent' did not respond in 900 seconds"
  284:             $exitCode2 = 124
  285:         }
  286:         Remove-Job -Job $job2 -Force -ErrorAction SilentlyContinue
  287: 
  288:         if ($exitCode2 -eq 0 -and $result2) {
  289:             Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
  290:                 -priority $priority -payload $payload -startedAt $startedAt `
  291:                 -response $result2 -filePath $filePath -fullFileName $fullFileName
  292:         } else {
  293:             # Failed after retry → dead-letter
  294:             Write-Log "❌ Failed after 2 attempts — dead-letter: $messageId"
  295:             Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
  296:                 -priority $priority -payload $payload -startedAt $startedAt `
  297:                 -response "Opencode failed after 2 attempts" -filePath $filePath
  298:         }
  299:     }
  300: }
  301: 
  302: # Main processing: scan .memory\inbox\{agent}\*.json
  303: function Process-Inbox {
  304:     $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }
  305: 
  306:     foreach ($agentDir in $agentDirs) {
  307:         $agentName = $agentDir.Name
  308:         $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }
  309: 
  310:         foreach ($jsonFile in $jsonFiles) {
  311:             Process-InboxFile -filePath $jsonFile.FullName -agentName $agentName
  312:         }
  313:     }
  314: }
  315: 
  316: # Dry run mode — show plan, nothing executes
  317: if ($DryRun) {
  318:     Write-Log "🔍 Dry run mode — showing plan only"
  319: 
  320:     $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }
  321:     $foundMessages = $false
  322: 
  323:     foreach ($agentDir in $agentDirs) {
  324:         $agentName = $agentDir.Name
  325:         $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }
  326: 
  327:         foreach ($jsonFile in $jsonFiles) {
  328:             $foundMessages = $true
  329:             Write-Log "📄 Inbox file: $($jsonFile.Name) for agent: $agentName"
  330:         }
  331:     }
  332: 
  333:     if (-not $foundMessages) {
  334:         Write-Log "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
  335:         Write-Host "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
  336:     }
  337: 
  338:     exit 0
  339: }
  340: 
  341: # Main execution with Mutex try/finally for safe release
  342: try {
  343:     if ($Once) {
  344:         Process-Inbox
  345:     } else {
  346:         # Interval loop — process repeatedly
  347:         while ($true) {
  348:             Process-Inbox
  349:             Write-Log "⏳ Sleeping for $IntervalSeconds seconds before next poll"
  350:             $null = Start-Sleep -Seconds $IntervalSeconds
  351:         }
  352:     }
  353: } finally {
  354:     # Always release mutex
  355:     $mutex.ReleaseMutex()
  356:     $mutex.Dispose()
  357: }
```

### `.agents/scripts/compliance-gate.ps1` lines 1-105

```powershell
    1: # compliance-gate.ps1 — Валидация enforcement Skills+MCP
    2: # Проверяет: self-report в CONTEXT-BUFFER.md содержит SKILLS_LOADED и MCP_USED
    3: 
    4: param(
    5:     [string]$ReportPath = "CONTEXT-BUFFER.md",
    6:     [int]$LookbackHours = 24,
    7:     [switch]$Strict
    8: )
    9: 
   10: $ErrorActionPreference = "Stop"
   11: 
   12: function Test-Compliance {
   13:     param($reportPath, $lookbackHours, $strict)
   14: 
   15:     if (-not (Test-Path $reportPath)) {
   16:         Write-Error "CONTEXT-BUFFER.md not found: $reportPath"
   17:         exit 1
   18:     }
   19: 
   20:     $content = Get-Content $reportPath -Raw
   21:     $cutoff = (Get-Date).AddHours(-$lookbackHours)
   22: 
   23:     # Найти все записи TYPE: update|resolved за последние N часов
   24:     # Формат: [YYYY-MM-DD] agent >> team-lead: ... SKILLS_LOADED: [...] MCP_USED: [...] COMPLIANCE: true
   25:     $pattern = '\[(?<date>\d{4}-\d{2}-\d{2})\]?\s*(?<time>\d{2}:\d{2}:\d{2})?\s*\]\s+(?<agent>\S+)\s+>>\s+team-lead:\s*TYPE:\s+(?<type>update|resolved).*?SKILLS_LOADED:\s*(?<skills>\[.*?\]).*?MCP_USED:\s*(?<mcp>\[.*?\]).*?COMPLIANCE:\s*(?<compliance>true|false)'
   26:     $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
   27: 
   28:     $pass = 0
   29:     $fail = 0
   30:     $violations = @()
   31: 
   32:     foreach ($match in $matches) {
   33:         # Parse date - use date part only since time might not be present
   34:         $dateStr = $match.Groups['date'].Value
   35:         $timeStr = $match.Groups['time'].Value
   36:         if ($timeStr) {
   37:             $time = [DateTime]::ParseExact("$dateStr $timeStr", "yyyy-MM-dd HH:mm:ss", $null)
   38:         } else {
   39:             $time = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
   40:         }
   41:         if ($time -lt $cutoff) { continue }
   42: 
   43:         $agent = $match.Groups['agent'].Value
   44:         $skills = $match.Groups['skills'].Value
   45:         $mcp = $match.Groups['mcp'].Value
   46:         $compliance = $match.Groups['compliance'].Value
   47: 
   48:         $skillsEmpty = $skills -eq '[]' -or [string]::IsNullOrWhiteSpace($skills)
   49:         $mcpEmpty = $mcp -eq '[]' -or [string]::IsNullOrWhiteSpace($mcp)
   50:         $compOk = $compliance -eq 'true'
   51: 
   52:         $ok = (-not $skillsEmpty) -and (-not $mcpEmpty) -and $compOk
   53: 
   54:         if ($ok) {
   55:             Write-Host "  [PASS] $agent -- skills: $skills, mcp: $mcp" -ForegroundColor Green
   56:             $pass++
   57:         } else {
   58:             $reason = @()
   59:             if ($skillsEmpty) { $reason += "SKILLS_LOADED empty" }
   60:             if ($mcpEmpty) { $reason += "MCP_USED empty" }
   61:             if (-not $compOk) { $reason += "COMPLIANCE != true" }
   62:             Write-Host "  [FAIL] $agent -- $($reason -join ', ')" -ForegroundColor Red
   63:             $fail++
   64:             $violations += @{
   65:                 agent = $agent
   66:                 time = $time
   67:                 reason = $reason -join '; '
   68:             }
   69:         }
   70:     }
   71: 
   72:     if ($pass -eq 0 -and $fail -eq 0) {
   73:         Write-Host "  [INFO] No records in last $lookbackHours hours" -ForegroundColor Yellow
   74:     }
   75: 
   76:     # Логирование нарушений
   77:     if ($violations.Count -gt 0) {
   78:         $logPath = Join-Path (Split-Path $reportPath -Parent) ".memory\tool-usage-violations.jsonl"
   79:         if (-not (Test-Path (Split-Path $logPath -Parent))) {
   80:             New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null
   81:         }
   82:         foreach ($v in $violations) {
   83:             $entry = @{
   84:                 date = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
   85:                 agent = $v.agent
   86:                 missing = $v.reason
   87:                 severity = "warning"
   88:             } | ConvertTo-Json -Depth 3
   89:             Add-Content -Path $logPath -Value $entry -Encoding UTF8
   90:         }
   91:     }
   92: 
   93:     Write-Host "`n=== Compliance Summary ===" -ForegroundColor Cyan
   94:     Write-Host "Passed: $pass"
   95:     Write-Host "Failed: $fail"
   96:     Write-Host "Total:  $($pass + $fail)"
   97: 
   98:     if ($fail -gt 0) {
   99:         if ($strict) { exit 1 }
  100:         return $false
  101:     }
  102:     return $true
  103: }
  104: 
  105: Test-Compliance -reportPath $ReportPath -lookbackHours $LookbackHours -strict $Strict
```

### `.agents/scripts/session-recovery.ps1` lines 1-185

```powershell
    1: # session-recovery.ps1 — Автовосстановление сессий при lock conflict
    2: # Запускается в фоне, мониторит .local/share/opencode/snapshot/ на ошибки
    3: 
    4: param(
    5:     [int]$CheckIntervalSec = 10,
    6:     [int]$MaxRetries = 3,
    7:     [switch]$Daemon
    8: )
    9: 
   10: $ErrorActionPreference = "Continue"
   11: 
   12: $SnapshotsDir = Join-Path $env:LOCALAPPDATA "opencode\snapshot"
   13: $LockFile = Join-Path $SnapshotsDir "recovery.lock"
   14: $LogFile = Join-Path $SnapshotsDir "recovery.log"
   15: 
   16: # Ensure directories exist
   17: if (-not (Test-Path $SnapshotsDir)) {
   18:     New-Item -ItemType Directory -Path $SnapshotsDir -Force | Out-Null
   19: }
   20: 
   21: function Write-Log {
   22:     param($msg)
   23:     $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
   24:     "$timestamp $msg" | Add-Content -Path $LogFile -Encoding UTF8
   25:     Write-Host "$timestamp $msg" -ForegroundColor Cyan
   26: }
   27: 
   28: function Test-LockConflict {
   29:     # Проверяем недавние ошибки в трейсах
   30:     $TracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
   31:     $TracesPath = Join-Path $TracesDir "traces.jsonl"
   32:     if (-not (Test-Path $TracesPath)) { return $false }
   33: 
   34:     $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-2)
   35:     $lines = Get-Content $TracesPath -Tail 20 -ErrorAction SilentlyContinue
   36:     foreach ($line in $lines) {
   37:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   38:         try {
   39:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   40:             if ($null -eq $obj) { continue }
   41:             if ($obj.type -eq "error" -and $obj.ts) {
   42:                 $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
   43:                 if ($ts -ge $cutoff -and $obj.message -match "Busy|FileSystem\.writeFile|exclude") {
   44:                     return $true
   45:                 }
   46:             }
   47:         } catch { continue }
   48:     }
   49:     return $false
   50: }
   51: 
   52: function Get-FreeTeamLeadCopy {
   53:     # Проверяем какие team-lead копии свободны (нет активной задачи в inbox)
   54:     $Root = "D:\Тест\agent-hq"
   55:     $InboxDir = Join-Path $Root ".memory\inbox"
   56:     $copies = @("team-lead", "team-lead-1", "team-lead-2", "team-lead-3")
   57:     foreach ($copy in $copies) {
   58:         $agentInbox = Join-Path $InboxDir $copy
   59:         if (Test-Path $agentInbox) {
   60:             $files = Get-ChildItem -Path $agentInbox -Filter "*.json" -File -ErrorAction SilentlyContinue
   61:             if ($files.Count -eq 0) {
   62:                 return $copy
   63:             }
   64:         } else {
   65:             return $copy
   66:         }
   67:     }
   68:     return $null
   69: }
   70: 
   71: function Delegate-To-Copy {
   72:     param($copyName, $originalTask)
   73: 
   74:     Write-Log "DELEGATE: Переделегирование на $copyName"
   75: 
   76:     # Создаём задачу в inbox копии
   77:     $InboxDir = Join-Path "D:\Тест\agent-hq\.memory\inbox" $copyName
   78:     if (-not (Test-Path $InboxDir)) {
   79:         New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null
   80:     }
   81: 
   82:     $taskId = "recovery-$(Get-Random -Minimum 10000 -Maximum 99999)"
   83:     $task = @{
   84:         id = $taskId
   85:         from = "session-recovery"
   86:         to = $copyName
   87:         type = "task"
   88:         priority = "high"
   89:         payload = $originalTask
   90:         created = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
   91:         recovery = $true
   92:         retry_count = 0
   93:     } | ConvertTo-Json -Depth 4
   94: 
   95:     $taskPath = Join-Path $InboxDir "$taskId.json"
   96:     [System.IO.File]::WriteAllText($taskPath, $task, (New-Object System.Text.UTF8Encoding($false)))
   97: 
   98:     Write-Log "DELEGATE: Задача $taskId создана в $copyName inbox"
   99: 
  100:     # Записываем в CONTEXT-BUFFER.md
  101:     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  102:     $tsNow = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
  103:     $entry = "[$tsNow] session-recovery -> ${copyName}:`nTYPE: update | PRIORITY: high`nCONTENT: Auto-recovery delegation from crashed session. Original task: $originalTask. Delegated to ${copyName}.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: [""context7: offline"", ""sequential-thinking: offline""]`nCOMPLIANCE: true`nSTATUS: resolved`n"
  104:     Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
  105: }
  106: 
  107: function Main-Loop {
  108:     Write-Log "START: session-recovery daemon started (interval: ${CheckIntervalSec}s)"
  109: 
  110:     while ($true) {
  111:         try {
  112:             if (Test-LockConflict) {
  113:                 Write-Log "DETECTED: Lock conflict detected"
  114: 
  115:                 $freeCopy = Get-FreeTeamLeadCopy
  116:                 if ($freeCopy) {
  117:                     Write-Log "FREE COPY: $freeCopy available"
  118: 
  119:                     # Читаем последнюю задачу из CONTEXT-BUFFER
  120:                     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  121:                     if (Test-Path $bufferPath) {
  122:                         $content = Get-Content $bufferPath -Raw
  123:                         # Ищем последнюю задачу пользователя
  124:                         $pattern = '\[(?<time>[\d\-T:]+)\]\s+(?<agent>\S+)\s+>>\s+team-lead:.*?CONTENT:\s*(?<content>.*?)(?=\[|\Z)'
  125:                         $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  126:                         if ($match.Success) {
  127:                             $taskContent = $match.Groups['content'].Value.Trim()
  128:                             Delegate-To-Copy -copyName $freeCopy -originalTask $taskContent
  129:                         } else {
  130:                             Delegate-To-Copy -copyName $freeCopy -originalTask "Recover from lock conflict - continue previous task"
  131:                         }
  132:                     }
  133: 
  134:                     # Ждём пока новая сессия поднимется
  135:                     Start-Sleep -Seconds 30
  136:                 } else {
  137:                     Write-Log "NO FREE COPY: All team-lead copies busy"
  138:                     # Записываем blocker
  139:                     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  140:                     $tsNow2 = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
  141:                     $entry = "[$tsNow2] session-recovery -> team-lead:`nTYPE: blocker | PRIORITY: critical`nCONTENT: Lock conflict detected but ALL team-lead copies busy. Manual intervention needed.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: []`nCOMPLIANCE: false`nSTATUS: open`n"
  142:                     Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
  143:                 }
  144:             }
  145:         } catch {
  146:             Write-Log "ERROR: $($_.Exception.Message)"
  147:         }
  148: 
  149:         Start-Sleep -Seconds $CheckIntervalSec
  150:     }
  151: }
  152: 
  153: # Singleton lock
  154: if (Test-Path $LockFile) {
  155:     $existingPid = Get-Content $LockFile -ErrorAction SilentlyContinue
  156:     if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
  157:         Write-Host "Another recovery daemon already running (PID: $existingPid)" -ForegroundColor Yellow
  158:         exit 0
  159:     }
  160: }
  161: $currentPid = $PID
  162: $currentPid | Out-File -FilePath $LockFile -Encoding UTF8
  163: 
  164: try {
  165:     if ($Daemon) {
  166:         Main-Loop
  167:     } else {
  168:         # One-shot check
  169:         if (Test-LockConflict) {
  170:             Write-Host "Lock conflict detected!" -ForegroundColor Red
  171:             $freeCopy = Get-FreeTeamLeadCopy
  172:             if ($freeCopy) {
  173:                 Write-Host "Free copy available: $freeCopy" -ForegroundColor Green
  174:                 exit 0
  175:             } else {
  176:                 Write-Host "No free copies" -ForegroundColor Red
  177:                 exit 1
  178:             }
  179:         } else {
  180:             Write-Host "No lock conflicts" -ForegroundColor Green
  181:             exit 0
  182:         }
  183:     }
  184: } finally {
  185:     if (Test-Path $LockFile) { Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue }
```

### `.agents/scripts/create-project.ps1` lines 1-190

```powershell
    1: param(
    2:     [Parameter(Mandatory=$true)]
    3:     [string]$ProjectName,
    4: 
    5:     [Parameter(Mandatory=$false)]
    6:     [string]$TemplateType = "full-stack",
    7: 
    8:     [Parameter(Mandatory=$false)]
    9:     [string[]]$Agents,
   10: 
   11:     [Parameter(Mandatory=$false)]
   12:     [switch]$CreateWorktrees
   13: )
   14: 
   15: $ErrorActionPreference = "Stop"
   16: 
   17: # Agents will be normalized later when building the agent list
   18: # Handle comma-separated strings from -File invocation (PS 5.1 does not auto-split [string[]] with -File)
   19: if ($null -ne $Agents) {
   20:     $splitAgents = @()
   21:     foreach ($a in $Agents) {
   22:         $splitAgents += ($a -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
   23:     }
   24:     $Agents = $splitAgents
   25: }
   26: 
   27: $baseDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
   28: $projectsDir = Join-Path $baseDir "projects"
   29: $projectDir = Join-Path $projectsDir $ProjectName
   30: 
   31: # Security: whitelist project name + path traversal guard
   32: if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
   33:     Write-Host "ERROR: Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-" -ForegroundColor Red
   34:     exit 1
   35: }
   36: $projFull = [System.IO.Path]::GetFullPath($projectDir)
   37: $rootFull = [System.IO.Path]::GetFullPath($projectsDir).TrimEnd('\') + '\'
   38: if (-not $projFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
   39:     Write-Host "ERROR: Path traversal detected: '$ProjectName' escapes projects root" -ForegroundColor Red
   40:     exit 1
   41: }
   42: 
   43: Write-Host "=== Creating project: $ProjectName ===" -ForegroundColor Cyan
   44: Write-Host "Template: $TemplateType" -ForegroundColor Yellow
   45: 
   46: if (Test-Path $projectDir) {
   47:     Write-Host "ERROR: Project directory already exists: $projectDir" -ForegroundColor Red
   48:     exit 1
   49: }
   50: 
   51: New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
   52: Write-Host "Created project: $projectDir" -ForegroundColor Green
   53: 
   54: # ============================================================
   55: # Create agent worktrees if requested
   56: # ============================================================
   57: function New-AgentWorktree {
   58:     param(
   59:         [string[]]$AgentNames,
   60:         [string]$ProjectName
   61:     )
   62: 
   63:     $baseAgentsDir = (Split-Path $PSScriptRoot -Parent)
   64:     $worktreesDir = Join-Path $baseAgentsDir "worktrees"
   65:     $gitExe = Get-Command git -ErrorAction SilentlyContinue
   66:     $gitAvailable = $null -ne $gitExe
   67: 
   68:     if ($AgentNames.Count -eq 0) {
   69:         Write-Host "No agents specified for worktree creation." -ForegroundColor Yellow
   70:         return
   71:     }
   72: 
   73:     Write-Host "Creating worktrees for $($AgentNames.Count) agent(s)" -ForegroundColor Yellow
   74: 
   75:     foreach ($agent in $AgentNames) {
   76:         $agentWorktreeDir = Join-Path $worktreesDir $agent
   77: 
   78:         if (Test-Path $agentWorktreeDir) {
   79:             Write-Host "WARNING: Worktree already exists for agent '$agent', skipping (idempotent): $agentWorktreeDir" -ForegroundColor Yellow
   80:             continue
   81:         }
   82: 
   83:         if (-not (Test-Path $worktreesDir)) {
   84:             New-Item -ItemType Directory -Path $worktreesDir -Force | Out-Null
   85:         }
   86: 
   87:         if ($gitAvailable -and (Test-Path (Join-Path $baseAgentsDir ".git"))) {
   88:             $branchName = "worktree\$agent\$ProjectName"
   89:             Write-Host "Creating git worktree for agent '$agent' on branch '$branchName'" -ForegroundColor Cyan
   90:             $gitWorktreeOk = $false
   91:             try {
   92:                 & git worktree add "$agentWorktreeDir" -b "$branchName" 2>$null
   93:                 if ($LASTEXITCODE -ne 0) {
   94:                     throw "git worktree add exited with code $LASTEXITCODE"
   95:                 }
   96:                 $gitWorktreeOk = $true
   97:             } catch {
   98:                 Write-Host "WARNING: git worktree failed for '$agent' ($($_.Exception.Message)), falling back to folder copy" -ForegroundColor Yellow
   99:                 $gitAvailable = $false
  100:             }
  101:             if ($gitWorktreeOk) {
  102:                 $skillsSrc = Join-Path $baseAgentsDir "skills"
  103:                 $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"
  104: 
  105:                 if (Test-Path $skillsSrc) {
  106:                     $skillsDst = Join-Path $agentWorktreeDir "skills"
  107:                     Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
  108:                     $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
  109:                     if ($null -ne $skillItems) {
  110:                         foreach ($item in $skillItems) {
  111:                             $dst = Join-Path $skillsDst $item.Name
  112:                             Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  113:                         }
  114:                     }
  115:                     Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
  116:                 }
  117: 
  118:                 if (Test-Path $opencodeAgentsSrc) {
  119:                     $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
  120:                     Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
  121:                     $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
  122:                     if ($null -ne $opencodeItems) {
  123:                         foreach ($item in $opencodeItems) {
  124:                             $dst = Join-Path $opencodeAgentsDst $item.Name
  125:                             Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  126:                         }
  127:                     }
  128:                     Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
  129:                 }
  130:                 continue
  131:             }
  132:         }
  133: 
  134:         Write-Host "Creating folder stub for agent '$agent'" -ForegroundColor Cyan
  135: 
  136:         $skillsSrc = Join-Path $baseAgentsDir "skills"
  137:         if (Test-Path $skillsSrc) {
  138:             $skillsDst = Join-Path $agentWorktreeDir "skills"
  139:             Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
  140:             $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
  141:             if ($null -ne $skillItems) {
  142:                 foreach ($item in $skillItems) {
  143:                     $dst = Join-Path $skillsDst $item.Name
  144:                     Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  145:                 }
  146:             }
  147:             Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
  148:         }
  149: 
  150:         $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"
  151:         if (Test-Path $opencodeAgentsSrc) {
  152:             $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
  153:             Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
  154:             $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
  155:             if ($null -ne $opencodeItems) {
  156:                 foreach ($item in $opencodeItems) {
  157:                     $dst = Join-Path $opencodeAgentsDst $item.Name
  158:                     Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  159:                 }
  160:             }
  161:             Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
  162:         }
  163:     }
  164: }
  165: 
  166: # Build the agent list to process
  167: $agentList = @()
  168: 
  169: if ($CreateWorktrees -and -not $Agents) {
  170:     $configDir = Join-Path (Join-Path $baseDir ".opencode") "agents"
  171:     if (Test-Path $configDir) {
  172:         $allConfigs = Get-ChildItem -Path $configDir -Filter "*.json" -ErrorAction SilentlyContinue
  173:         foreach ($config in $allConfigs) {
  174:             $name = [System.IO.Path]::GetFileNameWithoutExtension($config.Name)
  175:             if ($name -ne "registry") {
  176:                 $agentList += $name
  177:             }
  178:         }
  179:     }
  180: } elseif ($Agents -and $Agents.Count -gt 0) {
  181:     $agentList = $Agents
  182: }
  183: 
  184: if ($agentList.Count -gt 0) {
  185:     New-AgentWorktree -AgentNames $agentList -ProjectName $ProjectName
  186: }
  187: 
  188: # ============================================================
  189: # Copy shared template files
  190: # ============================================================
```

### `.agents/scripts/create-project.ps1` lines 188-310

```powershell
  188: # ============================================================
  189: # Copy shared template files
  190: # ============================================================
  191: 
  192: $templateDir = Join-Path $PSScriptRoot "..\templates\project"
  193: $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
  194: 
  195: Write-Host "Template: $TemplateType" -ForegroundColor Yellow
  196: Write-Host "Template source: $templateDir" -ForegroundColor Gray
  197: 
  198: if (-not (Test-Path $templateDir)) {
  199:     Write-Host "WARNING: Template directory not found: $templateDir - skipping template files" -ForegroundColor Yellow
  200: } else {
  201:     # CONTEXT-BUFFER.md
  202:     $cbSrc = Join-Path $templateDir "CONTEXT-BUFFER.md"
  203:     if (Test-Path $cbSrc) {
  204:         $cbContent = [System.IO.File]::ReadAllText($cbSrc) -replace '\{name\}', $ProjectName
  205:         [System.IO.File]::WriteAllText((Join-Path $projectDir "CONTEXT-BUFFER.md"), $cbContent, [System.Text.UTF8Encoding]::new($false))
  206:         Write-Host "  Copied CONTEXT-BUFFER.md" -ForegroundColor Gray
  207:     }
  208: 
  209:     # KNOWLEDGE-BASE.md
  210:     $kbSrc = Join-Path $templateDir "KNOWLEDGE-BASE.md"
  211:     if (Test-Path $kbSrc) {
  212:         $kbContent = [System.IO.File]::ReadAllText($kbSrc) -replace '\{name\}', $ProjectName
  213:         [System.IO.File]::WriteAllText((Join-Path $projectDir "KNOWLEDGE-BASE.md"), $kbContent, [System.Text.UTF8Encoding]::new($false))
  214:         Write-Host "  Copied KNOWLEDGE-BASE.md" -ForegroundColor Gray
  215:     }
  216: 
  217:     # README.md
  218:     $rdSrc = Join-Path $templateDir "README.md"
  219:     if (Test-Path $rdSrc) {
  220:         $rdContent = [System.IO.File]::ReadAllText($rdSrc) -replace '\{name\}', $ProjectName
  221:         [System.IO.File]::WriteAllText((Join-Path $projectDir "README.md"), $rdContent, [System.Text.UTF8Encoding]::new($false))
  222:         Write-Host "  Copied README.md" -ForegroundColor Gray
  223:     }
  224: 
  225:     # project.json
  226:     $pjSrc = Join-Path $templateDir "project.json"
  227:     if (Test-Path $pjSrc) {
  228:         $pjContent = [System.IO.File]::ReadAllText($pjSrc)
  229:         $pjContent = $pjContent -replace '\{name\}', $ProjectName
  230:         $pjContent = $pjContent -replace '\{type\}', $TemplateType
  231:         $pjContent = $pjContent -replace '\{created_at\}', $timestamp
  232:         [System.IO.File]::WriteAllText((Join-Path $projectDir "project.json"), $pjContent, [System.Text.UTF8Encoding]::new($false))
  233:         Write-Host "  Copied project.json" -ForegroundColor Gray
  234:     }
  235: 
  236:     # queue.json
  237:     $qSrc = Join-Path $templateDir "queue.json"
  238:     if (Test-Path $qSrc) {
  239:         Copy-Item -Path $qSrc -Destination (Join-Path $projectDir "queue.json") -Force
  240:         Write-Host "  Copied queue.json" -ForegroundColor Gray
  241:     }
  242: 
  243:     # memory/ directory with .gitkeep
  244:     $memDir = Join-Path $projectDir "memory"
  245:     if (-not (Test-Path $memDir)) {
  246:         New-Item -ItemType Directory -Path $memDir -Force | Out-Null
  247:     }
  248:     $gkSrc = Join-Path $templateDir "memory\.gitkeep"
  249:     $gkDst = Join-Path $memDir ".gitkeep"
  250:     if ((Test-Path $gkSrc) -and -not (Test-Path $gkDst)) {
  251:         Copy-Item -Path $gkSrc -Destination $gkDst -Force
  252:     }
  253:     Write-Host "  Created memory/" -ForegroundColor Gray
  254: }
  255: 
  256: # ============================================================
  257: # Type-specific directory structure
  258: # ============================================================
  259: 
  260: switch ($TemplateType) {
  261:     "full-stack" {
  262:         $dirs = @("src\frontend", "src\backend", "src\shared", "tests", "docs", "scripts")
  263:         foreach ($d in $dirs) {
  264:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  265:         }
  266:     }
  267:     "api-only" {
  268:         $dirs = @("src\api", "src\models", "tests", "docs")
  269:         foreach ($d in $dirs) {
  270:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  271:         }
  272:     }
  273:     "mobile" {
  274:         $dirs = @("src\app", "src\components", "src\screens", "tests")
  275:         foreach ($d in $dirs) {
  276:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  277:         }
  278:     }
  279:     "data-pipeline" {
  280:         $dirs = @("src\etl", "src\transforms", "src\models", "tests", "configs")
  281:         foreach ($d in $dirs) {
  282:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  283:         }
  284:     }
  285:     default {
  286:         Write-Host "Unknown template: $TemplateType. Using full-stack." -ForegroundColor Yellow
  287:     }
  288: }
  289: 
  290: $gitignore = @"
  291: node_modules/
  292: __pycache__/
  293: *.pyc
  294: .venv/
  295: venv/
  296: dist/
  297: build/
  298: .env
  299: .env.local
  300: *.log
  301: .DS_Store
  302: Thumbs.db
  303: "@
  304: Set-Content -Path (Join-Path $projectDir ".gitignore") -Value $gitignore
  305: 
  306: Write-Host ""
  307: Write-Host "=== Project created: $projectDir ===" -ForegroundColor Green
  308: Write-Host "Next steps:" -ForegroundColor Yellow
  309: Write-Host "  1. cd $projectDir" -ForegroundColor White
  310: Write-Host "  2. git init ; git add -A ; git commit -m 'init'" -ForegroundColor White
```

### `.agents/scripts/agent-utilization.ps1` lines 1-205

```powershell
    1: # agent-utilization.ps1 - Agent utilization metrics and audit log
    2: # US-014 Resource Awareness
    3: #
    4: # Parameters:
    5: #   -Json                    Output metrics as JSON (machine-readable)
    6: #   -Watch [-IntervalSec N]  Live dashboard mode (default 30s interval)
    7: #   -LogAssignment           Log an assignment to agent-assignments.jsonl
    8: #     -Agent <name>          Agent name
    9: #     -Project <name>        Project name
   10: #     -Task <id>             Task ID
   11: #
   12: # Reads: .memory/agent-registry.json
   13: # Writes: .memory/agent-assignments.jsonl (append, UTF-8 no BOM)
   14: 
   15: param(
   16:     [switch]$Json,
   17:     [switch]$Watch,
   18:     [int]$IntervalSec = 30,
   19:     [switch]$LogAssignment,
   20:     [string]$Agent,
   21:     [string]$Project,
   22:     [string]$Task
   23: )
   24: 
   25: $ErrorActionPreference = "Stop"
   26: 
   27: # --------------------------------------------------
   28: # Path resolution: script is in .agents/scripts/
   29: # Project root is two levels up
   30: # --------------------------------------------------
   31: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   32: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   33: 
   34: $RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
   35: $AssignmentsPath = Join-Path $projectRoot ".memory\agent-assignments.jsonl"
   36: $ProjectsDir = Join-Path $projectRoot "projects"
   37: 
   38: # UTF-8 without BOM encoding
   39: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   40: 
   41: # --------------------------------------------------
   42: # Helper: Load registry JSON
   43: # --------------------------------------------------
   44: function Load-Registry {
   45:     if (-not (Test-Path $RegistryPath)) {
   46:         Write-Error "Registry file not found: $RegistryPath"
   47:         return $null
   48:     }
   49:     try {
   50:         $content = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom)
   51:         $registry = $content | ConvertFrom-Json
   52:         return $registry
   53:     } catch {
   54:         Write-Error "Failed to parse registry JSON: $_"
   55:         return $null
   56:     }
   57: }
   58: 
   59: # --------------------------------------------------
   60: # Helper: Enumerate projects dynamically from projects/ dir
   61: # --------------------------------------------------
   62: function Get-ProjectNames {
   63:     $names = @()
   64:     if (Test-Path $ProjectsDir) {
   65:         $dirs = Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue
   66:         foreach ($d in $dirs) {
   67:             $names += $d.Name
   68:         }
   69:     }
   70:     return $names
   71: }
   72: 
   73: # --------------------------------------------------
   74: # Compute utilization metrics
   75: # Returns PSCustomObject with all metrics
   76: # --------------------------------------------------
   77: function Get-UtilizationMetrics {
   78:     $registry = Load-Registry
   79:     if (-not $registry) {
   80:         return $null
   81:     }
   82: 
   83:     $allAgents = @()
   84:     foreach ($name in $registry.agents.PSObject.Properties.Name) {
   85:         $allAgents += $registry.agents.$name
   86:     }
   87: 
   88:     $total = $allAgents.Count
   89:     $busy = ($allAgents | Where-Object { $_.status -eq "busy" }).Count
   90:     $free = ($allAgents | Where-Object { $_.status -eq "free" }).Count
   91:     $errorCount = ($allAgents | Where-Object { $_.status -eq "error" }).Count
   92: 
   93:     if ($total -gt 0) {
   94:         $utilizationPct = [math]::Round(($busy / $total) * 100, 1)
   95:     } else {
   96:         $utilizationPct = 0
   97:     }
   98: 
   99:     # By project: count busy agents per current_project
  100:     $byProject = @{}
  101:     foreach ($a in $allAgents) {
  102:         if ($a.status -eq "busy" -and $a.current_project) {
  103:             $proj = $a.current_project
  104:             if (-not $byProject.ContainsKey($proj)) {
  105:                 $byProject[$proj] = 0
  106:             }
  107:             $byProject[$proj]++
  108:         }
  109:     }
  110: 
  111:     # Free agents by specialization/role
  112:     $freeBySpec = @{}
  113:     foreach ($a in $allAgents) {
  114:         if ($a.status -eq "free") {
  115:             $role = $a.role
  116:             if (-not $freeBySpec.ContainsKey($role)) {
  117:                 $freeBySpec[$role] = 0
  118:             }
  119:             $freeBySpec[$role]++
  120:         }
  121:     }
  122: 
  123:     # Alerts
  124:     $alerts = @()
  125:     if ($utilizationPct -lt 50) {
  126:         $alerts += "UNDERUTILIZED: utilization ${utilizationPct}% < 50% threshold"
  127:     }
  128:     if ($utilizationPct -gt 90) {
  129:         $alerts += "OVERLOADED: utilization ${utilizationPct}% > 90% threshold"
  130:     }
  131: 
  132:     $metrics = [PSCustomObject]@{
  133:         total               = $total
  134:         busy                = $busy
  135:         free                = $free
  136:         error               = $errorCount
  137:         utilization_pct     = $utilizationPct
  138:         by_project          = $byProject
  139:         free_by_specialization = $freeBySpec
  140:         alerts              = $alerts
  141:     }
  142: 
  143:     return $metrics
  144: }
  145: 
  146: # --------------------------------------------------
  147: # Render text dashboard
  148: # --------------------------------------------------
  149: function Show-TextDashboard {
  150:     $metrics = Get-UtilizationMetrics
  151:     if (-not $metrics) {
  152:         Write-Output "ERROR: Could not load agent registry"
  153:         return
  154:     }
  155: 
  156:     Write-Output ""
  157:     Write-Output "=== AGENT UTILIZATION DASHBOARD ==="
  158:     Write-Output ""
  159: 
  160:     # Summary
  161:     Write-Output "Total: $($metrics.total) | Busy: $($metrics.busy) | Free: $($metrics.free) | Error: $($metrics.error)"
  162:     Write-Output "Utilization: $($metrics.utilization_pct)%"
  163:     Write-Output ""
  164: 
  165:     # By project
  166:     Write-Output "--- Busy Agents by Project ---"
  167:     if ($metrics.by_project.Count -eq 0) {
  168:         Write-Output "  (no busy agents)"
  169:     } else {
  170:         foreach ($proj in ($metrics.by_project.Keys | Sort-Object)) {
  171:             $count = $metrics.by_project[$proj]
  172:             Write-Output "  $proj : $count agent(s)"
  173:         }
  174:     }
  175:     Write-Output ""
  176: 
  177:     # Free by specialization
  178:     Write-Output "--- Free Agents by Role ---"
  179:     if ($metrics.free_by_specialization.Count -eq 0) {
  180:         Write-Output "  (no free agents)"
  181:     } else {
  182:         foreach ($role in ($metrics.free_by_specialization.Keys | Sort-Object)) {
  183:             $count = $metrics.free_by_specialization[$role]
  184:             Write-Output "  $role : $count"
  185:         }
  186:     }
  187:     Write-Output ""
  188: 
  189:     # Alerts
  190:     if ($metrics.alerts.Count -gt 0) {
  191:         Write-Output "--- ALERTS ---"
  192:         foreach ($alert in $metrics.alerts) {
  193:             Write-Output "  [!] $alert"
  194:         }
  195:         Write-Output ""
  196:     }
  197: 
  198:     # Recent assignments (last 5)
  199:     Show-RecentAssignments -Count 5
  200: }
  201: 
  202: # --------------------------------------------------
  203: # Show last N assignment log entries
  204: # --------------------------------------------------
  205: function Show-RecentAssignments {
```

### `.agents/scripts/verify-phase.ps1` lines 1-165

```powershell
    1: param()
    2: 
    3: # CI auto-detect: GitHub Actions / generic CI runners have no local runtime artifacts
    4: $isCI = ($env:GITHUB_ACTIONS -eq "true") -or ($env:CI -eq "true")
    5: 
    6: Write-Host "=== Agent-HQ Phase Verification ===" -ForegroundColor Cyan
    7: Write-Host "Mode: $(if ($isCI) { 'CI' } else { 'LOCAL' })" -ForegroundColor Cyan
    8: Write-Host ""
    9: 
   10: $pass = 0
   11: $fail = 0
   12: $total = 0
   13: $ciSkipped = 0
   14: 
   15: function Test-Check {
   16:     param([string]$Name, [bool]$Condition)
   17:     $script:total++
   18:     if ($Condition) {
   19:         Write-Host "  [PASS] $Name" -ForegroundColor Green
   20:         $script:pass++
   21:     } else {
   22:         Write-Host "  [FAIL] $Name" -ForegroundColor Red
   23:         $script:fail++
   24:     }
   25: }
   26: 
   27: # Local-only check: runtime artifact of a working machine, absent on CI runners.
   28: # In CI mode prints [CI-SKIP] and is not counted in pass/fail.
   29: function Test-LocalCheck {
   30:     param([string]$Name, [bool]$Condition)
   31:     if ($script:isCI) {
   32:         Write-Host "  [CI-SKIP] $Name (local runtime artifact)" -ForegroundColor DarkYellow
   33:         $script:ciSkipped++
   34:     } else {
   35:         Test-Check $Name $Condition
   36:     }
   37: }
   38: 
   39: # Phase 0: ACP
   40: Write-Host "Phase 0: Agent Communication Protocol" -ForegroundColor Yellow
   41: Test-LocalCheck ".memory/inbox/ exists" (Test-Path ".memory\inbox")
   42: Test-Check ".memory/outbox/ exists" (Test-Path ".memory\outbox")
   43: Test-LocalCheck ".memory/dead-letter/ exists" (Test-Path ".memory\dead-letter")
   44: 
   45: $inboxAgents = Get-ChildItem ".memory\inbox" -Directory -ErrorAction SilentlyContinue | Measure-Object
   46: Test-LocalCheck "At least 1 agent inbox" ($inboxAgents.Count -ge 1)
   47: 
   48: # Phase 0.5: Sandbox
   49: Write-Host ""
   50: Write-Host "Phase 0.5: Sandbox via git worktree" -ForegroundColor Yellow
   51: Test-LocalCheck ".agents/worktrees/ exists" (Test-Path ".agents\worktrees")
   52: 
   53: $worktrees = Get-ChildItem ".agents\worktrees" -Directory -ErrorAction SilentlyContinue | Measure-Object
   54: Test-LocalCheck "At least 1 worktree" ($worktrees.Count -ge 1)
   55: 
   56: # Phase 1: Memory Bank
   57: Write-Host ""
   58: Write-Host "Phase 1: Memory Bank" -ForegroundColor Yellow
   59: $mbFiles = @("activeContext.md", "decisionLog.md", "productContext.md", "progress.md", "systemPatterns.md")
   60: foreach ($f in $mbFiles) {
   61:     $path = ".memory\$f"
   62:     $exists = Test-Path $path
   63:     if ($exists) {
   64:         $size = (Get-Item $path).Length
   65:         Test-Check "$f exists and not empty" ($size -gt 0)
   66:     } else {
   67:         Test-Check "$f exists and not empty" $false
   68:     }
   69: }
   70: 
   71: # Phase 2: Agent Configs
   72: Write-Host ""
   73: Write-Host "Phase 2: Agent Configurations" -ForegroundColor Yellow
   74: Test-Check ".opencode/agents/ exists" (Test-Path ".opencode\agents")
   75: 
   76: $jsonFiles = Get-ChildItem ".opencode\agents\*.json" -ErrorAction SilentlyContinue | Measure-Object
   77: Test-Check "At least 5 JSON configs" ($jsonFiles.Count -ge 5)
   78: 
   79: # Phase 2.5: Git
   80: Write-Host ""
   81: Write-Host "Phase 2.5: Git Versioning" -ForegroundColor Yellow
   82: Test-Check ".git/ exists" (Test-Path ".git")
   83: Test-Check ".gitignore exists" (Test-Path ".gitignore")
   84: 
   85: # Phase 3: Skills
   86: Write-Host ""
   87: Write-Host "Phase 3: Skills" -ForegroundColor Yellow
   88: Test-Check ".agents/skills/ exists" (Test-Path ".agents\skills")
   89: 
   90: $skills = Get-ChildItem ".agents\skills" -Directory -ErrorAction SilentlyContinue | Measure-Object
   91: Test-Check "At least 1 skill folder" ($skills.Count -ge 1)
   92: 
   93: # Phase 11: Commands
   94: Write-Host ""
   95: Write-Host "Phase 11: Commands" -ForegroundColor Yellow
   96: $config = Get-Content "opencode.json" -Raw | ConvertFrom-Json
   97: $hasSync = $null -ne $config.command.sync
   98: $hasStatus = $null -ne $config.command.status
   99: Test-Check "/sync command defined" $hasSync
  100: Test-Check "/status command defined" $hasStatus
  101: 
  102: # Phase B2: Agent Registration
  103: Write-Host ""
  104: Write-Host "Phase B2: Agent Registration" -ForegroundColor Yellow
  105: $ocRaw = Get-Content "opencode.json" -Raw -ErrorAction SilentlyContinue
  106: if ($ocRaw) {
  107:     $oc = $ocRaw | ConvertFrom-Json
  108:     Test-Check "opencode.json has agents section" ($null -ne $oc.agents)
  109:     if ($null -ne $oc.agents) {
  110:         $agentCount = ($oc.agents | Get-Member -MemberType NoteProperty).Count
  111:         Test-Check "agents section has >= 30 entries ($agentCount found)" ($agentCount -ge 30)
  112:     } else {
  113:         Test-Check "agents section has >= 30 entries" $false
  114:     }
  115: } else {
  116:     Test-Check "opencode.json has agents section" $false
  117:     Test-Check "agents section has >= 30 entries" $false
  118: }
  119: $promptsDir = ".opencode\agents\prompts"
  120: $promptsExist = Test-Path $promptsDir
  121: Test-Check ".opencode/agents/prompts/ exists" $promptsExist
  122: if ($promptsExist) {
  123:     $promptFiles = Get-ChildItem "$promptsDir\*.txt" -ErrorAction SilentlyContinue | Measure-Object
  124:     Test-Check "prompts has >= 19 .txt files ($($promptFiles.Count) found)" ($promptFiles.Count -ge 19)
  125: } else {
  126:     Test-Check "prompts has >= 19 .txt files" $false
  127: }
  128: 
  129: # Phase D2: Context Bus
  130: Write-Host ""
  131: Write-Host "Phase D2: Context Bus" -ForegroundColor Yellow
  132: $ctxExists = Test-Path "CONTEXT-BUFFER.md"
  133: if ($ctxExists) {
  134:     $ctxSize = (Get-Item "CONTEXT-BUFFER.md").Length
  135:     Test-Check "CONTEXT-BUFFER.md exists and not empty" ($ctxSize -gt 0)
  136: } else {
  137:     Test-Check "CONTEXT-BUFFER.md exists and not empty" $false
  138: }
  139: $agentsExists = Test-Path "AGENTS.md"
  140: if ($agentsExists) {
  141:     $agentsSize = (Get-Item "AGENTS.md").Length
  142:     Test-Check "AGENTS.md exists and not empty" ($agentsSize -gt 0)
  143: } else {
  144:     Test-Check "AGENTS.md exists and not empty" $false
  145: }
  146: 
  147: # Phase E2: Real Code Features
  148: Write-Host ""
  149: Write-Host "Phase E2: Real Code Features" -ForegroundColor Yellow
  150: Test-Check ".opencode/plugins/tracer.js exists" (Test-Path ".opencode\plugins\tracer.js")
  151: Test-Check ".opencode/plugins/scoring.js exists" (Test-Path ".opencode\plugins\scoring.js")
  152: Test-Check ".agents/scripts/health-check.ps1 exists" (Test-Path ".agents\scripts\health-check.ps1")
  153: $tracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
  154: $tracesPath = Join-Path $tracesDir "traces.jsonl"
  155: $tracesExists = Test-Path $tracesPath
  156: if ($tracesExists) {
  157:     $tracesSize = (Get-Item $tracesPath).Length
  158:     Test-LocalCheck "traces.jsonl exists and not empty (in LOCALAPPDATA)" ($tracesSize -gt 0)
  159: } else {
  160:     Test-LocalCheck "traces.jsonl exists and not empty (in LOCALAPPDATA)" $false
  161: }
  162: 
  163: # Phase F: US-011..015 Multi-Project
  164: Write-Host ""
  165: Write-Host "Phase F: US-011..015 Multi-Project" -ForegroundColor Yellow
```

### `.agents/scripts/verify-phase.ps1` lines 214-396

```powershell
  214: # F4: .memory/agent-registry.json valid JSON, 30 agents, has status/daily_load fields
  215: $registryPath = ".memory\agent-registry.json"
  216: $registryValid = $false
  217: $registryAgentCount = 0
  218: $hasStatusField = $false
  219: $hasDailyLoadField = $false
  220: if (Test-Path $registryPath) {
  221:     try {
  222:         $content = [System.IO.File]::ReadAllText($registryPath, [System.Text.UTF8Encoding]::new($false))
  223:         $registry = $content | ConvertFrom-Json -ErrorAction Stop
  224:         $registryValid = $true
  225:         if ($registry.agents) {
  226:             $registryAgentCount = ($registry.agents | Get-Member -MemberType NoteProperty).Count
  227:             # Check first agent for status and daily_load fields
  228:             $firstAgentName = ($registry.agents | Get-Member -MemberType NoteProperty)[0].Name
  229:             $firstAgent = $registry.agents.$firstAgentName
  230:             $hasStatusField = $null -ne $firstAgent.status
  231:             $hasDailyLoadField = $null -ne $firstAgent.daily_load
  232:         }
  233:     } catch {
  234:         $registryValid = $false
  235:     }
  236: }
  237: Test-Check "F4: agent-registry.json valid, 30 agents, has status/daily_load ($registryAgentCount agents)" ($registryValid -and $registryAgentCount -ge 30 -and $hasStatusField -and $hasDailyLoadField)
  238: 
  239: # F5: agent-registry.ps1 -List -Status free -> exit 0, output contains "free"
  240: $regScript = ".agents\scripts\agent-registry.ps1"
  241: $f5Pass = $false
  242: if (Test-Path $regScript) {
  243:     $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -List -Status free 2>&1
  244:     $exitCode = $LASTEXITCODE
  245:     $f5Pass = ($exitCode -eq 0) -and ($result -match "free")
  246: }
  247: Test-Check "F5: agent-registry.ps1 -List -Status free exits 0, shows 'free'" $f5Pass
  248: 
  249: # F6: agent-registry.ps1 -Acquire -Specialization "nonexistent-xyz" -> exit 2
  250: $f6Pass = $false
  251: if (Test-Path $regScript) {
  252:     $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -Acquire -Specialization "nonexistent-xyz" -Project "test" 2>&1
  253:     $exitCode = $LASTEXITCODE
  254:     $f6Pass = ($exitCode -eq 2)
  255: }
  256: Test-Check "F6: agent-registry.ps1 -Acquire nonexistent spec exits 2" $f6Pass
  257: 
  258: # F7: project-queue.ps1 test on 1c-buh: -Add (critical) -> -Next (returns critical) -> -Complete (done) -> -List confirms -> cleanup to empty
  259: # Local-only: full cycle mutates projects/<name>/queue.json (gitignored runtime data), absent on CI.
  260: $queueScript = ".agents\scripts\project-queue.ps1"
  261: $f7Pass = $false
  262: $testProject = "1c-buh"
  263: if (-not $isCI -and (Test-Path $queueScript)) {
  264:     # Add a critical task
  265:     $addResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Add -Project $testProject -Title "Test critical task" -Priority critical 2>&1
  266:     $addExit = $LASTEXITCODE
  267:     if ($addExit -eq 0 -and $addResult -match "tq-(\d{3})") {
  268:         $taskId = $Matches[0]
  269:         # Get next task (should return our critical task)
  270:         $nextResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Next -Project $testProject 2>&1
  271:         $nextExit = $LASTEXITCODE
  272:         if ($nextExit -eq 0 -and $nextResult -match $taskId) {
  273:             # Complete the task
  274:             $completeResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Complete -Project $testProject -Task $taskId 2>&1
  275:             $completeExit = $LASTEXITCODE
  276:             if ($completeExit -eq 0) {
  277:                 # List to confirm done
  278:                 $listResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
  279:                 $listExit = $LASTEXITCODE
  280:                 if ($listExit -eq 0 -and $listResult -match "done") {
  281:                     # CLEANUP: Remove the test task by marking dead and removing, or just verify queue is clean
  282:                     # Actually, let's just verify the queue ends up with the task in done status
  283:                     # For idempotency, we'll mark it dead to remove from active queue
  284:                     $deadResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Dead -Project $testProject -Task $taskId -Reason "Test cleanup" 2>&1
  285:                     $deadExit = $LASTEXITCODE
  286:                     # Final list should show empty or only done/dead tasks
  287:                     $finalList = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
  288:                     $finalExit = $LASTEXITCODE
  289:                     # Check that queue is effectively clean (no queued/assigned/in_progress)
  290:                     $queueContent = Get-Content (Join-Path "projects" "$testProject\queue.json") -Raw -ErrorAction SilentlyContinue
  291:                     $queueObj = $queueContent | ConvertFrom-Json -ErrorAction SilentlyContinue
  292:                     $activeTasks = 0
  293:                     if ($queueObj -and $queueObj.tasks) {
  294:                         $activeTasks = ($queueObj.tasks | Where-Object { $_.status -in @("queued", "assigned", "in_progress") }).Count
  295:                     }
  296:                     $f7Pass = ($activeTasks -eq 0)
  297:                 }
  298:             }
  299:         }
  300:     }
  301: }
  302: Test-LocalCheck "F7: project-queue.ps1 full cycle (Add->Next->Complete->cleanup) on 1c-buh" $f7Pass
  303: 
  304: # F7-cleanup: убрать тестовый мусор из queue.json (задачи с тестовым title),
  305: # чтобы прогоны F7 не накапливали done/dead задачи. Идемпотентно: повторные
  306: # прогоны дают стабильный tasks count.
  307: if ($f7Pass -or (Test-Path (Join-Path "projects" "$testProject\queue.json"))) {
  308:     $cleanupQueuePath = Join-Path "projects" "$testProject\queue.json"
  309:     $cleanupRaw = [System.IO.File]::ReadAllText($cleanupQueuePath, [System.Text.UTF8Encoding]::new($false))
  310:     $cleanupObj = $null
  311:     try { $cleanupObj = $cleanupRaw | ConvertFrom-Json -ErrorAction Stop } catch { $cleanupObj = $null }
  312:     if ($cleanupObj -and $cleanupObj.tasks) {
  313:         $keepTasks = @($cleanupObj.tasks | Where-Object { $_.title -ne "Test critical task" })
  314:         $removedCount = $cleanupObj.tasks.Count - $keepTasks.Count
  315:         if ($removedCount -gt 0) {
  316:             $cleanupObj.tasks = $keepTasks
  317:             $newJson = $cleanupObj | ConvertTo-Json -Depth 10 -Compress
  318:             [System.IO.File]::WriteAllText($cleanupQueuePath, $newJson, [System.Text.UTF8Encoding]::new($false))
  319:             Write-Host "  F7-cleanup: removed $removedCount test task(s) from $testProject/queue.json" -ForegroundColor Gray
  320:         }
  321:     }
  322: }
  323: 
  324: # F8: agent-utilization.ps1 output contains "Utilization"; -Json outputs valid JSON
  325: $utilScript = ".agents\scripts\agent-utilization.ps1"
  326: $f8TextPass = $false
  327: $f8JsonPass = $false
  328: if (Test-Path $utilScript) {
  329:     $textResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript 2>&1
  330:     $textExit = $LASTEXITCODE
  331:     $f8TextPass = ($textExit -eq 0) -and ($textResult -match "Utilization")
  332:     
  333:     $jsonResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript -Json 2>&1
  334:     $jsonExit = $LASTEXITCODE
  335:     if ($jsonExit -eq 0) {
  336:         try {
  337:             $null = $jsonResult | ConvertFrom-Json -ErrorAction Stop
  338:             $f8JsonPass = $true
  339:         } catch {
  340:             $f8JsonPass = $false
  341:         }
  342:     }
  343: }
  344: Test-Check "F8: agent-utilization.ps1 shows 'Utilization' and -Json valid" ($f8TextPass -and $f8JsonPass)
  345: 
  346: # F9: opencode.json command.status.template mentions agent-utilization or "Agents & Utilization"
  347: $f9Pass = $false
  348: if (Test-Path "opencode.json") {
  349:     $ocContent = Get-Content "opencode.json" -Raw
  350:     $oc = $ocContent | ConvertFrom-Json
  351:     if ($oc.command.status.template) {
  352:         $template = $oc.command.status.template
  353:         $f9Pass = ($template -match "agent-utilization") -or ($template -match "Agents & Utilization")
  354:     }
  355: }
  356: Test-Check "F9: opencode.json status command mentions agent-utilization or 'Agents & Utilization'" $f9Pass
  357: 
  358: # F10: knowledge-index.md in root, "### PAT-" appears >= 6 times
  359: $kiPath = "knowledge-index.md"
  360: $f10Pass = $false
  361: if (Test-Path $kiPath) {
  362:     $kiContent = Get-Content $kiPath -Raw
  363:     $patCount = ($kiContent -split "### PAT-" | Measure-Object).Count - 1
  364:     $f10Pass = ($patCount -ge 6)
  365: }
  366: Test-Check "F10: knowledge-index.md has >= 6 '### PAT-' entries ($patCount found)" $f10Pass
  367: 
  368: # F11: .opencode/agents/prompts/team-lead.txt contains "DUAL-AGENT DELEGATION"
  369: $tlPromptPath = ".opencode\agents\prompts\team-lead.txt"
  370: $f11Pass = $false
  371: if (Test-Path $tlPromptPath) {
  372:     $tlContent = Get-Content $tlPromptPath -Raw
  373:     $f11Pass = $tlContent -match "DUAL-AGENT DELEGATION"
  374: }
  375: Test-Check "F11: team-lead.txt contains 'DUAL-AGENT DELEGATION'" $f11Pass
  376: 
  377: # Summary
  378: Write-Host ""
  379: Write-Host "=== Results ===" -ForegroundColor Cyan
  380: $summaryLine = "Passed: $pass / $total"
  381: if ($ciSkipped -gt 0) {
  382:     $summaryLine += " ($ciSkipped skipped: CI-only artifacts)"
  383: }
  384: Write-Host $summaryLine -ForegroundColor Green
  385: if ($fail -gt 0) {
  386:     Write-Host "Failed: $fail / $total" -ForegroundColor Red
  387: } else {
  388:     Write-Host "Failed: 0 / $total" -ForegroundColor Green
  389: }
  390: Write-Host ""
  391: if ($fail -eq 0) {
  392:     Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
  393: } else {
  394:     Write-Host "SOME CHECKS FAILED - review above" -ForegroundColor Yellow
  395: }
  396: if ($fail -gt 0) { exit 1 }
```

### `.agents/scripts/health-check.ps1` lines 1-148

```powershell
    1: param()
    2: 
    3: $ErrorActionPreference = "Continue"
    4: $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    5: $hasFail = $false
    6: 
    7: Write-Host "=== agent-hq Health Check ===" -ForegroundColor Cyan
    8: Write-Host "Root: $root" -ForegroundColor Gray
    9: Write-Host ""
   10: 
   11: # --- 1. Traces: type:error за последние 60 минут ---
   12: $tracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
   13: $tracesPath = Join-Path $tracesDir "traces.jsonl"
   14: if (Test-Path $tracesPath) {
   15:     $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
   16:     $errorCount = 0
   17:     $lines = Get-Content $tracesPath -ErrorAction SilentlyContinue
   18:     foreach ($line in $lines) {
   19:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   20:         try {
   21:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   22:             if ($null -eq $obj) { continue }
   23:             if ($obj.type -eq "error" -and $obj.ts) {
   24:                 $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
   25:                 if ($ts -ge $cutoff) { $errorCount++ }
   26:             }
   27:         } catch { continue }
   28:     }
   29:     if ($errorCount -gt 5) {
   30:         Write-Host "[FAIL] Traces: $errorCount errors in last 60 min" -ForegroundColor Red
   31:         $hasFail = $true
   32:     } elseif ($errorCount -gt 0) {
   33:         Write-Host "[WARN] Traces: $errorCount errors in last 60 min" -ForegroundColor Yellow
   34:     } else {
   35:         Write-Host "[OK] Traces: 0 errors in last 60 min" -ForegroundColor Green
   36:     }
   37: } else {
   38:     Write-Host "[OK] Traces: traces.jsonl not found (no errors)" -ForegroundColor Green
   39: }
   40: 
   41: # --- 2. Inbox backlog ---
   42: $inboxDir = Join-Path $root ".memory\inbox"
   43: $inboxCount = 0
   44: if (Test-Path $inboxDir) {
   45:     $inboxCount = (Get-ChildItem -Path $inboxDir -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
   46:     if ($inboxCount -gt 50) {
   47:         Write-Host "[FAIL] Inbox backlog: $inboxCount files" -ForegroundColor Red
   48:         $hasFail = $true
   49:     } elseif ($inboxCount -gt 20) {
   50:         Write-Host "[WARN] Inbox backlog: $inboxCount files" -ForegroundColor Yellow
   51:     } else {
   52:         Write-Host "[OK] Inbox backlog: $inboxCount files" -ForegroundColor Green
   53:     }
   54: } else {
   55:     Write-Host "[OK] Inbox: directory not found" -ForegroundColor Green
   56: }
   57: 
   58: # --- 3. Outbox (информативно) ---
   59: $outboxDir = Join-Path $root ".memory\outbox"
   60: $outboxCount = 0
   61: if (Test-Path $outboxDir) {
   62:     $outboxCount = (Get-ChildItem -Path $outboxDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
   63:     Write-Host "[OK] Outbox: $outboxCount files" -ForegroundColor Green
   64: } else {
   65:     Write-Host "[OK] Outbox: directory not found" -ForegroundColor Green
   66: }
   67: 
   68: # --- 4. Worktrees ---
   69: Write-Host "" -ForegroundColor Gray
   70: Write-Host "--- Git Worktrees ---" -ForegroundColor Cyan
   71: try {
   72:     $wtOutput = & git -C $root worktree list 2>&1
   73:     if ($LASTEXITCODE -eq 0) {
   74:         foreach ($line in $wtOutput) { Write-Host "  $line" -ForegroundColor Gray }
   75:         Write-Host "[OK] Worktrees: listed" -ForegroundColor Green
   76:     } else {
   77:         Write-Host "[WARN] Worktrees: git command failed" -ForegroundColor Yellow
   78:     }
   79: } catch {
   80:     Write-Host "[WARN] Worktrees: $($_.Exception.Message)" -ForegroundColor Yellow
   81: }
   82: 
   83: # --- 5. Performance: средняя duration_ms ---
   84: $perfPath = Join-Path $tracesDir "performance.jsonl"
   85: if (Test-Path $perfPath) {
   86:     $durations = @()
   87:     $perfLines = Get-Content $perfPath -ErrorAction SilentlyContinue
   88:     foreach ($line in $perfLines) {
   89:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   90:         try {
   91:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   92:             if ($null -ne $obj -and $obj.duration_ms) {
   93:                 $durations += [double]$obj.duration_ms
   94:             }
   95:         } catch { continue }
   96:     }
   97:     if ($durations.Count -gt 0) {
   98:         $avgMs = ($durations | Measure-Object -Average).Average
   99:         $avgSec = [math]::Round($avgMs / 1000, 2)
  100:         Write-Host "[OK] Performance: avg session duration = ${avgSec}s ($($durations.Count) sessions)" -ForegroundColor Green
  101:     } else {
  102:         Write-Host "[OK] Performance: no duration data" -ForegroundColor Green
  103:     }
  104: } else {
  105:     Write-Host "[OK] Performance: performance.jsonl not found" -ForegroundColor Green
  106: }
  107: 
  108: # --- 6. Disk space ---
  109: $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
  110: if ($drive) {
  111:     $freeGB = [math]::Round($drive.Free / 1GB, 2)
  112:     if ($freeGB -lt 5) {
  113:         Write-Host "[WARN] Disk: ${freeGB}GB free" -ForegroundColor Yellow
  114:     } else {
  115:         Write-Host "[OK] Disk: ${freeGB}GB free" -ForegroundColor Green
  116:     }
  117: } else {
  118:     Write-Host "[WARN] Disk: cannot determine free space" -ForegroundColor Yellow
  119: }
  120: 
  121: # --- 7. Skills+MCP Compliance Check (NEW) ---
  122: Write-Host "" -ForegroundColor Gray
  123: Write-Host "--- Skills+MCP Compliance ---" -ForegroundColor Cyan
  124: $complianceScript = Join-Path $PSScriptRoot "compliance-gate.ps1"
  125: if (Test-Path $complianceScript) {
  126:     try {
  127:         $compResult = & $complianceScript -ReportPath (Join-Path $root "CONTEXT-BUFFER.md") -LookbackHours 24 -Strict:$false
  128:         if ($LASTEXITCODE -eq 0) {
  129:             Write-Host "[OK] Compliance: PASS" -ForegroundColor Green
  130:         } else {
  131:             Write-Host "[WARN] Compliance: violations found (check .memory/tool-usage-violations.jsonl)" -ForegroundColor Yellow
  132:         }
  133:     } catch {
  134:         Write-Host "[WARN] Compliance: script error - $($_.Exception.Message)" -ForegroundColor Yellow
  135:     }
  136: } else {
  137:     Write-Host "[WARN] Compliance: compliance-gate.ps1 not found" -ForegroundColor Yellow
  138: }
  139: 
  140: # --- Итог ---
  141: Write-Host "" -ForegroundColor Gray
  142: if ($hasFail) {
  143:     Write-Host "HEALTH: FAIL" -ForegroundColor Red
  144:     exit 1
  145: } else {
  146:     Write-Host "HEALTH: PASS" -ForegroundColor Green
  147:     exit 0
  148: }
```

### `.agents/scripts/sync-agents.ps1` lines 304-534

```powershell
  304: $agentsDir = Join-Path $root ".opencode\agents"
  305: $promptsDir = Join-Path $agentsDir "prompts"
  306: $configPath = Join-Path $root "opencode.json"
  307: 
  308: if (-not (Test-Path $promptsDir)) {
  309:     New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
  310: }
  311: 
  312: $allowKeys = @("read", "edit", "bash", "glob", "grep", "skill", "question", "webfetch", "websearch", "task", "list")
  313: $denyIfMissing = @("edit", "bash", "task")
  314: 
  315: $jsonFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }
  316: 
  317: Write-Host "=== Sync Agents: $($jsonFiles.Count) files found ===" -ForegroundColor Cyan
  318: 
  319: $agentEntries = [System.Collections.ArrayList]::new()
  320: $count = 0
  321: 
  322: foreach ($file in $jsonFiles) {
  323:     # Защита от аномально большого входного файла (>50 КБ)
  324:     if ($file.Length -gt 51200) {
  325:         Write-Warning "SKIP $($file.Name): file size $([math]::Round($file.Length / 1024, 1)) KB exceeds 50 KB limit — suspicious"
  326:         continue
  327:     }
  328: 
  329:     $raw = $null
  330:     $data = $null
  331: 
  332:     # Валидация JSON после чтения — try/catch, пропуск при ошибке
  333:     try {
  334:         $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
  335:         $data = $raw | ConvertFrom-Json
  336:     }
  337:     catch {
  338:         Write-Warning "SKIP $($file.Name): invalid JSON — $($_.Exception.Message)"
  339:         continue
  340:     }
  341: 
  342:     # Валидация обязательных полей
  343:     $hasDescription = $data.description -and ($data.description -is [string]) -and ($data.description.Trim().Length -gt 0)
  344:     $hasMode = $data.mode -and ($data.mode -is [string]) -and ($data.mode.Trim().Length -gt 0)
  345:     $hasModel = $data.model -and ($data.model -is [string]) -and ($data.model.Trim().Length -gt 0)
  346: 
  347:     if (-not $hasDescription) {
  348:         Write-Warning "SKIP $($file.Name): missing or empty required field 'description'"
  349:         continue
  350:     }
  351:     if (-not $hasMode) {
  352:         Write-Warning "SKIP $($file.Name): missing or empty required field 'mode'"
  353:         continue
  354:     }
  355:     if (-not $hasModel) {
  356:         Write-Warning "SKIP $($file.Name): missing or empty required field 'model'"
  357:         continue
  358:     }
  359: 
  360:     $name = if ($data.name) { $data.name } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
  361: 
  362:     $promptFile = Join-Path $promptsDir "$name.txt"
  363:     [System.IO.File]::WriteAllText($promptFile, $data.prompt, (New-Object System.Text.UTF8Encoding($false)))
  364: 
  365:     $perm = [ordered]@{}
  366:     foreach ($key in $allowKeys) {
  367:         if ($data.permissions -contains $key) {
  368:             $perm[$key] = "allow"
  369:         } elseif ($denyIfMissing -contains $key) {
  370:             $perm[$key] = "deny"
  371:         }
  372:     }
  373:     # external_directory: глобальные доверенные зоны (D:\Тест + opencode-пути на C:)
  374:     # Без этого per-agent permission перекрывает top-level и агенты просят подтверждение
  375:     $perm["external_directory"] = [ordered]@{
  376:         "D:\Тест\**"                                        = "allow"
  377:         "C:\Users\Ermak_DS\.local\share\opencode\**"        = "allow"
  378:         "C:\Users\Ermak_DS\AppData\Local\opencode\**"       = "allow"
  379:         "C:\Users\Ermak_DS\.config\opencode\**"             = "allow"
  380:     }
  381: 
  382:     # Собираем entry как хэштаблицу (не PSCustomObject — для ручной сериализации)
  383:     $entry = @{
  384:         name        = $name
  385:         description = [string]$data.description
  386:         mode        = if ($data.mode) { [string]$data.mode } else { "subagent" }
  387:         model       = if ($data.model) { [string]$data.model } else { "" }
  388:         temperature = if ($null -ne $data.temperature) { [double]$data.temperature } else { $null }
  389:         permission  = $perm
  390:         prompt      = "{file:.opencode/agents/prompts/$name.txt}"
  391:     }
  392: 
  393:     $agentEntries.Add($entry) | Out-Null
  394:     $count++
  395:     Write-Host "  [$count] $name -> $($data.model)" -ForegroundColor Green
  396: }
  397: 
  398: if ($count -eq 0) {
  399:     Write-Warning "No valid agents found — aborting"
  400:     exit 1
  401: }
  402: 
  403: # --- DryRun: показать превью и выйти ---
  404: if ($DryRun) {
  405:     Write-Host "`n=== DRY RUN: generated agent section preview ===" -ForegroundColor Yellow
  406:     Write-Host '  "agent": {'
  407:     for ($i = 0; $i -lt $agentEntries.Count; $i++) {
  408:         $e = $agentEntries[$i]
  409:         $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
  410:         $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
  411:         Write-Host ($jsonBlock + $comma)
  412:     }
  413:     Write-Host '  }'
  414:     Write-Host "`n=== DRY RUN: opencode.json NOT modified ===" -ForegroundColor Yellow
  415:     exit 0
  416: }
  417: 
  418: # ============================================================
  419: # ТОЧЕЧНАЯ ТЕКСТОВАЯ ЗАМЕНА секции "agent" в opencode.json
  420: # НЕ используем ConvertFrom-Json/ConvertTo-Json на всём файле —
  421: # PS 5.1 теряет NoteProperty-секции и портит кириллицу.
  422: # ============================================================
  423: 
  424: if (-not (Test-Path $configPath)) {
  425:     throw "opencode.json not found: $configPath"
  426: }
  427: 
  428: # 1. Прочитать как ТЕКСТ с явным UTF-8
  429: $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  430: 
  431: # 2. Собрать JSON секции agent вручную (без ConvertTo-Json — PS 5.1 ломает кириллицу)
  432: $agentLines = [System.Collections.ArrayList]::new()
  433: [void]$agentLines.Add('  "agents": {')
  434: for ($i = 0; $i -lt $agentEntries.Count; $i++) {
  435:     $e = $agentEntries[$i]
  436:     $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
  437:     $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
  438:     [void]$agentLines.Add($jsonBlock + $comma)
  439: }
  440: [void]$agentLines.Add('  }')
  441: $agentJsonBlock = $agentLines -join "`n"
  442: 
  443: # 3. Найти верхнеуровневый ключ "agents" (любой отступ, но ТОЛЬКО top-level)
  444: #    Устойчиво к отступам; дубль-защита: секция "agent" (ед.ч., легаси-баг) удаляется
  445: $agentPattern = '(?m)^[ \t]*"agents"\s*:\s*\{'
  446: $agentMatch = [regex]::Match($configText, $agentPattern)
  447: 
  448: # Легаси-дубль: удалить top-level "agent" (единственное число) если существует
  449: $legacyPattern = '(?m)^[ \t]*"agent"\s*:\s*\{'
  450: $legacyMatch = [regex]::Match($configText, $legacyPattern)
  451: if ($legacyMatch.Success) {
  452:     $newText = Remove-JsonTopLevelSection -text $configText -keyName "agent"
  453:     if ($null -ne $newText) {
  454:         $configText = $newText
  455:         Write-Warning "Legacy duplicate 'agent' section removed"
  456:         # Повторно ищем agents (позиции сместились)
  457:         $agentMatch = [regex]::Match($configText, $agentPattern)
  458:     }
  459: }
  460: 
  461: if (-not $agentMatch.Success) {
  462:     Write-Warning "Top-level 'agents' key not found — appending before final }"
  463:     $lastBrace = $configText.LastIndexOf("}")
  464:     if ($lastBrace -lt 0) {
  465:         throw "opencode.json has no closing brace — cannot inject agent section"
  466:     }
  467:     $beforeLast = $configText.Substring(0, $lastBrace).TrimEnd()
  468:     $needsComma = (-not $beforeLast.EndsWith(",")) -and ($beforeLast.Length -gt 0)
  469:     $comma = if ($needsComma) { "," } else { "" }
  470:     $inject = "`n" + $agentJsonBlock + "`n"
  471:     $configText = $configText.Substring(0, $lastBrace) + $comma + $inject + "}"
  472: }
  473: else {
  474:     # 4. Найти конец секции agent через balanced braces
  475:     $braceStart = $agentMatch.Index + $agentMatch.Length - 1  # индекс открывающей {
  476:     $braceEnd = Find-JsonBlockEnd -text $configText -startBraceIndex $braceStart
  477: 
  478:     if ($braceEnd -lt 0) {
  479:         throw "Cannot find matching closing brace for 'agent' section — aborting"
  480:     }
  481: 
  482:     # 5. Заменить подстроку от начала совпадения до парной } включительно
  483:     $replaceFrom = $agentMatch.Index
  484:     $replaceTo = $braceEnd + 1  # включая }
  485:     $configText = $configText.Remove($replaceFrom, $replaceTo - $replaceFrom).Insert($replaceFrom, $agentJsonBlock)
  486: }
  487: 
  488: # 6. Бэкап ПЕРЕД перезаписью
  489: $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  490: $backupPath = Join-Path $root "opencode.json.bak.$timestamp"
  491: 
  492: try {
  493:     Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
  494:     Write-Host "`nBackup created: $backupPath" -ForegroundColor Gray
  495: }
  496: catch {
  497:     Write-Warning "Failed to create backup: $($_.Exception.Message) — aborting to prevent data loss"
  498:     exit 1
  499: }
  500: 
  501: # 7. Записать UTF-8 без BOM
  502: [System.IO.File]::WriteAllText($configPath, $configText, (New-Object System.Text.UTF8Encoding($false)))
  503: 
  504: # 8. Проверка размера (>100 КБ — аномалия, откат)
  505: $writtenFile = Get-Item -LiteralPath $configPath
  506: if ($writtenFile.Length -gt 102400) {
  507:     Write-Error "opencode.json size $([math]::Round($writtenFile.Length / 1024, 1)) KB exceeds 100 KB limit — rolling back from backup"
  508:     Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
  509:     exit 1
  510: }
  511: 
  512: # 9. Валидация JSON ПОСЛЕ записи (ConvertFrom-Json ТОЛЬКО для проверки!)
  513: try {
  514:     $verifyRaw = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  515:     $null = $verifyRaw | ConvertFrom-Json
  516: }
  517: catch {
  518:     Write-Error "opencode.json is invalid JSON after write — rolling back from backup: $($_.Exception.Message)"
  519:     Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
  520:     exit 1
  521: }
  522: 
  523: # 10. Удаление старых бэкапов — оставить только последние 3
  524: $allBackups = Get-ChildItem -LiteralPath $root -Filter "opencode.json.bak.*" | Sort-Object Name -Descending
  525: if ($allBackups.Count -gt 3) {
  526:     $toDelete = $allBackups | Select-Object -Skip 3
  527:     foreach ($old in $toDelete) {
  528:         Remove-Item -LiteralPath $old.FullName -Force
  529:         Write-Host "Old backup removed: $($old.Name)" -ForegroundColor Gray
  530:     }
  531: }
  532: 
  533: Write-Host "`n=== DONE: $count agents written to opencode.json (text replacement, manual JSON serialization) ===" -ForegroundColor Cyan
  534: Write-Host "Prompts saved to: $promptsDir" -ForegroundColor Gray
```

### `.opencode/plugins/tracer.js` lines 1-78

```javascript
    1: import fs from "node:fs";
    2: import path from "node:path";
    3: import os from "node:os";
    4: 
    5: export const TracerPlugin = ({ directory }) => {
    6:   const starts = new Map();
    7:   const tracesDir = path.join(
    8:     process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    9:     "opencode",
   10:     "agent-hq-traces"
   11:   );
   12:   const tracesFile = path.join(tracesDir, "traces.jsonl");
   13: 
   14:   const writeJsonl = (obj) => {
   15:     try {
   16:       fs.mkdirSync(tracesDir, { recursive: true });
   17:       fs.appendFileSync(tracesFile, JSON.stringify(obj) + "\n", "utf-8");
   18:     } catch (_) {}
   19:   };
   20: 
   21:   return {
   22:     "tool.execute.before": async (input, _output) => {
   23:       try {
   24:         const callID = input?.callID;
   25:         if (callID) {
   26:           if (starts.size >= 1000) {
   27:             const oldest = starts.keys().next().value;
   28:             starts.delete(oldest);
   29:           }
   30:           starts.set(callID, Date.now());
   31:         }
   32:       } catch (_) {}
   33:     },
   34: 
   35:     "tool.execute.after": async (input, _output) => {
   36:       try {
   37:         const callID = input?.callID;
   38:         const ms = callID && starts.has(callID) ? Date.now() - starts.get(callID) : 0;
   39:         if (callID) starts.delete(callID);
   40:         writeJsonl({
   41:           ts: new Date().toISOString(),
   42:           type: "tool",
   43:           tool: input?.tool,
   44:           ms,
   45:         });
   46:       } catch (_) {}
   47:     },
   48: 
   49:     event: async ({ event }) => {
   50:       try {
   51:         const id = event?.properties?.sessionID;
   52:         if (!id) return;
   53:         if (event?.type === "session.created") {
   54:           writeJsonl({ ts: new Date().toISOString(), type: "session_start", id });
   55:         } else if (event?.type === "session.error") {
   56:           const props = event?.properties ?? event ?? {};
   57:           const msg =
   58:             props.message ??
   59:             props.error ??
   60:             props.data ??
   61:             props.reason ??
   62:             props.detail ??
   63:             "";
   64:           const raw = JSON.stringify(props, null, 0);
   65:           writeJsonl({
   66:             ts: new Date().toISOString(),
   67:             type: "error",
   68:             id,
   69:             message: String(msg).slice(0, 300),
   70:             props: String(raw).slice(0, 500),
   71:           });
   72:         } else if (event?.type === "session.idle") {
   73:           writeJsonl({ ts: new Date().toISOString(), type: "session_end", id });
   74:         }
   75:       } catch (_) {}
   76:     },
   77:   };
   78: };
```

### `.opencode/plugins/scoring.js` lines 1-57

```javascript
    1: import fs from "node:fs";
    2: import path from "node:path";
    3: import os from "node:os";
    4: 
    5: export const ScoringPlugin = ({ directory }) => {
    6:   const sessions = new Map();
    7:   const tracesDir = path.join(
    8:     process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    9:     "opencode",
   10:     "agent-hq-traces"
   11:   );
   12:   const perfFile = path.join(tracesDir, "performance.jsonl");
   13: 
   14:   const writeJsonl = (obj) => {
   15:     try {
   16:       fs.mkdirSync(tracesDir, { recursive: true });
   17:       fs.appendFileSync(perfFile, JSON.stringify(obj) + "\n", "utf-8");
   18:     } catch (_) {}
   19:   };
   20: 
   21:   return {
   22:     event: async ({ event }) => {
   23:       try {
   24:         const id = event?.properties?.sessionID;
   25:         if (!id) return;
   26:         if (event?.type === "session.created") {
   27:           sessions.set(id, Date.now());
   28:         } else if (event?.type === "session.idle") {
   29:           const start = sessions.get(id);
   30:           if (start !== undefined) {
   31:             const duration_ms = Date.now() - start;
   32:             const score = Math.max(0, 100 - Math.round(duration_ms / 60000));
   33:             writeJsonl({
   34:               ts: new Date().toISOString(),
   35:               session_id: id,
   36:               duration_ms,
   37:               score,
   38:             });
   39:             sessions.delete(id);
   40:           }
   41:         }
   42:       } catch (_) {}
   43:     },
   44: 
   45:     "tool.execute.after": async (input, _output) => {
   46:       try {
   47:         if (input?.tool === "task") {
   48:           writeJsonl({
   49:             ts: new Date().toISOString(),
   50:             type: "delegation",
   51:             tool: "task",
   52:           });
   53:         }
   54:       } catch (_) {}
   55:     },
   56:   };
   57: };
```

### `api/main.py` lines 1-9

```python
    1: from fastapi import FastAPI
    2: from fastapi.responses import JSONResponse
    3: 
    4: app = FastAPI(title="Health Check API")
    5: 
    6: 
    7: @app.get("/health")
    8: def health_check():
    9:     return JSONResponse(content={"status": "ok"})
```

### `api/requirements.txt` lines 1-2

```text
    1: fastapi>=0.115.0
    2: uvicorn[standard]>=0.30.0
```

### `.agents/templates/project/project.json` lines 1-9

```json
    1: {
    2:   "name": "{name}",
    3:   "type": "{type}",
    4:   "priority": "normal",
    5:   "agents": [],
    6:   "created_at": "{created_at}",
    7:   "status": "active",
    8:   "description": ""
    9: }
```

### `.agents/templates/project/queue.json` lines 1-3

```json
    1: {
    2:   "tasks": []
    3: }
```

## Начало каждого SKILL.md (для проверки discovery format)

### .agents/skills/1c-bsl-validate/SKILL.md
```markdown
# 1C:Enterprise — Проверка вызовов общих модулей BSL

## Описание

Проверка вызовов общих модулей в BSL по выгрузке конфигурации: существует ли модуль и экспортный ли у него метод. Работает без EDT, без платформы и без базы — по индексу от 1c-config-index. Ловит ошибки «переименовали метод, а вызовы в других модулях не обновили» до запуска.

## Когда использовать

- Переименовали метод или сняли `Экспорт` — нужно найти все вызовы
- Проверка BSL-кода перед коммитом
```

### .agents/skills/1c-bsp-api/SKILL.md
```markdown
# 1C:Enterprise — Справочник API БСП

## Описание

Офлайн-справочник по программному интерфейсу Библиотеки стандартных подсистем (БСП) 1С: 2624 метода в 284 модулях, 71 подсистема, версии 3.1.11 и 3.2.1. Позволяет проверить вызов метода БСП перед написанием кода. **НЕ** для API самой платформы (см. 1c-platform-docs) и **НЕ** для прикладных конфигураций (ERP, ЗУП, БП).

## Когда использовать

- Пишешь код на конфигурации с БСП и нужно узнать имя модуля или метода
- Нужна сигнатура метода, его контекст выполнения (сервер/клиент)
```

### .agents/skills/1c-config-index/SKILL.md
```markdown
# 1C:Enterprise — Индекс XML-выгрузки конфигурации

## Описание

Один проход по XML-выгрузке конфигурации 1С → один JSON. Индекс отвечает на вопрос «что вообще есть в этой конфигурации и из чего оно состоит»: объекты, реквизиты, ТЧ, измерения, ресурсы регистров, экспортные методы общих модулей. Работает без EDT, без платформы и без запущенной базы — только файлы выгрузки.

## Когда использовать

- Нужно проверить объект против остальной конфигурации
- Нужен список всех объектов/модулей/методов конфигурации
```

### .agents/skills/1c-config-router/SKILL.md
```markdown
# 1C:Enterprise — Маршрутизатор задач по конфигурации

## Описание

Мета-скилл: определяет какой workflow или отдельный скилл использовать для задачи пользователя. Таблица маршрутизации по всем 1С-скиллам.

## Когда использовать

- Не знаешь, какой скилл использовать для задачи
- Задача комплексная и требует цепочки операций
```

### .agents/skills/1c-dev/SKILL.md
```markdown
# 1C:Enterprise Development — Встроенный язык

## Описание

Разработка на встроенном языке (BSL) платформы 1С:Предприятие 8.3. Покрывает модули, процедуры/функции, работу с объектами метаданных (справочники, документы, регистры), паттерны БСП, типизацию и обработку ошибок.

## Когда использовать

- Написание/модификация модулей объектов, форм, менеджеров
- Разработка внешних обработок и отчётов (EPF/ERF)
```

### .agents/skills/1c-edt-configurator/SKILL.md
```markdown
# 1C:Enterprise — EDT и Конфигуратор

## Описание

Работа в 1С:EDT (Enterprise Development Tools) и Конфигураторе: расширения конфигурации (CFE), обновление конфигурации, выгрузка/загрузка CF/CFE, командная разработка с Git-хранилищем, ролевая модель и best practices.

## Когда использовать

- Создание и управление расширениями конфигурации (CFE)
- Выгрузка конфигурации в файлы (CF) и обратная загрузка
```

### .agents/skills/1c-epf-build/SKILL.md
```markdown
# 1C:Enterprise — Сборка внешней обработки (EPF/ERF)

## Описание

Сборка внешней обработки 1С (EPF) или внешнего отчёта (ERF) из XML-исходников через пакетный запуск платформы. Работает без EDT — напрямую из исходников в файл.

## Когда использовать

- Собрать EPF/ERF из XML-исходников
- Автоматизировать сборку обработок в CI/CD
```

### .agents/skills/1c-form-patterns/SKILL.md
```markdown
# 1C:Enterprise — Паттерны компоновки управляемых форм

## Описание

Справочник типовых паттернов дизайна управляемых форм 1С. Архетипы форм (документ, обработка, справочник, список), конвенции именования, иерархия групп, продвинутые приёмы компоновки.

## Когда использовать

- Проектирование управляемой формы (выбор архетипа)
- Расположение элементов управления на форме
```

### .agents/skills/1c-meta-edit/SKILL.md
```markdown
# 1C:Enterprise — Точечное редактирование метаданных

## Описание

Атомарные операции модификации XML объектов метаданных 1С. Добавление/удаление/изменение реквизитов, табличных частей, измерений, ресурсов, свойств объекта, форм, макетов, команд. Работает с XML-выгрузкой конфигурации без платформы и EDT.

## Когда использовать

- Добавить/удалить реквизит справочника, документа, регистра
- Добавить/удалить табличную часть с реквизитами
```

### .agents/skills/1c-naparnik/SKILL.md
```markdown
# 1C:Enterprise — 1С:Напарник (MCP-инструменты анализа кода)

## Описание

MCP-сервер **1c-naparnik** — интеграция с API 1С:Напарник (code.1c.ai). 12 инструментов: 6 для анализа/модификации BSL-кода, 6 для поиска по документации и базе знаний ИТС.

## Когда использовать

- Нужно проверить качество BSL-кода (стиль, архитектура, стандарты)
- Нужно проверить код на синтаксические ошибки, логические проблемы, антипаттерны
```

### .agents/skills/1c-platform-docs/SKILL.md
```markdown
# 1C:Enterprise — Документация платформы 1С (MCP)

## Описание

MCP-сервер **bsl-platform-help** — доступ к документации API платформы 1С:Предприятие. Поддерживает keyword, semantic (эмбеддинги) и hybrid поиск. Проверка существования встроенных функций/методов/свойств, получение сигнатур, просмотр членов типа.

## Когда использовать

- Проверка существования встроенных процедур/функций/методов/свойств
- Поиск методов и типов по описанию на естественном языке
```

### .agents/skills/1c-query/SKILL.md
```markdown
# 1C:Enterprise — Язык запросов

## Описание

Составление и оптимизация запросов на языке запросов 1С:Предприятие 8.3. Покрывает синтаксис (ВЫБРАТЬ/ИЗ/ГДЕ), соединения, временные таблицы, виртуальные таблицы регистров (остатки, обороты, срезы), агрегатные функции и оптимизацию производительности.

## Когда использовать

- Составление запросов для получения/фильтрации/агрегации данных из 1С-базы
- Построение отчётов и сводок
```

### .agents/skills/1c-query-optimization/SKILL.md
```markdown
# 1C:Enterprise — Продвинутая оптимизация запросов

## Описание

Продвинутые паттерны оптимизации запросов 1С: временные таблицы вместо подзапросов, оптимизация JOIN, оптимизация СКД-отчётов, обработка больших объёмов данных порциями. Дополняет базовые правила из 1c-query.

## Когда использовать

- Сложные запросы с многошаговой обработкой данных
- Оптимизация JOIN и подзапросов
```

### .agents/skills/1c-query-validate/SKILL.md
```markdown
# 1C:Enterprise — Проверка запросов по выгрузке конфигурации

## Описание

Проверка текста запроса 1С по выгрузке конфигурации: существуют ли таблицы, табличные части, виртуальные таблицы регистров и поля. Работает без EDT, без платформы и без базы — по индексу от 1c-config-index. Ловит опечатки в именах до того, как запрос попадёт в базу.

## Когда использовать

- Написали запрос и хотите проверить его перед выполнением
- Переименовали объект/реквизит — нужно найти сломанные запросы
```

### .agents/skills/1c-storage-ops/SKILL.md
```markdown
# 1C:Enterprise — Операции с хранилищем конфигурации

## Описание

Работа с хранилищем конфигурации 1С (не Git!) через пакетный запуск платформы: отчёт по версиям, захват и снятие захвата, обновление, помещение, выгрузка в CF, подключение и отключение базы. Основной механизм совместной работы в Конфигураторе.

## Когда использовать

- Захватить объекты для редактирования в хранилище
- Поместить изменения в хранилище (commit)
```

### .agents/skills/1c-support-state/SKILL.md
```markdown
# 1C:Enterprise — Состояние поддержки конфигурации

## Описание

Чтение и переключение состояния поддержки типовой (вендорской) конфигурации 1С в XML-выгрузке: разрешить правку объекта, снять с поддержки, вернуть на замок, включить/выключить возможность изменения. Работает с файлом `Ext/ParentConfigurations.bin`.

## Когда использовать

- Нужно разрешить правку типового объекта (временное снятие с замка)
- Нужно снять объект с поддержки (полное снятие)
```

### .agents/skills/1c-vanessa-steps/SKILL.md
```markdown
# 1C:Enterprise — Шаги Vanessa Automation (BDD-тестирование)

## Описание

Реестр из **1569 шагов** Vanessa Automation с описаниями и типами. Позволяет найти нужный шаг по смыслу и проверить готовый сценарий .feature перед запуском. Предотвращает ошибки «модель сочинила шаг, которого в Vanessa нет».

## Когда использовать

- Пишешь новый сценарий Vanessa — **сначала найди шаги**, потом составляй из найденного
- Правишь чужой сценарий и не уверен, существует ли шаг
```

### .agents/skills/memory-search/SKILL.md
```markdown
# Memory Search Skill

## Keyword grep по .memory/

### Поиск по файлам

1. **activeContext.md** — основной файл поиска
   - `grep -i "выполнено" .memory/activeContext.md`
   - `grep -i "заблокировано" .memory/activeContext.md`
   - `grep -i "ADR" .memory/decisionLog.md`
```

### .agents/skills/model-router/SKILL.md
```markdown
# Model Router Skill

## Текущее состояние (2026-09-09, АВАРИЙНАЯ МИГРАЦИЯ)

** ВСЕ 30 агентов работают на `tokenrouter/z-ai/glm-5.3-free` **

Причина: квота opencode free-tier исчерпана («Free usage exceeded, subscribe to Go») — модели opencode/mimo-v2.5-free, opencode/nemotron-3.5-lightning-free, opencode/nemotron-3-ultra-free НЕДОСТУПНЫ. Все запросы к ним виснут/падают.

Провайдер TokenRouter (ключ {env:TOKENROUTER_API_KEY}, отдельная квота) — единственный рабочий.

```

### .agents/skills/performance-scoring/SKILL.md
```markdown
# Performance Scoring Protocol

## Метрики агентов

### Время отклика (Response Time)
| Метрика | Целевое значение | Штраф |
|---------|------------------|-------|
| Простая задача | < 30 сек | +10 сек = -1 балл |
| Средняя задача | < 2 мин | +1 мин = -1 балл |
| Сложная задача | < 5 мин | +2 мин = -1 балл |
```

### .agents/skills/plugin-system/SKILL.md
```markdown
# Plugin System

## Структура плагинов

```
.opencode/plugins/
├── example-plugin/
│   ├── plugin.json       # Метаданные плагина
│   └── index.js          # Код плагина
└── _disabled/            # Отключённые плагины
```

### .agents/skills/self-healing/SKILL.md
```markdown
# Self-Healing Protocol

## Автоматическое восстановление при ошибках

### Уровень 1: Retry (повтор)
- **Условие**: ошибка сети, таймаут, временная недоступность
- **Действие**: повторить запрос 2 раза с экспоненциальной задержкой (1с, 2с, 4с)
- **Лог**: `.memory/traces/retry.log`

### Уровень 2: Fallback (резервная модель)
```

### .agents/skills/skill-enforcement/SKILL.md
```markdown
# Skill Enforcement — Принудительное использование скиллов и MCP

## Описание

Мета-скилл: обеспечивает 100% покрытие задач соответствующими скиллами и MCP-инструментами. Каждый агент ОБЯЗАН прочитать нужный SKILL.md ПЕРЕД началом работы и зафиксировать использование в трейсе.

## Когда использовать

- ВСЕГДА — это базовое правило для всех агентов
- При делегировании любой задачи через task tool
```

### .agents/skills/summarization/SKILL.md
```markdown
# Summarization Skill

## Автоматическое сжатие контекста

### Стратегия: summary + archive

#### Порог сжатия
1. Если `.memory/activeContext.md` > 50KB → сжатие запускается
2. ИЛИ сжатие запускается командой `/sync` каждые 30 минут
3. ИЛИ по запросу team-lead
```

### .agents/skills/superpowers/implement/SKILL.md
```markdown
# Superpowers Implement — Implementation Phase

## Описание

Фаза implementation методологии Superpowers (obra) для SDLC.
Автоматизирует написание кода: TDD (тесты первыми), clean code, YAGNI, соответствие плану.

## Когда использовать

- Задачи SDLC, требующие фазы implementation
```

### .agents/skills/superpowers/plan/SKILL.md
```markdown
# Superpowers Plan — Planning Phase

## Описание

Фаза planning методологии Superpowers (obra) для SDLC.
Автоматизирует декомпозицию requirements на архитектурные решения, задачи, зависимости и timeline.

## Когда использовать

- Задачи SDLC, требующие фазы planning
```

### .agents/skills/superpowers/spec/SKILL.md
```markdown
# Superpowers Spec — Specification Phase

## Описание

Фаза specification методологии Superpowers (obra) для SDLC.
Автоматизирует сбор и структурирование требований: от размытой идеи до чётких User Stories с Acceptance Criteria.

## Когда использовать

- Задачи SDLC, требующие фазы specification
```

### .agents/skills/superpowers/test/SKILL.md
```markdown
# Superpowers Test — Testing Phase

## Описание

Фаза testing методологии Superpowers (obra) для SDLC.
Автоматизирует тестирование: unit/integration/e2e, coverage analysis, edge cases, regression test plan.

## Когда использовать

- Задачи SDLC, требующие фазы testing
```

### .agents/skills/windows-safety/SKILL.md
```markdown
# Windows Safety & PowerShell 5.1 — обязательный скилл

## Когда использовать
ПЕРЕД любой командой сложнее `git status`, ПЕРЕД любым скачиванием/установкой, ПЕРЕД запуском чужих скриптов.

## 1. Синтаксис PowerShell 5.1
- НЕТ `&&` и `||` (это PS7/bash). Правильно:
  `cmd1; if ($LASTEXITCODE -eq 0) { cmd2 }`
- НЕТ bash: `[ -f file ]` → `Test-Path "file"`; `[ -d dir ]` → `Test-Path "dir" -PathType Container`; `rm -rf x` → `Remove-Item -Recurse -Force x`; `mkdir -p d` → `New-Item -ItemType Directory -Force d`
- НЕТ `curl -L`: использовать `curl.exe -L -o out URL` или `Invoke-WebRequest -Uri URL -OutFile out`
```

### `.memory/outbox/test-001.json` lines 1-12

```json
    1: ﻿{
    2:     "id":  "test-001",
    3:     "type":  "result",
    4:     "startedAt":  "2026-09-09T10:04:02",
    5:     "response":  "\u001b[93m\u001b[1m! \u001b[0m agent \"dev-1\" not found. Falling back to default agent \u001b[0m \u003e build ┬╖ z-ai/glm-5.3-free \u001b[0m \u001b[93m\u001b[1m! \u001b[0mpermission requested: external_directory (D:\\╨в╨╡╤Б╤В\\agent-hq\\*); auto-rejecting \u001b[0mтЬЧ \u001b[0mGet-Content -LiteralPath \"D:\\╨в╨╡╤Б╤В\\agent-hq\\CONTEXT-BUFFER.md\" -Tail 30 failed \u001b[91m\u001b[1mError: \u001b[0mThe user rejected permission to use this specific tool call.",
    6:     "finishedAt":  "2026-09-09T10:05:02",
    7:     "payload":  "Create a simple test file test_agent_output.txt with content \u0027Hello from inbox poller test\u0027",
    8:     "from":  "team-lead",
    9:     "status":  "done",
   10:     "priority":  "normal",
   11:     "to":  "dev-1"
   12: }
```

### `.memory/agent-registry.json` lines 1-1

```json
    1: {"agents":{"tech-writer":{"name":"tech-writer","role":"tech-writer","specialization":["docs","markdown","api"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"security-auditor":{"name":"security-auditor","role":"security-auditor","specialization":["security","owasp","code-review"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"code-reviewer-1":{"name":"code-reviewer-1","role":"code-reviewer","specialization":["code-review","clean-code","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"smm-strategist":{"name":"smm-strategist","role":"smm-strategist","specialization":["promotion","target-audience","funnel","webfetch"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"team-lead-2":{"name":"team-lead-2","role":"orchestrator","specialization":["orchestration","architecture","delegation","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"skill-surgeon":{"name":"skill-surgeon","role":"skill-surgeon","specialization":["skills","tools","webfetch"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-2-1":{"name":"dev-2-1","role":"developer","specialization":["python","javascript","docker"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-1":{"name":"dev-1","role":"developer","specialization":["python","fastapi","postgres","docker","git"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":7},"qa-engineer-1":{"name":"qa-engineer-1","role":"qa-engineer","specialization":["testing","pytest","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"backend":{"name":"backend","role":"backend-dev","specialization":["python","fastapi","redis","docker","sql"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":1},"frontend":{"name":"frontend","role":"frontend-dev","specialization":["react","typescript","css","vite"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"integration-specialist":{"name":"integration-specialist","role":"integration-specialist","specialization":["api","grpc","kafka","python","sql"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"team-lead-3":{"name":"team-lead-3","role":"orchestrator","specialization":["orchestration","architecture","delegation","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"qa-engineer":{"name":"qa-engineer","role":"qa-engineer","specialization":["testing","pytest","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"mobile-dev":{"name":"mobile-dev","role":"mobile-dev","specialization":["react-native","flutter","python"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-2":{"name":"dev-2","role":"developer","specialization":["python","javascript","docker"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-3-1":{"name":"dev-3-1","role":"developer","specialization":["sql","data","python"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"data-engineer":{"name":"data-engineer","role":"data-engineer","specialization":["etl","airflow","clickhouse","python","sql"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-1-1":{"name":"dev-1-1","role":"developer","specialization":["python","fastapi","postgres","docker","git"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":2},"devops":{"name":"devops","role":"devops","specialization":["docker","ci-cd","k8s","python"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"legal-advisor":{"name":"legal-advisor","role":"legal-advisor","specialization":["laws","contracts","taxes","api"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"security-auditor-1":{"name":"security-auditor-1","role":"security-auditor","specialization":["security","owasp","code-review"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"backend-1":{"name":"backend-1","role":"backend-dev","specialization":["python","fastapi","redis","docker","sql"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":2},"product-manager":{"name":"product-manager","role":"product-manager","specialization":["requirements","user-stories","api-design"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"code-reviewer":{"name":"code-reviewer","role":"code-reviewer","specialization":["code-review","clean-code","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":1},"team-lead":{"name":"team-lead","role":"orchestrator","specialization":["orchestration","architecture","delegation","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"db-specialist":{"name":"db-specialist","role":"db-specialist","specialization":["sql","nosql","orm","python"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"team-lead-1":{"name":"team-lead-1","role":"orchestrator","specialization":["orchestration","architecture","delegation","code-review","security"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0},"dev-3":{"name":"dev-3","role":"developer","specialization":["sql","data","python"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":2},"tech-writer-1":{"name":"tech-writer-1","role":"tech-writer","specialization":["docs","markdown","api"],"status":"free","current_project":null,"current_task":null,"last_assignment":null,"daily_load":0}}}
```

# PHASE1 END
Теперь выполни полный независимый аудит по заданию в начале пакета.
