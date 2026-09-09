# Model Router Skill

## Текущее состояние (2026-09-09, АВАРИЙНАЯ МИГРАЦИЯ)

** ВСЕ 30 агентов работают на `tokenrouter/z-ai/glm-5.3-free` **

Причина: квота opencode free-tier исчерпана («Free usage exceeded, subscribe to Go») — модели opencode/mimo-v2.5-free, opencode/nemotron-3.5-lightning-free, opencode/nemotron-3-ultra-free НЕДОСТУПНЫ. Все запросы к ним виснут/падают.

Провайдер TokenRouter (ключ {env:TOKENROUTER_API_KEY}, отдельная квота) — единственный рабочий.

## Правила выбора модели

| Тип задачи | Модель | Критерий | Стоимость |
|-----------|--------|----------|-----------|
| ВСЕ задачи (все агенты) | `tokenrouter/z-ai/glm-5.3-free` | Основная и единственная рабочая модель | $0 |
| Фоллбек (если GLM упал 2 раза) | ждать/повтор позже | Квота opencode может восстановиться — проверить `opencode run "ping" ` | $0 |

## Лестница эскалации (§5 AGENTS.md)

Единственная модель — эскалация по МОДЕЛИ невозможна. Вместо неё:
- Retry-3 (§5) → другой АГЕНТ (копия) на той же модели
- x2-timeout (§3.2) → передача задачи другой копии агента
- Слабый результат → более детальное ТЗ + skill-pinning (пути к SKILL.md в ТЗ)

## Восстановление после квоты (когда opencode вернёт free-tier)

Вернуть распределение:
- `glm-5.3-free` (TokenRouter): team-lead ×4, product-manager, code-reviewer ×2, dev-1/3 (+копии)
- `mimo-v2.5-free`: frontend, legal-advisor, smm-strategist, skill-surgeon, tech-writer ×2
- `lightning`: backend ×2, dev-2(+1), devops, data-engineer, db-specialist, integration-specialist, mobile-dev
- `ultra`: qa-engineer ×2, security-auditor ×2

Проверка восстановления: `opencode run "ping"` — если отвечает (не «Free usage exceeded»), можно вернуть лестницу lightning → mimo → glm-5.3 → ultra.

## Cost-Aware Routing

Все модели $0. Приоритет по latency: GLM 5.3 единственная — просто используй её.

### Формат лога переключений
```
[timestamp] agent={agent} task={task_id} from={old_model} to={new_model} reason={reason}
```

## Примеры

- Любая задача → `glm-5.3-free` (нет альтернатив)
- Ревью/оркестрация/разработка/тесты → `glm-5.3-free`
- GLM упал 2 раза подряд → записать в .memory/traces/model-switch.log, подождать 5 мин, retry
