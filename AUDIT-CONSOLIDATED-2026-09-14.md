# Единый аудит и план agent-hq — 2026-09-14 (v2)

> Свод независимых разборов + анализ тимлида + правки по ревью плана.
> Источники: (1) наш разбор 5 агентами; (2) внешний аудит «Этап 1»; (3) внешний аудит «Вариант B»; (4) эволюционный стратегический план; (5) personal-first workbench plan.
> **Внешние планы (для воспроизводимости):** branch `arena/01a09f7c-test`, files `AGENT_HQ_EVOLUTION_PLAN.md`, `PROJECT_AUDIT_2026-09-14.md`, personal-first plan @ commit `414b4b5`. В текущей ветке их нет — ссылки на источник, не копии.
> **Runtime-находки датированы:** observed_at `2026-09-14`, env: Windows, `D:\Тест\agent-hq`, branch `feature/skills-mcp-enforcement`. Состояние worktree/веток/registry — снимок на эту дату, не вечный факт.
> Статус: **черновик для согласования**. После утверждения — сделать единственным планом (объединить с FULL_PLAN/MASTER_PLAN).

---

## 1. Вердикт (уточнён)

**Pre-Alpha / богатый каркас, главный end-to-end цикл не замкнут.**
Отдельные компоненты **реализованы** (файловые inbox/outbox/archive; CLI registry; CLI queue; шаблоны проектов; плагины JSONL; часть secret-scanner; health/verify). Но **сквозной автоматический workflow `queue → acquire/reserve → inbox → opencode run → outbox → release → scoring → routing` не собран как связанная система.** Это не «0 IMPLEMENTED» — это разрыв интеграции.

Ключевая мысль: **не расширять, а стабилизировать.** Сначала один воспроизводимый, безопасный, транзакционный цикл на Windows, потом фичи.

### Что уже закрыто (Wave 1 P0, коммит `815e266`)
- Poller: реальный exit code + structured result; ошибки → dead-letter (с обрезкой stdout/stderr 4000); успех требует маркер `STATUS: resolved`.
- compliance-gate: матчит реальный формат (`->`/`→`/`>>`, ISO-T, `[TIME]`), пустые SKILLS/MCP = FAIL, try/catch мусорных дат.
- health-check: вердикт по возвращённому значению (был всегда PASS).
- 30 `SKILL.md`: валидный YAML frontmatter (`name`/`description` в кавычках).
- `.gitignore`: `.memory/dead-letter/` игнорируется целиком.
- `api/` orphan удалён.
- Evidence-discipline скилл + AGENTS.md §12.

---

## 2. Критические проблемы

Статус: ✅ закрыто в Wave 1 · ⏳ открыто.

| ID | Проблема | Подтверждение | Статус |
|----|----------|---------------|--------|
| C1 | Ложный DONE: успех = непустой вывод | `inbox-poller.ps1`; `.memory/outbox/test-001.json` | ✅ (815e266) |
| C2 | `task: deny` у всех 30 → делегирование невозможно | `opencode.json`; sync-agents | ⏳ |
| C3 | Рекурсия team-lead (`task … subagent_type=team-lead`) | `prompts/team-lead.txt:8-9` | ⏳ |
| C4 | Race reserve/acquire (read-modify-write без лока) | `agent-registry.ps1:201-236,389-505`; `project-queue.ps1:303-337` | ⏳ |
| C5 | Worktree-изоляция не соблюдается (poller в корне) | `inbox-poller.ps1`; `create-project.ps1:76,87` | ⏳ |
| C6 | Pre-commit secret-scan не работает из worktree (`$GITDIR/../../`) | `.agents/hooks/pre-commit:15` | ⏳ |
| C7 | Ложный фикс `61f8709` (обещан hook-fix, только буфер) | `git show --stat 61f8709` | ⏳ (документируем) |
| C8 | compliance-gate no-op (`>>` vs `->`) | `compliance-gate.ps1` | ✅ (815e266) |
| C9 | health-check всегда PASS | `health-check.ps1` | ✅ (815e266) |
| C10 | opencode.json: legacy `agents` + мёртвые ключи `memory/workspace/projects/modules` | `opencode.json:67,758-812` | ⏳ (P0-A) |
| C11 | Skills без frontmatter → невидимы | 30× `SKILL.md` | ✅ frontmatter; ⏳ discovery-test |
| C12 | Mojibake/BOM (registry.json, 2 JSON) | `registry.json` | ⏳ |
| C13 | Хардкод путей `D:\Тест`, `C:\Users\Ermak_DS` | 8+ скриптов, opencode.json | ⏳ |
| C14 | Poller последователен + глобальный Mutex | `inbox-poller.ps1` | ⏳ |
| C15 | Stuck busy (StaleCheck не release; Complete release до Save) | `project-queue.ps1:462-514,342-387` | ⏳ |
| C16 | Prompt injection (`TASK: $payload` + широкие права) | `inbox-poller.ps1`; `opencode.json` | ⏳ |
| C17 | message-queue.ps1 сломан | `message-queue.ps1:34,70-78,97` | ⏳ |
| C18 | Хук не устанавливается автоматически | sync-agents | ⏳ |
| C19 | **Evidence-Discipline пока только prompt-правило**, не runtime-гарантия | `evidence-discipline/SKILL.md`; AGENTS §12 | ⏳ (P0-C/P1) |

