# PHASE2 AUDIT PART 2/2

**Решение:** разделить latency, correctness, retry rate, acceptance rate, token efficiency и user rating. Не сводить их в одно число без документированной модели.

### P2-6. Memory и context bus не масштабируются

Общий append-oriented Markdown создаёт конфликты, не имеет схемы, идемпотентности, sequence number и устойчивого consumer offset. Чтение «последних 30 строк» может обрезать одну большую запись или пропустить контекст.

**Решение:** event store SQLite/JSONL с project/task IDs и sequence; Markdown summary генерировать отдельно.

---

## 6. Взгляд с трёх аналитических позиций

### Архитектор продукта

- Сильная сторона — роли и desired workflow описаны подробно.
- 30 агентов обоснованы как **общий пул для нескольких одновременных проектов**; сокращать каталог ролей не обязательно.
- Главная проблема не в размере пула, а в незавершённой автоматической связке `project queue → acquire/reserve → inbox worker → complete/release`.
- Рекомендация — сохранить 30 зарегистрированных ролей, но сначала подтвердить MVP-путь на временной команде из 3–5 выбранных агентов. Остальные должны оставаться `free`, а не запускаться на каждый запрос.

### Senior/Staff инженер

- Главные риски — конфигурационный drift, non-atomic state, отсутствие контрактных тестов и fail-open validation.
- Рекомендация — typed schemas, один generator, SQLite state store, Pester tests, настоящий E2E.
- PowerShell можно сохранить как CLI shell, но core state machine лучше вынести в тестируемый Python/TypeScript модуль.

### Security/SRE

- Главные риски — broad bash/edit/external access, непроверяемый supply chain MCP-команд, скрытые исключения и отсутствие audit correlation.
- Рекомендация — deny by default, sandbox boundary, allowlist commands/providers, redaction, signed/locked dependencies, metrics/SLO и disaster-recovery tests.

---

## 7. Рекомендуемая целевая архитектура

```text
agent-hq.yaml (единственный declarative source)
        │
        ├── generator → opencode.json (только валидные OpenCode keys)
        ├── generator → agent cards/docs
        └── validator → JSON Schema + semantic checks

CLI / OpenCode orchestrator
        │
        ▼
SQLite state store
(projects, tasks, attempts, agents, leases, events)
        │
        ├── scheduler/lease manager
        ├── worker runner (structured exit/result)
        ├── policy engine (permissions/compliance)
        └── telemetry exporter

Markdown README / CONTEXT summary = generated views, не база данных
```

Ключевые свойства:

- transactional task claim;
- lease timeout и heartbeat;
- idempotency key;
- bounded retries;
- structured result contract;
- append-only audit events;
- project isolation;
- policy deny-by-default;
- reproducible config generation.

---

## 8. План доработок

### Этап 0 — сохранить воспроизводимость (0.5–1 день)

- Зафиксировать используемую версию OpenCode.
- Сохранить её JSON Schema в repo или pin download checksum.
- Записать один реальный failing/successful launch log.
- Создать baseline smoke test.

**Готово, когда:** чистая машина может воспроизвести текущий запуск по инструкции.

### Этап 1 — устранить P0 (2–4 дня)

- Исправить `agent`/custom config blocks.
- Выдать orchestrator корректный task allowlist.
- Добавить frontmatter всем skills.
- Переписать compliance на structured records.
- Сохранять настоящий exit code poller.
- Добавить тест каждого исправления.

**Готово, когда:** schema validation и минимальный E2E проходят на Windows CI.

### Этап 2 — надёжное состояние (3–6 дней)

- Перенести registry/queue/attempts в SQLite.
- Реализовать lease/heartbeat/idempotency.
- Добавить concurrent tests (2–20 workers).
- Оставить JSON/Markdown exports для просмотра.

**Готово, когда:** конкурентные reserve/claim не теряют задачи и не назначают агента дважды.

### Этап 3 — безопасность и наблюдаемость (2–4 дня)

- Перейти на deny-by-default permissions.
- Убрать персональные абсолютные пути.
- Ввести correlation IDs и event schema.
- Добавить log rotation/redaction/error counters.
- Подключить dependency/security scans.

**Готово, когда:** security test подтверждает границы worktree и отсутствие доступа к посторонним каталогам.

### Этап 4 — документация и UX (1–3 дня)

- Перегенерировать docs из source config.
- Написать 10-минутный quick start.
- Разделить current state и roadmap.
- Добавить команды `doctor`, `validate`, `smoke-test`.

**Готово, когда:** новый пользователь запускает demo без знания внутренней архитектуры.

### Этап 5 — проверка многопроектного пула после стабилизации

