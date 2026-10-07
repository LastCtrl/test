# Live Supervision + Model Registry (дизайн)

Статус: дизайн утверждён к реализации (2026-10-07). Расширяет план модельного шлюза.

## Идея (от пользователя)
1. **Следить за ИИ во время работы**, а не только оценивать в конце: каждые N минут проверять, не завис ли / нет движения / долго думает → **переотдать задачу другому**, а «зависшего» пометить как нестабильного.
2. **Единый реестр бесплатных ИИ** (все подключённые API) с сортировкой по **скорости, качеству, типу задач, рейтингам (нашим и внешним), доступности** → во время работы **автоматически подкидывать агентам лучших**; если один долго думает на проверке — вызвать другого.

## Целевая архитектура (3 слоя, переиспользуем существующее)

### Слой A — Model Registry (реестр + скоринг)
Источники:
- `openrouter /api/v1/models` (фильтр `pricing.prompt==0 && pricing.completion==0`), метаданные (context, modality);
- aihubmix `/models`, Zen (`opencode` free-list) — по мере доступности;
- **наши данные**: `.memory/ratings.jsonl` (grades), traces (`duration_ms`, `status`), `failure-memory.jsonl`.

Метрики на модель (по задачам/ролям):
| Метрика | Источник | Формула/заметка |
|---|---|---|
| availability | live-probe (PONG/HTTP) + traces | uptime %, OK/429/DEAD |
| speed | traces `duration_ms`, probe latency | p50/p95, tok/s (если есть usage) |
| quality | `ratings.jsonl` grade, verdicts | средний grade по task-type |
| task-fit | эвристика + grades по ролям | code/review/qa/design/analysis |
| cost | pricing | free/paid tier (приоритет free) |
| context | metadata | лимит контекста |
| reputation | внешние (arena/провайдер) опц. | не обязательно |

**Score(model, task_type) = w1·availability + w2·speed + w3·quality + w4·task_fit − w5·cost − w6·instability**
(веса в конфиге; instability — штраф за зависания/ошибки, см. Слой B).
Хранение: `.memory/model-registry.json` (версионируемый, human-readable) + история проб.

### Слой B — Live Supervision (наблюдение во время работы)
Сигналы (уже есть, надо связать):
- `traces.jsonl` (события/вызовы: `session_id, agent, task_id, attempt_id, duration_ms, status`);
- heartbeat Go-цикла (`.memory/driver.lock`, run heartbeat в SQLite `run_events`);
- session/child-session статусы opencode.

Watchdog (каждые 1–2 мин):
- **activity gap** = now − последнее событие по run/session;
- `SUSPECT` (gap > T_suspect, напр. 5 мин) → лог/нотификация, мягкая проба;
- `STALLED` (gap > T_stalled = 2×T_suspect, либо `chunkTimeout` сработал) → действия:
  1. **checkpoint/handoff** (сохранить состояние попытки);
  2. **остановить зависшую попытку** (только свой процесс, по PID с проверкой cmdline — §3.7);
  3. **переотдать задачу ДРУГОМУ агенту/модели** (тот же пул роли, другая модель из Registry, лучший доступный);
  4. **инкремент instability** модели/агента; при N зависаний → `unstable_until = now + cooldown` (исключается из роутинга);
  5. запись в `failure-memory.jsonl` + `model-health.json`;
  6. нотификация (Telegram/лог).
- Различать «думает» и «завис»: если провайдер стримит — по `chunkTimeout` (opencode умеет, задаётся per-provider); если нет — по отсутствию любых событий.

### Слой C — Enforcement (шлюз)
- Go-шлюз (из основного плана) = точка применения: алиасы `router/strong|free|fast` + `router/auto:<task-type>`.
- Per-request: выбрать лучшую модель по Registry (score), при ошибке/таймауте — следующую (до старта стрима).
- Это и даёт «автоматом лучших агентам» + «вызвать другого, если долго».

## Что переиспользуем / что добавляем
| Есть | Добавляем |
|---|---|
| traces/performance/scoring (плагины) | Registry + скоринг + сортировки |
| `model-router.ps1` (probe/breaker/`model-health.json`) | discovery free-моделей из API |
| Go loop heartbeat/recover/checkpoint (M2) | auto-reassign на другую модель + instability-штраф |
| `session-recovery.ps1`, self-healing | watchdog «SUSPECT/STALLED» + handoff |
| `ratings.jsonl`, `failure-memory.jsonl` | join рейтингов в score |

## Фазы реализации
| Фаза | Дельверабл | Оценка |
|---|---|---|
| R1 | Registry-тул: discovery (openrouter/aihubmix) + probe + `.memory/model-registry.json` + CLI-список (сортировки) | 45 мин |
| R2 | Скоринг (speed/quality/task-fit/availability/instability) + интеграция с `model-router` (роутинг по score) | 45 мин |
| R3 | Watchdog «SUSPECT/STALLED» (по traces/heartbeat) + нотификация | 30 мин |
| R4 | Auto-reassign на другую модель/агента + instability + failure-memory | 45 мин |
| R5 | Интеграция в Go-шлюз (алиасы `auto:<task-type>`), UI-список | по плану шлюза |

## Метрики успеха
- Независимая приёмка всегда доступна (≥2 живых ревьюера разных семейств).
- Зависшая задача автоматически переотдаётся ≤ 2·T_stalled.
- Нестабильные модели исключаются из роутинга (cooldown) и не «съедают» квоты.
- Реестр сортируется по заданным осям; роутинг объясним (почему выбрана модель — код причины).
