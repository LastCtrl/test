---
name: model-router
description: "Правила выбора модели для задач агентов и лестница эскалации. Применять при выборе модели под задачу и обработке отказов провайдеров."
---

# Model Router Skill

## Текущее состояние (2026-09-15)

Живой список — AGENTS.md §1. Источник правды по агентам: `.opencode/agents/*.json` → `sync-agents.ps1` → блок `agent` в `opencode.json`.

### Разработчики
| Агенты | Модель |
|--------|--------|
| dev-*, backend*, frontend, devops, data-engineer, db-specialist, mobile-dev, integration-specialist, product-manager, tech-writer*, smm-strategist, skill-surgeon, legal-advisor, team-lead* | `opencode-go/deepseek-v4.1-flash` |

### Проверяющие (8)
| Агент | Модель | Назначение |
|------|--------|-----------|
| senior-reviewer | `opencode-go/qwen3.8-flash` | крупные/значимые приёмки (ПЛАТНАЯ, согласована) |
| senior-reviewer-1 | `opencode-go/deepseek-v4.1-flash` | запасной senior (ПЛАТНАЯ, согласована) |
| code-reviewer | `aihubmix/gpt-5.5-free` | крупные ревью (free: 100 req/сут, 1M ток/сут) |
| code-reviewer-1 | `opencode/big-pickle` | free |
| qa-engineer | `opencode/ling-3.0-flash-fin-free` | free, самый быстрый |
| qa-engineer-1 | `opencode/mimo-v2.5-free` | free |
| security-auditor | `aihubmix/coding-glm-5.1-free` | free |
| security-auditor-1 | `opencode/nemotron-3.5-lightning-free` | free |

## Что недоступно (на 2026-09-15)
- `tokenrouter/*` — баланс $0 (включая nemotron free) → провайдер мёртв.
- `tokenrouter/z-ai/glm-5.3-free` — больше не бесплатна / нет канала (`No available channel ... distributor`).
- `openrouter/*:free` — дневной лимит free-моделей исчерпан (сброс раз в сутки).
- `openrouter/z-ai/glm-5.2:free` — больше не free (платный слаг `z-ai/glm-5.2`).
- `aihubmix/coding-glm-4.7-free`, `coding-glm-5-free`, `coding-kimi-k3-free`, `coding-minimax-m3-free` — ошибки на 2026-09-15.
- `opencode/muse-spark-*-contributor-free` — недоступны в стране.

## Правила выбора модели
- Разработка/рутина → `opencode-go/deepseek-v4.1-flash` (рабочая лошадка).
- Крупная/значимая приёмка → `senior-reviewer` (qwen3.8-flash) или `code-reviewer` (gpt-5.5-free).
- Обычная приёмка/тесты → free-проверяющие (`ling-3.0-flash-fin-free`, `mimo-v2.5-free`, `big-pickle`, `nemotron-3.5-lightning-free`, `coding-glm-5.1-free`).
- Платные — ТОЛЬКО `senior-reviewer`/`senior-reviewer-1` (согласовано 2026-09-15). Остальные платные запрещены.

## Лестница эскалации (§5 AGENTS.md)
1. Retry-2: тот же агент на своей модели.
2. Retry-3: ДРУГОЙ агент-копия; при неудаче — поднять класс модели (free-проверяющий → `code-reviewer` gpt-5.5-free → `senior-reviewer` qwen3.8-flash).
3. x2-timeout (§3.2): передача задачи другой копии агента.
4. Слабый результат → детальное ТЗ + skill-pinning (пути к SKILL.md в ТЗ).

## Проверка доступности модели
```
opencode run --model <provider/model> "Reply with exactly: PONG"
```
`PONG` → жива. `No available channel` / `Rate limit exceeded` / `credit ... insufficient` → мёртва.

## Новые модели в provider
Модели, которых нет в каталоге models.dev (напр. `aihubmix/gpt-5.5-free`), объявляются в `opencode.json` → `provider.<id>.models.<model-id>`; иначе `UnknownError`.
