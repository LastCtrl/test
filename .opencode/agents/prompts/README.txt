# Prompts Structure & Skills Mapping

Структура промптов агентов и маппинг обязательных скиллов/MCP.

## Структура промпта (общая для всех 19 агентов)

Каждый промпт в `.opencode/agents/prompts/<agent>.txt` содержит:

1. **Role Description** — кто агент, его зона ответственности
2. **Обязательный протокол** — чтение CONTEXT-BUFFER.md, запись результата, blocker процедура
3. **🔴 SKILL ENFORCEMENT (mandatory)** — ссылка на skill-enforcement/SKILL.md
4. **Role-specific Rules** — стек, правила, что НЕ делает
5. **Rollback Protocol** — max 2 попытки, откат, blocker
6. **Skill Rule** — подгружай скиллы ПЕРЕД работой
7. **MCP Tools** — context7, sequential-thinking, hermes-atlas-mcp

---

## Agent → Skills + MCP Mapping (из registry.json)

| Агент | Required Skills | MCP Tools (mandatory when applicable) |
|-------|-----------------|---------------------------------------|
| **team-lead** | model-router, performance-scoring, self-healing, summarization, skill-enforcement | context7 (для библиотек), sequential-thinking (>3 шага), hermes-atlas-mcp (новые скиллы) |
| **dev-1** | 1c-dev, 1c-query, 1c-bsp-api, windows-safety, skill-enforcement | context7 (exceljs, fastapi, postgres, 1c-bsl), sequential-thinking (>3 шага) |
| **dev-2** | 1c-dev, 1c-query, 1c-edt-configurator, windows-safety, skill-enforcement | context7 (javascript, python libs), sequential-thinking (>3 шага) |
| **dev-3** | 1c-dev, 1c-bsl-validate, 1c-query-validate, windows-safety, skill-enforcement | context7 (sql, data libs), sequential-thinking (>3 шага) |
| **frontend** | 1c-form-patterns, 1c-meta-edit, skill-enforcement | context7 (react, typescript, tailwind, vite), sequential-thinking (>3 шага) |
| **backend** | 1c-query, 1c-bsp-api, 1c-query-optimization, skill-enforcement | context7 (fastapi, redis, sql), sequential-thinking (>3 шага) |
| **db-specialist** | 1c-storage-ops, 1c-config-index, 1c-support-state, skill-enforcement | context7 (postgres, mysql, redis, clickhouse), sequential-thinking (>3 шага) |
| **mobile-dev** | 1c-epf-build, skill-enforcement | context7 (react-native, flutter, swift, kotlin), sequential-thinking (>3 шага) |
| **devops** | windows-safety, 1c-platform-docs, skill-enforcement | context7 (docker, k8s, ci-cd, terraform), sequential-thinking (>3 шага) |
| **integration-specialist** | 1c-naparnik, 1c-config-router, skill-enforcement | context7 (grpc, kafka, rabbitmq, api-gateway), sequential-thinking (>3 шага) |
| **data-engineer** | 1c-query, 1c-query-validate, 1c-query-optimization, skill-enforcement | context7 (airflow, clickhouse, etl), sequential-thinking (>3 шага) |
| **qa-engineer** | 1c-bsl-validate, 1c-query-validate, 1c-storage-ops, skill-enforcement | context7 (pytest, testing libs), sequential-thinking (>3 шага) |
| **security-auditor** | windows-safety, 1c-platform-docs, skill-enforcement | context7 (owasp, security libs), sequential-thinking (>3 шага) |
| **code-reviewer** | 1c-dev, 1c-bsl-validate, clean-code, skill-enforcement | context7 (code review tools), sequential-thinking (>3 шага) |
| **product-manager** | summarization, memory-search, skill-enforcement | context7 (api design), hermes-atlas-mcp (новые скиллы для требований) |
| **tech-writer** | summarization, 1c-platform-docs, skill-enforcement | context7 (markdown, docs tools), sequential-thinking (>3 шага) |
| **skill-surgeon** | 1c-dev, 1c-query, 1c-bsp-api, 1c-storage-ops, 1c-config-router, windows-safety, model-router, performance-scoring, self-healing, summarization, memory-search, clean-code, skill-enforcement, plugin-system | context7 (любые), hermes-atlas-mcp (поиск скиллов), sequential-thinking (>3 шага) |
| **legal-advisor** | 1c-platform-docs, summarization, skill-enforcement | context7 (laws, contracts), hermes-atlas-mcp (новые скиллы) |
| **smm-strategist** | memory-search, performance-scoring, skill-enforcement | context7 (marketing tools), hermes-atlas-mcp (новые скиллы) |

---

## Delegation Template (для team-lead в task tool)

При делегировании задачи через `task tool` ОБЯЗАТЕЛЬНО включай в prompt:

```markdown
## ОБЯЗАТЕЛЬНЫЕ ПОЛЯ В ТЗ:
- Skills: <список из таблицы выше для данного агента>
- MCP: <context7/hermes-atlas/sequential-thinking — какие нужны>
- Self-report: ОБЯЗАТЕЛЬНО укажи SKILLS_LOADED и MCP_USED в отчёте
```

