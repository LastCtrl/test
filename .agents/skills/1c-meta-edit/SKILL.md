# 1C:Enterprise — Точечное редактирование метаданных

## Описание

Атомарные операции модификации XML объектов метаданных 1С. Добавление/удаление/изменение реквизитов, табличных частей, измерений, ресурсов, свойств объекта, форм, макетов, команд. Работает с XML-выгрузкой конфигурации без платформы и EDT.

## Когда использовать

- Добавить/удалить реквизит справочника, документа, регистра
- Добавить/удалить табличную часть с реквизитами
- Добавить/удалить измерения/ресурсы регистра
- Добавить/удалить формы, макеты, команды
- Переименовать реквизит или изменить его тип
- Изменить свойства объекта (длина кода, длина наименования)
- Добавить владельца справочника
- Позиционная вставка реквизита (после конкретного)

## Инструкции

### Команда (inline mode — простые операции)

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-meta-edit/scripts/meta-edit.ps1" -ObjectPath "<путь>" -Operation <операция> -Value "<значение>"
```

### Команда (JSON mode — сложные/комбинированные)

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-meta-edit/scripts/meta-edit.ps1" -DefinitionFile "<json>" -ObjectPath "<путь>"
```

| Параметр | Описание |
|----------|----------|
| `ObjectPath` | XML-файл или директория объекта (обязательный, авторезолв `<dirName>.xml`) |
| `Operation` | Inline-операция (альтернатива DefinitionFile) |
| `Value` | Значение для inline-операции |
| `DefinitionFile` | JSON-файл с операциями (альтернатива Operation) |
| `NoValidate` | Не запускать meta-validate после правки |

### Операции — Дочерние элементы

Batch через `;;` во всех операциях.

| Операция | Формат Value | Пример |
|----------|-------------|--------|
| `add-attribute` | `Имя: Тип \| флаги` | `"Сумма: Число(15,2) \| req, index"` |
| `add-ts` | `ТЧ: Рекв1: Тип1, Рекв2: Тип2` | `"Товары: Ном: CatalogRef.Ном, Кол: Число(15,3)"` |
| `add-dimension` | `Имя: Тип \| флаги` | `"Организация: CatalogRef.Организации \| master"` |
| `add-resource` | `Имя: Тип` | `"Сумма: Число(15,2)"` |
| `add-enumValue` | `Имя` | `"Значение1 ;; Значение2"` |
| `add-column` | `Имя: Тип` | `"Тип: EnumRef.ТипыДокументов"` |
| `add-form` / `add-template` / `add-command` | `Имя` | `"ФормаЭлемента"` |
| `add-ts-attribute` | `ТЧ.Имя: Тип` | `"Товары.Скидка: Число(15,2)"` |
| `remove-*` | `Имя` | `"СтарыйРеквизит ;; ЕщёОдин"` |
| `remove-ts-attribute` | `ТЧ.Имя` | `"Товары.УстаревшийРекв"` |
| `modify-attribute` | `Имя: ключ=значение` | `"СтароеИмя: name=НовоеИмя, type=Строка(500)"` |
| `modify-ts-attribute` | `ТЧ.Имя: ключ=значение` | `"Товары.Рекв: name=НовоеИмя"` |
| `modify-ts` | `ТЧ: ключ=значение` | `"Товары: synonym=Товарный состав"` |

**Позиционная вставка:** `"Склад: CatalogRef.Склады >> after Организация"`

**Составной тип:** `"Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"`

### Операции — Свойства объекта

| Операция | Формат Value | Пример |
|----------|-------------|--------|
| `modify-property` | `Ключ=Значение` | `"CodeLength=11 ;; DescriptionLength=150"` |
| `add-owner` | `MetaType.Name` | `"Catalog.Контрагенты ;; Catalog.Организации"` |
| `add-registerRecord` | `MetaType.Name` | `"AccumulationRegister.ОстаткиТоваров"` |
| `add-basedOn` | `MetaType.Name` | `"Document.ЗаказКлиента"` |
| `add-inputByString` | `Путь поля` | `"StandardAttribute.Description"` |
| `set-owners` / `set-registerRecords` / `set-basedOn` / `set-inputByString` | Замена всего списка | `"Catalog.Орг ;; Catalog.Контр"` |
| `remove-owner` / `remove-registerRecord` / ... | Удаление из списка | `"Catalog.Контрагенты"` |

### modify-attribute — структурные свойства реквизита

Помимо `name` и `type`, `modify-attribute` поддерживает: `Format`, `ChoiceForm`, `ChoiceParameters`, `FillValue`, `MinValue`, `MaxValue` и др.

## Примеры

```powershell
# Добавить реквизиты
-Operation add-attribute -Value "Комментарий: Строка(200) ;; Сумма: Число(15,2) | index"

# Составной тип (несколько типов через +)
-Operation add-attribute -Value "Значение: Строка + Число(15,2) + Дата + CatalogRef.Контрагенты"

# Добавить ТЧ с реквизитами
-Operation add-ts -Value "Товары: Ном: CatalogRef.Ном | req, Кол: Число(15,3), Цена: Число(15,2)"

# Удалить реквизит
-Operation remove-attribute -Value "УстаревшийРеквизит"

# Переименовать + сменить тип
-Operation modify-attribute -Value "СтароеИмя: name=НовоеИмя, type=Строка(500)"

# Изменить свойства объекта
-Operation modify-property -Value "CodeLength=11 ;; DescriptionLength=150"

# Владельцы справочника
-Operation set-owners -Value "Catalog.Контрагенты ;; Catalog.Организации"

# Добавить форму
-Operation add-form -Value "ФормаСписка"
```

## Верификация

После редактирования всегда запускай:

```
/meta-validate <ObjectPath>    — валидация после редактирования
/meta-info <ObjectPath>        — визуальная сводка
```

## Лучшие практики

- Всегда проверяй валидацию после правок
- Используй JSON mode для комбинированных операций (add + remove + modify в одном вызове)
- Позиционная вставка (`>> after`) удобна для保持 порядка реквизитов
- Batch через `;;` позволяет делать несколько однотипных операций за раз
- Составной тип через `+` объединяет несколько возможных ссылочных типов

## Ссылки

- [cc-1c-skills (Nikolay-Shirokov)](https://github.com/Nikolay-Shirokov/cc-1c-skills) — исходный скилл meta-edit
- [Документация платформы 1С 8.3](https://its.1c.ru/db/metod8dev)
