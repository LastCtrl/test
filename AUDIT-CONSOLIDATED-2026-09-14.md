# Единый аудит и план agent-hq — 2026-09-14

> Свод трёх независимых разборов + анализ нашего тимлида.
> Источники: (1) наш разбор 5 агентами; (2) внешний аудит «Этап 1»; (3) внешний аудит «Вариант B»; (4) стратегический эволюционный план.
> Статус: **черновик для согласования**. После утверждения — сделать единственным планом (объединить с FULL_PLAN/MASTER_PLAN).

---

## 1. Вердикт

**Pre-Alpha / прототип с богатой документацией.** Каркас ролей, очередей, памяти, скиллов и наблюдаемости — есть. **Главный end-to-end цикл не замкнут**: 0 IMPLEMENTED, ~5 PARTIAL, 2 DOCUMENTED ONLY, 6 BROKEN (по консенсусу трёх аудитов).

Ключевая мысль: **не расширять, а стабилизировать.** Сначала один воспроизводимый, безопасный, транзакционный цикл на Windows, потом фичи.

---

## 2. Критические проблемы (подтверждены)

| ID | Проблема | Подтверждение | Источник |
|----|----------|---------------|----------|
| C1 | **Ложный DONE**: poller считает успехом непустой вывод (stderr/ошибки) → `outbox/status:done` | `inbox-poller.ps1:247-251`; артефакт `.memory/outbox/test-001.json` («agent dev-1 not found … permission denied» + `status: done`) | все 3 |
| C2 | **`task: deny` у всех 30 агентов** → делегирование невозможно | `opencode.json`; sync-agents ставит deny при отсутствии task | все 3 |
| C3 | **Рекурсия в промпте team-lead** (`task … subagent_type=team-lead`) → fork-bomb | `prompts/team-lead.txt:8-9` | аудиты 2,3 |
| C4 | **Race при reserve/acquire** (read-modify-write без лока) → двойное назначение | `agent-registry.ps1:201-236,389-505`; `project-queue.ps1:303-337` | все 3 |
| C5 | **Worktree-изоляция не соблюдается**: poller запускает `opencode run` в корне, не в worktree | `inbox-poller.ps1:243-246`; `create-project.ps1:76,87` (ветка worktree мертва) | все 3 |
| C6 | **Секретный pre-commit не работает из worktree** — битый fallback `$GITDIR/../../` | `.agents/hooks/pre-commit:15` | наш (нет в аудитах) |
| C7 | **Ложный фикс `61f8709`**: обещан worktree-fix + «live 4/4», фактически только CONTEXT-BUFFER | `git show --stat 61f8709` | наш |
| C8 | **compliance-gate — no-op**: регексп `>>` vs реальные `->` (0 совпадений) | `compliance-gate.ps1:25`; в буфере 23×`->`, 0×`>>` | наш + аудит 3 |
| C9 | **health-check всегда PASS** по compliance (`$LASTEXITCODE` при `return $false`) | `health-check.ps1:127-132` | наш + аудит 2 |
| C10 | **opencode.json: legacy `agents` + мёртвые ключи** `memory/workspace/projects/modules`; схема `additionalProperties:false` | `opencode.json:67,758-812` | аудиты 2,3 |
| C11 | **Skills без YAML frontmatter** → opencode их не обнаруживает (нет `name`/`description`) | 29× `SKILL.md`, старт без frontmatter | аудиты 2,3 |
| C12 | **Mojibake + BOM**: registry.json кириллица битая; 2 tracked JSON с BOM | `registry.json`, 2 файла | наш + аудит 3 |
| C13 | **Хардкод путей** `D:\Тест\agent-hq`, `C:\Users\Ermak_DS` в 8+ скриптах и конфиге | inbox-poller:10, session-recovery:54..139, sync-agents:376 | все 3 |
| C14 | **Poller последователен + глобальный Mutex** → нет параллелизма 5 проектов | `inbox-poller.ps1:47-52,303-314,Wait 900s` | все 3 |
| C15 | **Stuck busy**: StaleCheck не освобождает агента; Complete release до Save | `project-queue.ps1:462-514,342-387` | все 3 |
| C16 | **Prompt injection**: `TASK: $payload` вклеивается без экранирования + bash/edit/ широкий external_directory | `inbox-poller.ps1:229-231`; `opencode.json:846-853` | все 3 |
| C17 | **message-queue.ps1 сломан** (timestamp, всегда-блок, Archive удаляет outbox) | `message-queue.ps1:34,70-78,97` | наш |
| C18 | **Хук не устанавливается автоматически** (sync-agents не копирует в `.git/hooks`) | grep по скриптам | наш |