- Сохранить каталог из 30 агентов как общий пул.
- Сначала проверить динамическое выделение 3–5 агентов двум проектам.
- Затем провести нагрузочный тест пяти проектов с разными временными командами.
- Добавлять новые копии ролей только при измеренной queue latency/utilization; существующие копии пока можно оставить.
- Проверить, что незадействованные агенты остаются `free`, один agent ID не назначается двум проектам, а завершение задачи всегда освобождает агента.
- Сравнивать модели на фиксированном benchmark-наборе, а не по субъективным единичным ratings.

---

## 9. Предлагаемая CI-матрица

| Job | ОС | Что проверяет |
|---|---|---|
| config | ubuntu | JSON Schema, generated diff, prompt refs, skill frontmatter |
| powershell-unit | windows | Pester для queue/registry/poller/compliance |
| node-unit | ubuntu/windows | tracer/scoring events и failures |
| python-unit | ubuntu/windows | FastAPI health/control-plane, если API остаётся |
| security | ubuntu | gitleaks, CodeQL, dependency audit |
| integration | windows | fake OpenCode CLI: exit codes, timeout, retry, dead-letter |
| e2e | windows | реальный pinned OpenCode, одна делегация и QA rejection |
| concurrency | windows | race tests reserve/claim/complete |

CI должен падать при:

- неизвестном ключе OpenCode config;
- нераспознанном skill;
- пустом/невалидном self-report;
- nonzero worker exit;
- duplicate task claim;
- несовпадении generated files;
- mojibake/BOM policy violation.

---

## 10. Дополнительные функции и идеи развития

Подробная реализация и место каждой функции в roadmap описаны в `AGENT_HQ_EVOLUTION_PLAN.md`. Ниже — сводный список предложений, дополняющих исходную концепцию проекта.

### 10.1 Explainable Routing

Для каждого назначения сохранять объяснение выбора агента и модели: специализация, рейтинг, доступность, квота, риск, стоимость и причины отклонения альтернатив. Это позволит проверять решения router и отлаживать неверные назначения.

### 10.2 Capability Passport модели

Поддерживать автоматически обновляемую карточку каждой модели:

- сильные и слабые типы задач;
- качество tool calling;
- поддерживаемые языки и технологии;
- context window;
- latency и стоимость;
- provider limits;
- reliability;
- количество наблюдений и confidence.

### 10.3 Prompt A/B Testing

Версионировать prompts по hash, безопасно направлять часть Low-risk задач на candidate-версию и сравнивать acceptance rate, retries, latency и tokens. Новая версия становится основной только после устойчивого улучшения; при деградации выполняется rollback.

### 10.4 Team Composition Optimizer

Оценивать не только отдельных агентов, но и состав команды. Например, сравнивать `backend + QA`, `backend + reviewer` и `backend + QA + reviewer`, чтобы находить минимальную команду, обеспечивающую необходимое качество для конкретного риска.

### 10.5 Reviewer Disagreement Detector

Если QA, code-reviewer и security-auditor дают противоречивые verdict, система не выбирает простое большинство, а сравнивает evidence, запускает детерминированные тесты и при необходимости назначает независимого tie-breaker.

### 10.6 Failure Memory

Хранить структурированные сигнатуры прошлых ошибок, неудачные подходы, успешные исправления и модели, которые справились. Перед retry искать похожие случаи и добавлять релевантный опыт в задание, не передавая агенту весь общий журнал.

### 10.7 Task Replay

Сохранять достаточно данных для воспроизведения выполнения: исходный prompt, base commit, версии файлов, model parameters, tool calls, результаты и verdict. Это необходимо для отладки, расследования false DONE и честного сравнения моделей.

### 10.8 Canary Model Rollout

Подключать новые модели по этапам: shadow tasks → 5% Low-risk → 15% Normal-risk → production promotion. При превышении порога ошибок или снижении качества автоматически откатывать routing.

### 10.9 Confidence-aware Automation

Учитывать уверенность классификатора, evaluator и model ratings. Низкая уверенность приводит не к случайному автоматическому решению, а к дополнительному planner/reviewer, тестам или запросу подтверждения.

### 10.10 Dynamic Verification Depth

Выбирать глубину проверки по risk, novelty, reversibility и blast radius. Документационная правка получает лёгкую проверку, а authentication, DB migration или destructive operation — полный QA/review/security pipeline.

### 10.11 Semantic Task Deduplication

Находить одинаковые research/documentation задачи в разных проектах и безопасно переиспользовать уже проверенный общий результат, сохраняя изоляцию приватного контекста проектов.

### 10.12 Cost/Quality Frontier

Показывать не единственного «победителя», а Pareto-варианты: самая быстрая, самая дешёвая, самая качественная модель и лучший баланс. Project policy выбирает подходящий режим.

### 10.13 Project Autopilot Levels

