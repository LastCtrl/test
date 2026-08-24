# Self-Healing Protocol

## Автоматическое восстановление при ошибках

### Уровень 1: Retry (повтор)
- **Условие**: ошибка сети, таймаут, временная недоступность
- **Действие**: повторить запрос 2 раза с экспоненциальной задержкой (1с, 2с, 4с)
- **Лог**: `.memory/traces/retry.log`

### Уровень 2: Fallback (резервная модель)
- **Условие**: основная модель упала 2 раза подряд
- **Действие**: переключиться на резервную модель
- **Маппинг**:
  - `mimo-v2.5-free` → `nemotron-3-ultra-free`
  - `nemotron-3.5-lightning-free` → `mimo-v2.5-free`
  - `nemotron-3-ultra-free` → `mimo-v2.5-free`
- **Лог**: `.memory/traces/fallback.log`

### Уровень 3: Task Escalation (эскалация задачи)
- **Условие**: агент не смог выполнить за 2 попытки
- **Действие**:
  1. Откатить изменения агента (git restore / удалить созданные файлы)
  2. Записать blocker в `.memory/inbox/{agent}/blocker-{id}.json`
  3. Передать задачу другому агенту
- **Лог**: `.memory/traces/escalation.log`

### Уровень 4: Circuit Breaker (разрыв цепи)
- **Условие**: 5 ошибок подряд от одного агента/модели
- **Действие**:
  1. Заблокировать агента/модель на 5 минут
  2. Уведомить team-lead через `.memory/inbox/team-lead/blocker-{id}.json`
  3. После истечения таймаута — попробовать снова
- **Лог**: `.memory/traces/circuit-breaker.log`

## Формат логов

```json
{
  "timestamp": "2026-08-21T16:00:00Z",
  "level": "retry|fallback|escalation|circuit-breaker",
  "agent": "dev-1",
  "model": "mimo-v2.5-free",
  "task_id": "task-001",
  "error": "timeout after 30s",
  "action": "retry #1",
  "success": true
}
```

## Мониторинг

### Проверка здоровья агентов
- Каждые 30 минут: проверить `.memory/traces/` на наличие ошибок
- Если >= 5 ошибок за час → алерт team-lead
- Если агент не отвечал > 10 минут → пометить как inactive

### Автоматическая очистка
- Логи старше 7 дней → архив в `.memory/archive/traces/`
- Blocker'ы старше 3 дней с статусом resolved → удалить
