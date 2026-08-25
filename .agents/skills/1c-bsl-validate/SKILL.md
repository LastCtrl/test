# 1C:Enterprise — Проверка вызовов общих модулей BSL

## Описание

Проверка вызовов общих модулей в BSL по выгрузке конфигурации: существует ли модуль и экспортный ли у него метод. Работает без EDT, без платформы и без базы — по индексу от 1c-config-index. Ловит ошибки «переименовали метод, а вызовы в других модулях не обновили» до запуска.

## Когда использовать

- Переименовали метод или сняли `Экспорт` — нужно найти все вызовы
- Проверка BSL-кода перед коммитом
- Поиск несуществующих вызовов общих модулей
- Миграция между версиями БСП (старые имена методов)

## Инструкции

### Команда

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-bsl-validate/scripts/bsl-validate.ps1" -ModulePath "src" -IndexPath ".cache/index.json"
```

```bash
python skills/1c-bsl-validate/scripts/bsl-validate.py -ModulePath src -IndexPath .cache/index.json
```

### Параметры

| Параметр | Обяз. | Описание |
|----------|:-----:|----------|
| `ModulePath` | да | Файл `.bsl` или каталог (рекурсивный обход) |
| `IndexPath` | да | Индекс от `1c-config-index` |
| `UnknownCalls` | нет | Дополнительно искать вызовы неизвестных имен |
| `Detailed` | нет | Показать счётчики даже когда есть замечания |
| `MaxErrors` | нет | Не выводить больше N замечаний (по умолчанию 30) |

### Workflow

```bash
# 1. Собрать индекс
python skills/1c-config-index/scripts/config-index.py -ConfigPath src -OutFile .cache/index.json

# 2. Проверить BSL-вызовы
python skills/1c-bsl-validate/scripts/bsl-validate.py -ModulePath src -IndexPath .cache/index.json
```

### Что проверяется

**Основная проверка:** вызов вида `ОбщиеФункции.Метод()` — проверяется что:
1. `ОбщиеФункции` есть в индексе среди общих модулей
2. `Метод` есть в списке экспортных методов этого модуля

**Дополнительная проверка** (`--UnknownCalls`): ищет вызовы неизвестных имён (только общие модули).

### Формат вывода

```
✓ src/CommonModules/ОбщегоНазначения/Module.bsl — ошибок нет
✗ src/Documents/Заказ/ObjectModule.bsl:
  строка 42: ОбщегоНазначения.НесуществующийМетод() — метод не найден
  строка 67: Справочники.УстаревшийМодуль.Действие() — модуль не найден
```

## Примеры

```bash
# Проверить конкретный файл
python bsl-validate.py -ModulePath src/Documents/Заказ/ObjectModule.bsl -IndexPath .cache/index.json

# Проверить всё
python bsl-validate.py -ModulePath src -IndexPath .cache/index.json

# С доп. проверкой неизвестных имен
python bsl-validate.py -ModulePath src -IndexPath .cache/index.json --UnknownCalls
```

## Лучшие практики

- **Перед коммитом** — всегда проверяй BSL-вызовы
- **Индекс актуальный** — пересобирай после каждого изменения конфигурации
- **Не доверяй Intellisense** — он может показать метод, которого нет в этой версии БСП

## Ссылки

- [claude-code-skills-1c (Desko77)](https://github.com/Desko77/claude-code-skills-1c) — исходный скилл 1c-bsl-validate
