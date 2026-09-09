# Skill Enforcement — Принудительное использование скиллов и MCP

## Описание

Мета-скилл: обеспечивает 100% покрытие задач соответствующими скиллами и MCP-инструментами. Каждый агент ОБЯЗАН прочитать нужный SKILL.md ПЕРЕД началом работы и зафиксировать использование в трейсе.

## Когда использовать

- ВСЕГДА — это базовое правило для всех агентов
- При делегировании любой задачи через task tool
- При работе с внешними библиотеками/фреймворками (context7)
- При сложных задачах >3 шагов (sequential-thinking)

## Инструкции

### 1. ОБЯЗАТЕЛЬНЫЙ ПРЕДВАРИТЕЛЬНЫЙ ЭТАП (для каждого агента)

ПЕРЕД началом ЛЮБОЙ задачи:

```markdown
## 🔴 ПРЕДВАРИТЕЛЬНЫЙ ЭТАП (НЕПРОВЕРЕНИЕ = BLOCKER)

### 1. SKILLS — ОБЯЗАТЕЛЬНО
- Определи нужные скиллы из `.agents/skills/` (ls .agents/skills/)
- ВЫЗОВИ `skill <имя-скилла>` ДЛЯ КАЖДОГО НУЖНОГО
- Для 1С: СНАЧАЛА `skill 1c-config-router` → он скажет какой скилл нужен
- Без загрузки скилла — НЕ ПИШИ КОД

### 2. CONTEXT7 — ОБЯЗАТЕЛЬНО ДЛЯ ВНЕШНИХ БИБЛИОТЕК/ФРЕЙМВОРКОВ
- Любая библиотека (exceljs, fastapi, react, 1c-bsl и т.д.):
  1. `context7_resolve-library-id` — найти ID
  2. `context7_query-docs` — получить актуальную документацию/примеры
- Не полагайся на память модели

### 3. SEQUENTIAL-THINKING — ОБЯЗАТЕЛЬНО ЕСЛИ ЗАДАЧА > 3 ШАГОВ
- Сложная архитектура, дебаг, многошаговые задачи
- Вызывай `sequential-thinking_sequentialthinking` с thoughtNumber=1
- Планируй явно, фиксируй гипотезы

### 4. HERMES-ATLAS-MCP — ЕСЛИ НУЖЕН НОВЫЙ СКИЛЛ/ТУЛ
- `hermes-atlas-mcp_search_projects` — поиск готовых решений
- `hermes-atlas-mcp_get_project` — детали

⚠️ ЕСЛИ НЕ СДЕЛАЛ ПРЕДВАРИТЕЛЬНЫЙ ЭТАП — ЗАПИШИ BLOCKER В CONTEXT-BUFFER.MD И НЕ НАЧИНАЙ РАБОТУ
```

### 2. SELF-REPORT В ТРЕЙС (обязательно в конце задачи)

Каждый агент ДОЛЖЕН записать в CONTEXT-BUFFER.md:

```
[TIME] <agent> → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: <что сделано>
SKILLS_LOADED: [<список скиллов через запятую>]
MCP_USED: [<список MCP инструментов через запятую>]
COMPLIANCE: true
STATUS: resolved
```

Поля `SKILLS_LOADED` и `MCP_USED` — ОБЯЗАТЕЛЬНЫ. Пустой массив = violation.

### 3. FALLBACK ПРАВИЛА

- **MCP недоступен** (context7, hermes-atlas-mcp, sequential-thinking):
  - Запиши в трейс: `MCP_USED: ["context7: offline", "hermes-atlas: offline"]`
  - Продолжай работу БЕЗ MCP
  - Создай blocker в CONTEXT-BUFFER.md: "MCP offline — нужен ручной restore"

- **Скилл не найден** в `.agents/skills/`:
  - Вызови `skill skill-surgeon` с запросом создать нужный скилл
  - Жди создания (15 мин) или работай без скилла с пометкой `SKILLS_LOADED: ["<skill-name>: missing"]`