**Пример для dev-1:**
```
task "Создать Excel отчёт с формулами
## ОБЯЗАТЕЛЬНЫЕ ПОЛЯ В ТЗ:
- Skills: 1c-dev, 1c-query, 1c-bsp-api, windows-safety, skill-enforcement
- MCP: context7 (exceljs), sequential-thinking (планирование листов)
- Self-report: ОБЯЗАТЕЛЬНО укажи SKILLS_LOADED и MCP_USED в отчёте
" subagent_type=dev-1
```

---

## Dual-Agent Delegation Template (ОБЯЗАТЕЛЬНО ДЛЯ КАЖДОЙ ЗАДАЧИ)

**Правило:** Каждая входящая задача обрабатывается **ДВУМЯ агентами параллельно**:
- **team-lead** — архитектура, делегирование, качество
- **product-manager** — требования, user stories, acceptance criteria, приоритизация

### Шаблон вызова

```markdown
## ШАГ 1: DUAL-AGENT (одно сообщение, два вызова)

# Вызов product-manager (параллельно с анализом team-lead)
task "Проанализируй требования для: <ЗАДАЧА>.
Выдай:
1. User Stories (формат: Как... я хочу... чтобы...)
2. Acceptance Criteria (проверяемые критерии)
3. MoSCoW приоритизацию
4. Риски и зависимости
5. Рекомендации по технологическому стеку
6. Нефункциональные требования" subagent_type=product-manager

# Team-lead анализирует параллельно:
# - Тип проекта (full-stack, api-only, mobile, data-pipeline, integration)
# - Архитектурные решения
# - Набор агентов для делегирования
# - Порядок выполнения подзадач

## ШАГ 2: СИНХРОНИЗАЦИЯ

# Team-lead читает вывод PM из CONTEXT-BUFFER.md
# Объединяет: PM requirements + техническая архитектура = итоговый план

## ШАГ 3: ДЕЛЕГИРОВАНИЕ ИСПОЛНИТЕЛЯМ

# Только после ШАГОВ 1+2 — запуск dev/backend/qa/etc
task "Создать <компонент> по ТЗ:
## ОБЯЗАТЕЛЬНЫЕ ПОЛЯ В ТЗ:
- Skills: <список из таблицы выше для данного агента>
- MCP: <context7/hermes-atlas/sequential-thinking — какие нужны>
- User Stories: <из вывода product-manager>
- Acceptance Criteria: <из вывода product-manager>
- Self-report: ОБЯЗАТЕЛЬНО укажи SKILLS_LOADED и MCP_USED в отчёте
" subagent_type=<agent>
```

### Пример: реальная задача

```
task "Проанализируй требования для: Создание REST API для управления SIM-картами.
Выдай:
1. User Stories (формат: Как... я хочу... чтобы...)
2. Acceptance Criteria (проверяемые критерии)
3. MoSCoW приоритизацию
4. Риски и зависимости
5. Рекомендации по технологическому стеку (FastAPI + PostgreSQL)
6. Нефункциональные требования (безопасность, производительность)" subagent_type=product-manager

# Параллельно team-lead определяет:
# - Тип: API-only
# - Стек: FastAPI + PostgreSQL + Redis
# - Агенты: backend + db-specialist + qa-engineer + security-auditor

# После получения вывода PM:
task "Создать REST API для SIM-карт:
## ОБЯЗАТЕЛЬНЫЕ ПОЛЯ В ТЗ:
- Skills: 1c-query, 1c-bsp-api, windows-safety, skill-enforcement
- MCP: context7 (fastapi, sqlalchemy, postgres), sequential-thinking
- User Stories: US-001: Как оператор, я хочу добавлять SIM-карты, чтобы вести учёт
- Acceptance Criteria: POST /simcards возвращает 201, валидация IMSI, авторизация
- Self-report: ОБЯЗАТЕЛЬНО укажи SKILLS_LOADED и MCP_USED в отчёте
" subagent_type=backend
```

---

## Session Recovery (Auto-Delegation при Lock Conflict)

При ошибке "Busy: FileSystem.writeFile" или lock conflict:
1. Скрипт `session-recovery.ps1` автоматически обнаруживает конфликт
2. Ждёт 5 секунд (настраивается через `-LockCheckIntervalSec`)
3. Проверяет свободные копии team-lead-1/2/3
4. Записывает delegation-запрос в CONTEXT-BUFFER.md
5. Если все заняты — записывает blocker + планирует retry через message-queue

Запуск: `.agents\scripts\session-recovery.ps1`

---

## Как обновить маппинг

1. Измени `required_skills` в `.opencode/agents/registry.json`
2. Запусти `.agents/scripts/sync-agents.ps1` — обновит opencode.json и промпты
3. Обнови этот README.md (таблицу выше)
4. Коммит: `docs(prompts): update skills mapping`

Сохрани файл. Коммит: `docs(prompts): add prompts structure README`