---

## 3. Что добавили внешние аудиты (у нас этого не было)

1. **Skills требуют YAML frontmatter** (`name`,`description`) — вероятная настоящая причина невидимости скиллов.
2. **Рекурсивный self-call team-lead** (fork-bomb) в промпте.
3. **Legacy-ключ `agents` + `additionalProperties:false`** → валидация схемы в CI (мы видели, что миграция работает, но риск реален).
4. **BOM в 2 tracked JSON** ломает строгий парсер.
5. **Отсутствие frontmatter/encoding-тестов, schema-валидации, Pester, E2E-тестов, security-скан-ов и lock-файлов** зависимостей.
6. **api/main.py — orphan** (не в CI/архитектуре, без тестов/Docker).
7. **Tracer без корреляции** (нет project/task/agent/model), `catch(_){}` скрывает свои же ошибки.
8. **Единый declarative source** агентов + детерминированный генератор (CI: clean diff).
9. **Structured verdict / retry budget / lease-heartbeat / SQLite-миграция** как целевая архитектура.
10. **Fake OpenCode CLI + E2E happy path + intentional rejection** для тестов.
11. **Триаж документов**: README → User Guide / Architecture / Operations / Contributor + ADR; команды `/doctor`, `/explain`, `/budget`.

---

## 4. Наши пункты, которых нет в аудитах (важно сохранить)

- Hook secret-scan bypass из worktree (C6) + ложный коммит 61f8709 (C7).
- `message-queue.ps1` сломан (C17).
- `registry.json` mojibake + расхождение прав 10 агентов.
- `create-project.ps1` мёртвая ветка worktree; `run-poller.ps1` заглушка; `prompt-gate.ps1` пишет temp в корень.
- `.serena/` LSP mismatch (powershell LSP, память о JS-проекте).
- Тесты: только `test-vault.ps1`, не в CI.
- `.memory` гигиена: пустой dead-letter, stale progress.md, пустая строка в ratings.jsonl.
- 27 worktree вморожены на `30f3830`; 28 `agent/*` веток не слиты; `tech-writer` worktree грязный.
- CI триггерится только на `main` (мёртв с 27.08) → не покрывает текущую работу.

---

## 5. Дополнительные предложения (сверх аудитов)

1. **Evidence-Discipline skill (анти-галлюцинации)** — см. §6. Обязателен для всех агентов.
2. **Единый `NOT ENOUGH EVIDENCE` маркер** в промптах: агент обязан отличать проверенное от предположения.
3. **Generator `agents.yaml → opencode.json + cards + docs`** с проверкой в CI «no dirty diff».
4. **`doctor`-preflight**: схема, permissions, skills discovery, MCP, worktree, SQLite, пути.
5. **Fake-CLI harness** для детерминированных тестов poller (exit 0/1/124, empty, stderr-only, timeout).
6. **Import-graph линтер промптов**: ловит ссылки на несуществующие скиллы/скрипты (у нас уже есть мёртвые ссылки).
7. **Secret-canary** в тестах: подсунуть фейковый токен в payload → проверить, что не попал в outbox/buffer/CI-артефакт.
8. **Авто-архивация CONTEXT-BUFFER** (сейчас растёт до 88 KB) + генерация summary из событий.

---

## 6. Анти-галлюцинации (обязательный пункт плана)

DeepSeek (и другие) любят выдумывать файлы, команды и «готово». Ввести принудительно:

**A. Новый скилл `.agents/skills/evidence-discipline/SKILL.md`** с YAML frontmatter:
- Правило 1: не утверждать существование файла/команды/API без чтения/проверки.
- Правило 2: если не проверено — писать `NOT ENOUGH EVIDENCE: <что именно>`.
- Правило 3: `DONE` только с артефактом (путь + вывод команды/строка) — иначе `PARTIAL`.
- Правило 4: ссылки на код — в формате `path:line`, только после чтения.
- Правило 5: несуществующий скилл/скрипт/модель — явно `missing`, без выдумывания.
- Правило 6: различать «прочитал» / «предположил» / «сделал».

**B. Блок в каждый промпт агентов** (генерируется `sync-agents.ps1`): 6 правил выше + запрет «успеха без артефакта».