Ввести уровни автономности:

| Уровень | Режим |
|---|---|
| 0 | Observe — только рекомендации |
| 1 | Assist — выполнение после подтверждения |
| 2 | Auto-safe — автономные обратимые Low/Normal задачи |
| 3 | Auto-project — автономный workflow с checkpoints |
| 4 | Full autonomy — human approval только для Critical действий |

### 10.14 Chaos Testing

Регулярно моделировать timeout, quota exhaustion, malformed output, зависший worker, потерю heartbeat, повреждение state, конфликт worktree, недоступный MCP и противоречие reviewers. Система должна доказать, что не теряет задачу и не создаёт false DONE.

### 10.15 Policy Simulator

Перед включением новой routing/permission policy проигрывать исторические события и показывать, какие назначения изменились бы, где выросли бы стоимость или latency и какие операции были бы запрещены.

### Приоритет внедрения

Эти функции не должны задерживать исправление P0. Рекомендуемый порядок:

1. после надёжного scheduler — Explainable Routing, Task Replay и Failure Memory;
2. после Evaluation v1 — Capability Passport и Cost/Quality Frontier;
3. после накопления статистики — Canary Models, Prompt A/B и Team Optimizer;
4. после стабилизации production workflow — Autopilot Levels, Chaos Testing и Policy Simulator.

---

## 11. Конкретный backlog

### P0

- [ ] Мигрировать `opencode.json` на актуальную schema (`agent`, только допустимые keys).
- [ ] Исправить generator `sync-agents.ps1`.
- [ ] Разрешить task tool только orchestrator по allowlist.
- [ ] Добавить YAML frontmatter 29 skills.
- [ ] Заменить Markdown-regex compliance структурированной схемой.
- [ ] Исправить передачу native exit code в poller.
- [ ] Написать E2E happy path + intentional rejection.

### P1

- [ ] Сделать queue/registry transactional.
- [ ] Сузить bash/edit/external permissions.
- [ ] Создать единый source агента и deterministic generator.
- [ ] Исправить encoding/mojibake/BOM.
- [ ] Добавить Pester и CI schema validation.
- [ ] Ввести correlation IDs и честные telemetry metrics.
- [ ] Убрать machine-specific paths в local override.

### P2

- [ ] Решить судьбу FastAPI API.
- [ ] Pin/lock dependencies и включить update/security automation.
- [ ] Разделить документацию current/target.
- [ ] Сгенерировать agent/model/skill tables.
- [ ] Переработать scoring.
- [ ] Ввести retention/rotation для events и memory.

---

## 12. Выполненные проверки

- `git status`, дерево и история репозитория;
- строгий JSON parse 81 файла: 2 файла с BOM не проходят обычное чтение UTF-8;
- Node syntax check двух plugins: успешно;
- Python compile `api`: успешно;
- импорт API не выполнялся из-за отсутствующих в sandbox зависимостей;
- подсчёт и сопоставление 30 agent configs/registries/prompts;
- анализ permissions;
- поиск секретов и опасных process/file patterns;
- проверка текущего GitHub Actions: последний run успешен;
- проверка актуальной OpenCode schema/docs на 2026-09-14;
- анализ PowerShell read-modify-write, poller и compliance flow;
- проверка encoding и документальных противоречий.

### Ограничения аудита

- В Linux sandbox нет `powershell`/`pwsh`, поэтому PowerShell scripts не были исполнены локально.
- Не выполнялся реальный OpenCode/TokenRouter запрос: это могло бы расходовать внешнюю квоту и требует локального окружения владельца.
- Нет независимых запусков конкретных закрытых моделей под их именами.

---

## 13. Финальная рекомендация

Проект стоит продолжать: концепция полезная, а значительная часть каркаса уже создана. Но следующая версия должна быть не «ещё больше агентов», а **стабилизационный релиз**.

Предлагаемая цель релиза:

> `v0.1 — один воспроизводимый, безопасный, транзакционный и наблюдаемый end-to-end workflow на Windows: из общего пула 30 агентов выбирается минимальная команда, задача проходит acquire → execute → review → release, а результат подтверждается CI.`

После этого можно объективно измерять, сколько агентов одновременно нужно каждому проекту, какие роли становятся узкими местами, какие модели лучше и где параллелизм действительно даёт выигрыш.

---

## Актуальные внешние ориентиры

- OpenCode config schema: `https://opencode.ai/config.json`
- OpenCode agents: `https://opencode.ai/docs/agents/`
- OpenCode permissions: `https://opencode.ai/docs/permissions/`
- OpenCode skills: `https://opencode.ai/docs/skills/`
- OpenCode plugins: `https://opencode.ai/docs/plugins/`


---
Аудит получен. Ответь только: `Аудит принят, жду стратегический план`.
