# Performance Scoring Protocol

## Метрики агентов

### Время отклика (Response Time)
| Метрика | Целевое значение | Штраф |
|---------|------------------|-------|
| Простая задача | < 30 сек | +10 сек = -1 балл |
| Средняя задача | < 2 мин | +1 мин = -1 балл |
| Сложная задача | < 5 мин | +2 мин = -1 балл |

### Качество (Quality Score)
| Метрика | Ценность | Штраф |
|---------|----------|-------|
| Задача выполнена с первого раза | +10 баллов | — |
| Задача выполнена после retry | +5 баллов | — |
| Задача выполнена после escalation | +2 балла | — |
| Задача не выполнена | 0 баллов | — |
| Баг найден code-reviewer | -5 баллов | — |
| Баг найден security-auditor | -10 баллов | — |

### Эффективность (Efficiency)
| Метрика | Формула |
|---------|---------|
| Токены на задачу | completed_tokens / task_count |
| Retry rate | retry_count / total_tasks |
| Success rate | success_count / total_tasks |

## Формула итогового балла

```
agent_score = (quality_score * 0.5) + (speed_score * 0.3) + (efficiency_score * 0.2)
```

Где:
- `quality_score` = sum(качественных баллов) / max_possible * 100
- `speed_score` = (target_time / actual_time) * 100 (макс 100)
- `efficiency_score` = (1 - retry_rate) * 100

## Логирование

### Формат записи
```json
{
  "timestamp": "2026-08-21T16:00:00Z",
  "agent": "dev-1",
  "task_id": "task-001",
  "duration_sec": 45,
  "quality_points": 10,
  "tokens_used": 1500,
  "retries": 0,
  "model": "mimo-v2.5-free"
}
```

### Файл лога
`.memory/traces/performance.jsonl` (JSON Lines, одна строка = одна запись)

## Рейтинг агентов

### Обновление рейтинга
- После каждой задачи: обновить score агента
- Каждый день: пересчитать рейтинг за последние 7 дней
- Рейтинг = среднее(score за 7 дней)

### Использование рейтинга
- team-lead при выборе агента: ưu tiên агенты с рейтингом > 80
- Если рейтинг < 50: автоматический code review + security audit
- Если рейтинг < 30: эскалировать пользователю

## Дашборд

### Формат вывода
```
=== Agent Performance Dashboard ===

Agent          | Score | Tasks | Avg Time | Retry% | Status
---------------|-------|-------|----------|--------|--------
dev-1          | 92    | 15    | 45s      | 5%     | ✅
backend        | 88    | 12    | 60s      | 8%     | ✅
frontend       | 85    | 8     | 90s      | 12%    | ⚠️
dev-2          | 78    | 10    | 120s     | 15%    | ⚠️
qa-engineer    | 95    | 6     | 30s      | 0%     | ✅

Top Performer: qa-engineer (95)
Needs Attention: dev-2 (78)
```
