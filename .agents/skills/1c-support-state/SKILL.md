---
name: 1c-support-state
description: "Чтение и переключение состояния поддержки типовой конфигурации 1С в XML-выгрузке. Применять для снятия/возврата объекта с поддержки и разрешения правки типовых объектов."
---

# 1C:Enterprise — Состояние поддержки конфигурации

## Описание

Чтение и переключение состояния поддержки типовой (вендорской) конфигурации 1С в XML-выгрузке: разрешить правку объекта, снять с поддержки, вернуть на замок, включить/выключить возможность изменения. Работает с файлом `Ext/ParentConfigurations.bin`.

## Когда использовать

- Нужно разрешить правку типового объекта (временное снятие с замка)
- Нужно снять объект с поддержки (полное снятие)
- Нужно вернуть объект на замок
- Нужно включить/выключить возможность изменения всей конфигурации
- Просмотр текущего состояния поддержки объекта

## Инструкции

### Команда

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path <путь> [режим]
```

### Режимы

| Команда | Описание |
|---------|----------|
| `/support-state <путь>` | Показать состояние (по умолчанию) |
| `/support-state <путь> -Set editable` | Разрешить правку (поддержка сохраняется) |
| `/support-state <путь> -Set off-support` | Снять с поддержки |
| `/support-state <путь> -Set locked` | Вернуть на замок |
| `/support-state <корень> -Capability on` | Включить возможность изменения |
| `/support-state <корень> -Capability off` | Выключить возможность изменения |

### Семантика состояний

| Состояние | Правило 1С | Правка | Обновления вендора |
|-----------|-----------|:------:|:------------------:|
| `locked` | На замке | ✗ | ✓ |
| `editable` | Редактируется | ✓ | ✓ |
| `off-support` | Снят с поддержки | ✓ | ✗ |

### Параметры скрипта

| Параметр | Обязательный | Описание |
|----------|:------------:|----------|
| `-Path <путь>` | да | XML объекта, каталог или корень выгрузки |
| `-Get` | нет | Показать состояние (по умолчанию) |
| `-Set <режим>` | нет | `editable` / `off-support` / `locked` |
| `-Capability <on/off>` | нет | Вкл/выкл возможность изменения |

## Примеры

```powershell
# Показать состояние справочника
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path "src/Catalogs/Номенклатура"

# Разрешить правку
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path "src/Catalogs/Номенклатура" -Set editable

# Снять с поддержки
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path "src/Catalogs/Номенклатура" -Set off-support

# Вернуть на замок
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path "src/Catalogs/Номенклатура" -Set locked

# Включить возможность изменения конфигурации
powershell.exe -NoProfile -File ".agents/skills/1c-support-state/scripts/support-state.ps1" -Path "src" -Capability on
```

## Лучшие практики

- **Изменения только в выгрузке** — чтобы подействовали в базе, загрузи выгрузку обратно
- **Под git** — изменение `.bin` видно в диффе и откатывается штатно
- **Минимум off-support** — снятие с поддержки делает невозможным обновление от вендора
- **Предпочитай `editable`** — это разрешает правку, но сохраняет поддержку

## Ссылки

- [claude-code-skills-1c (Desko77)](https://github.com/Desko77/claude-code-skills-1c) — исходный скилл 1c-support-state