---

## 3. Что добавили внешние аудиты

1. Skills требуют YAML frontmatter — причина невидимости. ✅ применено.
2. Рекурсивный self-call team-lead (fork-bomb).
3. Legacy `agents` + schema `additionalProperties:false` → schema validation в CI.
4. BOM в 2 tracked JSON.
5. Нет frontmatter/encoding-тестов, schema-валидации, Pester, E2E, security-скан-ов, lock-файлов.
6. `api/` orphan. ✅ удалён.
7. Tracer без корреляции, `catch(_){}`.
8. Единый declarative source + генератор (CI: clean diff).
9. Structured verdict / retry budget / lease-heartbeat / SQLite.
10. Fake OpenCode CLI + E2E happy path + intentional rejection.
11. Триаж docs: User Guide / Architecture / Operations / Contributor + ADR; `/doctor`, `/explain`, `/budget`.
12. **Machine-generated evidence** (runtime прикладывает hashes/exit_code/diff_id/tool_call_id, а не модель).
13. **Операционный self-healing** (CNTLM/proxy/provider/session watchdog, checkpoint, token preflight, snapshot-lock).
14. **Go Hybrid control plane** + executor abstraction (personal-first).

## 4. Наши пункты, которых нет в аудитах

- Hook secret-scan bypass из worktree (C6) + ложный коммит 61f8709 (C7).
- `message-queue.ps1` сломан (C17); `registry.json` mojibake + расхождение прав 10 агентов.
- `create-project.ps1` мёртвая ветка worktree; `run-poller.ps1` заглушка; `prompt-gate.ps1` пишет temp в корень.
- `.serena/` LSP mismatch; тесты только `test-vault.ps1`, не в CI.
- `.memory` гигиена (пустой dead-letter, stale progress.md, пустая строка в ratings.jsonl).
- Рабочая ветка на 40 коммитов впереди `main`; 28 `agent/*` веток не слиты; worktree `tech-writer` грязный.

---

## 5. CI — исправление (feedback #4)

