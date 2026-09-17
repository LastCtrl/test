---
name: 1c-config-index
description: "Однопроходный индекс XML-выгрузки конфигурации 1С в JSON: объекты, реквизиты, ТЧ, измерения, ресурсы, экспортные методы. Применять для проверки состава конфигурации и подготовки индекса для bsl-validate/query-validate."
---

# 1C:Enterprise — Индекс XML-выгрузки конфигурации

## Описание

Один проход по XML-выгрузке конфигурации 1С → один JSON. Индекс отвечает на вопрос «что вообще есть в этой конфигурации и из чего оно состоит»: объекты, реквизиты, ТЧ, измерения, ресурсы регистров, экспортные методы общих модулей. Работает без EDT, без платформы и без запущенной базы — только файлы выгрузки.

## Когда использовать

- Нужно проверить объект против остальной конфигурации
- Нужен список всех объектов/модулей/методов конфигурации
- Нужно подготовить индекс для других инструментов (bsl-validate, query-validate)
- Поиск экспортных методов общих модулей
- Проверка отсутствующих файлов в выгрузке

## Инструкции

### Команда

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-config-index/scripts/config-index.ps1" -ConfigPath "src" -OutFile "index.json"
```

```bash
python skills/1c-config-index/scripts/config-index.py -ConfigPath src -OutFile index.json
```

### Параметры

| Параметр | Обяз. | Описание |
|----------|:-----:|----------|
| `ConfigPath` | да | Каталог выгрузки (где `Configuration.xml`) |
| `OutFile` | нет | Куда записать индекс (без него — stdout) |
| `Detailed` | нет | Дописать имена ненайденных объектов и время сборки |

### Что попадает в индекс

| Ключ | Что там |
|------|---------|
| `format` | Версия схемы индекса |
| `kind` | `configuration` или `extension` |
| `name`, `version` | Имя и версия конфигурации |
| `declared` | Состав `Configuration.xml`: тип → список имен |
| `objects` | Ключ `Тип.Имя` → разбор объекта (реквизиты, ТЧ, модули) |
| `types` | Все `GeneratedType` конфигурации |
| `commonModules` | Общий модуль → список ЭКСПОРТНЫХ методов |
| `missing` | Объявлено в XML, но файла на диске нет |
| `unknownKinds` | Типы из ChildObjects, которых нет в карте типов |

### Использование другими инструментами

```bash
# 1. Собрать индекс
python skills/1c-config-index/scripts/config-index.py -ConfigPath src -OutFile .cache/index.json

# 2. Проверить BSL-вызовы
python skills/1c-bsl-validate/scripts/bsl-validate.py -ModulePath src -IndexPath .cache/index.json

# 3. Проверить запросы
python skills/1c-query-validate/scripts/query-validate.py -QueryPath запрос.txt -IndexPath .cache/index.json
```

## Примеры

```bash
# Базовый индекс
python config-index.py -ConfigPath src -OutFile index.json

# С детализацией
python config-index.py -ConfigPath src -OutFile index.json --Detailed
```

## Лучшие практики

- **Пересобирай индекс** после каждого изменения конфигурации
- **Кэшируй** индекс в `.cache/` — повторный проход дорогой
- **Используй для offline-проверок** — не нужна запущенная база

## Ссылки

- [claude-code-skills-1c (Desko77)](https://github.com/Desko77/claude-code-skills-1c) — исходный скилл 1c-config-index