- **Дешёвая модель игнорирует enforcement** (mimo-v2.5-free, nemotron-3.5-lightning-free):
  - compliance-gate.ps1 (Слой 3) автоматически REJECT
  - Retry на mimo-v2.5-free (попытка 2)
  - 2 REJECT подряд → эскалация на nemotron-3-ultra-free

### 4. ВАЛИДАЦИЯ (Слой 3 — qa-engineer)

qa-engineer проверяет КАЖДУЮ задачу через compliance-gate:

```powershell
# Проверка трейса за последнюю задачу
# 1. Есть ли запись с SKILLS_LOADED и MCP_USED?
# 2. SKILLS_LOADED не пустой?
# 3. Если задача с библиотекой — есть ли context7 в MCP_USED?
# 4. Если задача >3 шагов — есть ли sequential-thinking в MCP_USED?

# Результат: PASS / REJECT + причина
```

## Правила

- **Никаких исключений** — enforcement работает для всех 19 агентов
- **Self-report формат строгий** — парсер ищет именно `SKILLS_LOADED:` и `MCP_USED:`
- **Время на предварительный этап** — не учитывается в таймауте задачи (max 30 сек)
- **Логирование** — все вызовы skill tool и MCP автоматически попадают в traces.jsonl

## Интеграция

### В промпт агента (добавляется в секцию "Обязательный протокол")

```markdown
## 🔴 SKILL ENFORCEMENT (mandatory)
ПЕРЕД работой: skill <нужные-скиллы> → context7 (если библиотека) → sequential-thinking (если >3 шага)
В конце: CONTEXT-BUFFER.md += SKILLS_LOADED: [...], MCP_USED: [...], COMPLIANCE: true
Без этого — BLOCKER, работа не начинается.
```

### В team-lead делегирование (task tool prompt template)

```markdown
## ОБЯЗАТЕЛЬНЫЕ ПОЛЯ В ТЗ:
- Skills: <список из role→skill mapping>
- MCP: <context7/hermes-atlas/sequential-thinking>
- Self-report: ОБЯЗАТЕЛЬНО укажи SKILLS_LOADED и MCP_USED в отчёте
```

## Примеры

### Задача: "Создать Excel отчёт с формулами"
```
1. skill 1c-query (или excel-report если есть)
2. context7_resolve-library-id "exceljs" → context7_query-docs
3. sequential-thinking (планирование листов/формул)
4. Работа
5. Отчёт: SKILLS_LOADED: ["1c-query"], MCP_USED: ["context7", "sequential-thinking"], COMPLIANCE: true
```

### Задача: "Оптимизировать SQL запрос"
```
1. skill 1c-query-optimization
2. context7_resolve-library-id "postgresql" → context7_query-docs
3. sequential-thinking (план оптимизации)
4. Работа
5. Отчёт: SKILLS_LOADED: ["1c-query-optimization"], MCP_USED: ["context7", "sequential-thinking"], COMPLIANCE: true
```

### Задача: "Code review PR" (security-auditor)
```
1. skill windows-safety (если есть файловые операции)
2. context7_query-docs для OWASP/top-10 если нужно
3. Работа
4. Отчёт: SKILLS_LOADED: ["windows-safety"], MCP_USED: [], COMPLIANCE: true
```

## Критерии приёмки (для qa-engineer)

- [ ] skill-enforcement/SKILL.md существует и содержит все секции
- [ ] Все 19 агентов имеют в промпте ссылку на этот скилл
- [ ] registry.json содержит required_skills для всех 19 агентов
- [ ] Self-report формат работает (парсер находит SKILLS_LOADED/MCP_USED)
- [ ] compliance-gate.ps1 валидирует трейсы корректно
- [ ] 3 тестовые задачи = PASS (skills loaded ≠ [])

## Ссылки

- `.opencode/agents/registry.json` — role→skill mapping
- `.agents/skills/README.md` — каталог всех скиллов
- `.opencode/agents/prompts/README.md` — таблица агент → скиллы
- `AGENTS.md §3.4-3.6` — enforcement rules