**Факт:** `main` обновлялся 2026-09-10 (merge PR #2, `cd405d6`); последний main-run успешен. CI (`.github/workflows/verify.yml`) триггерится на **push в main/master** и **PR в main/master**. Push в feature-ветку **без PR** не проверяется. Проверка **недостаточно глубокая** (наличие файлов/ключевых слов, не поведение; локальные проверки в CI скипаются).

**Вывод:** формулировка «CI мёртв» некорректна. Правильно — «покрытие PR в main есть, но проверка поверхностная; рабочие push в feature-ветку не покрыты; поведенческих/E2E-тестов нет».

---

## 6. Анти-галлюцинации (уточнено по feedback 6,7)

**Проблема:** любая модель (не только DeepSeek) может сообщить непроверенный результат. Prompt-инструкция — **не защита**: агент может написать `DONE, tests passed, artifact: fake.txt`. Даже проверка существования файла недостаточна (файл мог существовать; содержимое неверно; вывод выдуман; diff от другой попытки).

**Двухуровневое решение:**
- **P0-C (parser):** compliance-gate парсит структурированный формат; **отсутствие ожидаемой записи = FAIL** (не «No records → OK»).
- **P1 (runtime evidence):** платформенный runtime, а не модель, прикладывает доказательство:
  ```json
  {"task_id":"tq-001","attempt_id":"attempt-002","tool_call_id":"...","artifact":"src/file.py",
   "sha256_before":"...","sha256_after":"...","git_diff_id":"...","command":"pytest","exit_code":0,
   "stdout_hash":"...","started_at":"...","finished_at":"..."}
  ```
  Self-report сопоставляется с trace по `session_id/task_id/attempt_id/tool_call_id`. Тогда reviewer лишь интерпретирует машинную запись.

Уровень риска галлюцинаций измеряется отдельно по `model/prompt/task profile` — без обобщений про конкретную модель.

---

## 7. Стратегическое направление (новое)

**Принято: Go Hybrid, personal-first.** Не полный rewrite и не «ещё один coding agent».

```
User / CLI / Telegram / (future UI)
            │
            ▼
   Go Control Plane + SQLite        ← владеет lifecycle задачи (не OpenCode)
 API · RBAC · scheduler · supervisor · audit
            │
     versioned Executor interface
      ┌─────┼──────┬─────────┐
      ▼     ▼      ▼         ▼
   OpenCode  ClaudeCode  Codex  fake-executor
            │
     Model/provider layer
```

- **OpenCode — worker, не источник истины.** Падение/зависание его сессии не теряет задачу (durable state).
- **PowerShell** после миграции — только Windows bootstrap/admin, не очередь/scheduler/state.
- **Native Go executor** — только после доказанных ограничений adapter (exit criteria в источнике).
- **Порядок (personal-first):** Milestone 0 (fundament) → 1 (Go runner не теряет процесс) → 2 (durable task + recovery) → 3 (CNTLM/provider/session self-healing) → 4 (worktrees + доказуемая приёмка) → 5 (daily driver) → 6 (коллега/команда).

**Operational self-healing (OR-P0/P1):** диагностика снизу вверх (process → port → proxy probe → network → provider → model → opencode → attempt); безопасный CNTLM restart только owned PID + restart budget + circuit breaker; provider failover с reason codes; session watchdog (heartbeat + progress + soft probe + hard timeout); checkpoint/handoff вместо «продолжай»; token preflight против oversized cold request; snapshot-lock backoff/reconciliation.

**Telegram — адаптер к control API, не отдельный оркестратор** (observe-only → safe ops → approvals). Токен только из vault/env; allowlist chat-id; RBAC; idempotency; redaction.

---

## 8. Roadmap (реструктурирован по feedback #1,5,8)

### P0 — контракты до любой миграции

**P0-A — Runtime configuration**
- ⏳ P0-0: миграция `opencode.json` → канонический `agent`; вынести custom metadata в `agent-hq.json`; добавить JSON-Schema валидацию + CI fail при неизвестном ключе; доказать, что opencode видит **все 30** агентов.
- ✅ frontmatter всем skills; ⏳ native discovery-test; уникальность `name`; сверка `required_skills` registry с существующими скиллами.

**P0-B — Исполнение**
- ✅ настоящий process exit code + structured result (poller).
- ⏳ убрать self-recursion team-lead.
- ⏳ **task allowlist** (deny-by-default, разрешённые роли), а не blanket `"task":"allow"`.
- ⏳ отделить granular command policy от task permissions.
- ⏳ запуск worker в assignment worktree + filesystem boundary.
- ⏳ устранить False DONE на всех terminal paths (в т.ч. queue/registry).

**P0-C — Проверка**
- ✅ compliance parser (реальный формат; отсутствие записи = FAIL).
- ✅ health verdict.
- ⏳ machine-generated evidence + trace correlation (self-report ≠ доказательство).
- ⏳ fake CLI tests (exit 0/1/124, empty, stderr-only, timeout).
- ⏳ intentional rejection E2E (QA реально блокирует неверный результат).

**P0-D — Безопасность и переносимость**
- ⏳ secret hook: фикс worktree-fallback + авто-установка через sync-agents.
- ⏳ убрать абсолютные пути (`$PSScriptRoot`/`AGENT_HQ_ROOT`).
- ⏳ ограничить external_directory + bash (deny-by-default) + доступ к чужим проектам.
- ⏳ redact payload/stdout/stderr/секретов.
- ⏳ pin внешних зависимостей (MCP/actions по версии/SHA) + rollback-tests для миграций.

### P1 — состояние и изоляция (→ Go foundation)
- Атомарный claim (Mutex→SQLite), lease/heartbeat, release на terminal, StaleCheck-Release.
- Per-project worktree + boundary + leak-тест; per-project CONTEXT-BUFFER.
- Единый daemon с worker pool (без глобального bottleneck mutex); единая retry-политика.
- Tracer/scoring v2 с корреляцией; убрать `catch(_){}`.
- Prompt-gate scrub + secret redaction + human approval.
- Go CLI runner + SQLite (tasks/attempts/events/checkpoints) + watchdog/checkpoint/restart.

### P2 — честная оценка и routing
- Evaluation v2 (раздельные capability/reliability/quality/prompt/workflow, n+CI).
- Model router (quota/availability/circuit breaker/dynamic fallback).
- 2 проекта → 5 проектов soak/solo tests.

### P3 — фичи (после зелёного ядра)
Explainable routing · Capability passport · Prompt A/B · Team optimizer · Reviewer-disagreement detector · Failure memory · Task replay · Canary rollout · Confidence-aware · Dynamic verification depth · Semantic dedup · Cost/quality frontier · Autopilot levels · Chaos testing · Policy simulator · `/doctor` `/explain` `/budget`.

---

## 9. Anti-backlog (чего НЕ делать сейчас)

- Не добавлять агентов ради количества; не удалять пул 30 без данных.
- Не строить ML-routing до чистой статистики.
- Не разрешать агентам менять собственные policies.
- Не считать скорость качеством; не принимать self-report за приёмку.
- Не гарантировать `$0` без контроля provider policy.
- Не экспериментировать моделями на Critical-задачах.
- Не писать собственный native Go agent runtime/MCP/provider loop до доказанных ограничений adapter.
- Не строить generic SaaS до внутреннего rollout.