**C. Раздел в AGENTS.md** «§12 Evidence-discipline» + требование указывать в self-report, что проверено, а что предположено.

**D. Обеспечение (gate):** список сообщённых файлов в self-report сверяется с существованием на диске; несуществующий артефакт в `DONE` → REJECT.

---

## 7. Идеи фич (backlog, после стабилизации)

Из эволюционного плана — принимаем как P3 (не раньше надёжного ядра):

1. Explainable Routing (reason codes выбора агента/модели).
2. Capability Passport модели (языки, tool-calling, контекст, квоты, reliability, n).
3. Prompt A/B Testing по hash версии.
4. Team Composition Optimizer (минимальный состав под риск).
5. Reviewer Disagreement Detector (не majority, а evidence + tie-breaker).
6. Failure Memory (сигнатуры ошибок → фиксы → модели, что справились).
7. Task Replay (полное воспроизведение прогона).
8. Canary Model Rollout (shadow → 5% → 15% → prod).
9. Confidence-aware Automation.
10. Dynamic Verification Depth (по risk/novelty/reversibility).
11. Semantic Task Deduplication (переиспользование research между проектами).
12. Cost/Quality Frontier (Pareto, а не одно число).
13. Project Autopilot Levels 0…4.
14. Chaos Testing (timeout, quota, malformed, застрявший worker, конфликт).
15. Policy Simulator (прогон политик на истории).
16. Команды `/doctor`, `/explain`, `/budget`.

---

## 8. Целевая архитектура (согласовано)

```
agents.yaml (единственный source)
   ├─ generator → opencode.json (только валидные ключи)
   ├─ generator → cards / docs
   └─ validator → JSON Schema + semantic checks

Intake → Classifier → Planner → Scheduler(pool/lease/heartbeat)
   → Model Router → Isolated Worker(worktree, structured result)
   → Verification → Complete/Retry/Escalate/Rollback → Evaluator → Report
```

Состояние: **SQLite** (projects, tasks, attempts, agents, assignments, models, provider_health, evaluations, events, approvals, prompt_versions, artifacts). Markdown — производное представление.

---

## 9. Roadmap

### P0 — сломано/ложно (старт немедленно)
| # | Задача | Файлы | DoD / тест |
|---|--------|-------|------------|
| P0-1 | Native exit code в poller + structured result | inbox-poller.ps1 | ошибка агента → dead-letter, НЕ outbox |
| P0-2 | Скрипт установки хука + фикс worktree-fallback | sync-agents.ps1, hooks | секрет в worktree блокируется; хук ставится автоматически |
| P0-3 | Фикс регекспа compliance-gate под `->` | compliance-gate.ps1 | поддельный self-report → FAIL |
| P0-4 | Фикс verdict health-check | health-check.ps1 | пустая система → не PASS |
| P0-5 | permissions: task allow оркестратору + убрать self-call; сузить external_directory/bash | opencode.json, sync-agents, prompts | делегирование работает, чужой проект недоступен |
| P0-6 | **Evidence-discipline** скилл + блок в промпты + §12 AGENTS | .agents/skills, prompts, AGENTS.md | несуществующий артефакт в DONE → REJECT |
| P0-7 | portability: `$PSScriptRoot`/env вместо хардкодов | 8 скриптов, opencode.json | клон в C:\tmp работает без D:\Тест |

### P1 — состояние и изоляция
- Атомарный claim (Mutex→SQLite), lease/heartbeat, release на terminal, StaleCheck-Release.
- Per-project worktree + boundary enforced + leak-тест.
- Per-project CONTEXT-BUFFER + routing inbox.
- Единый daemon с worker pool (ThrottleLimit), единая retry-политика.
- Tracer/scoring v2 с корреляцией; убрать `catch(_){}`.
- Prompt-gate scrub + secret redaction + human approval.

### P2 — честная оценка и routing
- Evaluation v2 (раздельные capability/reliability/quality/prompt/workflow, n+CI).
- Model router с quota/availability/circuit breaker.
- 5-project soak test.

### P3 — фичи из §7 (после зелёного ядра).

---

## 10. Anti-backlog (чего НЕ делать сейчас)

- Не добавлять новых агентов ради количества.
- Не удалять пул 30 агентов без данных.
- Не строить ML-routing до чистой статистики.
- Не разрешать агентам менять собственные policies.
- Не считать скорость качеством.
- Не принимать self-report за приёмку.
- Не гарантировать `$0` без контроля provider policy.
- Не экспериментировать моделями на Critical-задачах.
