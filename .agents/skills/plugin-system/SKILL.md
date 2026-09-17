---
name: plugin-system
description: "Структура и формат плагинов opencode (.opencode/plugins, plugin.json). Применять при создании, установке и отладке плагинов."
---

# Plugin System

## Структура плагинов

```
.opencode/plugins/
├── example-plugin/
│   ├── plugin.json       # Метаданные плагина
│   └── index.js          # Код плагина
└── _disabled/            # Отключённые плагины
```

## Формат plugin.json

```json
{
  "name": "example-plugin",
  "version": "1.0.0",
  "description": "Пример плагина для agent-hq",
  "author": "agent-hq",
  "enabled": true,
  "hooks": {
    "before_task": "function beforeTask(task) { console.log('Before:', task.id); }",
    "after_task": "function afterTask(task, result) { console.log('After:', task.id, result.status); }",
    "on_error": "function onError(task, error) { console.log('Error:', error.message); }"
  },
  "permissions": ["read", "log"]
}
```

## Хуки плагинов

| Хук | Когда вызывается | Аргументы |
|-----|------------------|-----------|
| `before_task` | Перед началом задачи | `{ id, agent, description }` |
| `after_task` | После завершения задачи | `{ id, agent }, { status, duration, tokens }` |
| `on_error` | При ошибке | `{ id, agent }, { message, stack }` |
| `on_model_switch` | При переключении модели | `{ from, to, reason }` |
| `on_escalation` | При эскалации задачи | `{ id, from_agent, to_agent, reason }` |

## Встроенные плагины

### 1. logger
Логирует все действия агентов в `.memory/traces/`

### 2. cost-tracker
Отслеживает стоимость (для будущих платных моделей)

### 3. health-monitor
Мониторит здоровье агентов, автоматически перезапускает упавших

## Установка плагинов

```powershell
# Скопировать плагин в .opencode/plugins/
Copy-Item -Path "path/to/plugin" -Destination ".opencode/plugins/plugin-name" -Recurse

# Или через opencode
opencode plugin install <plugin-name>
```

## Отключение плагинов

Переместить в `._disabled/` или установить `"enabled": false` в plugin.json
