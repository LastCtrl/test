# 1C:Enterprise — Сборка внешней обработки (EPF/ERF)

## Описание

Сборка внешней обработки 1С (EPF) или внешнего отчёта (ERF) из XML-исходников через пакетный запуск платформы. Работает без EDT — напрямую из исходников в файл.

## Когда использовать

- Собрать EPF/ERF из XML-исходников
- Автоматизировать сборку обработок в CI/CD
- Собрать обработку без открытия EDT или Конфигуратора
- Проверить, что обработка собирается без ошибок

## Инструкции

### Команда

```powershell
powershell.exe -NoProfile -File ".agents/skills/1c-epf-build/scripts/epf-build.ps1" -ProcessorName "МояОбработка" -SrcDir "src" -OutDir "build"
```

### Параметры

| Параметр | Обязательный | По умолчанию | Описание |
|----------|:------------:|--------------|----------|
| `ProcessorName` | да | — | Имя обработки (имя корневого XML) |
| `SrcDir` | нет | `src` | Каталог исходников |
| `OutDir` | нет | `build` | Каталог для результата |
| `V8Path` | нет | авто | Каталог bin платформы |

### Параметры подключения

Предпочтительно использовать конкретную базу:

1. Прочитай `.v8-project.json` из корня проекта — возьми `v8path` и разреши базу
2. Если пользователь указал параметры подключения — используй напрямую
3. Если указал базу по имени — ищи по id/alias/name в `.v8-project.json`
4. Если не указал — сопоставь текущую ветку Git с `databases[].branches`
5. Если ветка не совпала — используй `default`

**Автоопределение платформы:**

```powershell
Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" | Sort-Object -Descending | Select-Object -First 1
```

### Структура проекта

```
src/
├── MyProcessor/
│   ├── MyProcessor.xml       # Корневой XML
│   ├── ObjectModule.bsl      # Модуль объекта
│   ├── Form/
│   │   └── Форма/
│   │       ├── Form.xml
│   │       └── Module.bsl
│   └── Template/
│       └── ПечатнаяФорма/
│           └── MXL.xml
```

## Примеры

```powershell
# Базовая сборка
powershell.exe -NoProfile -File ".agents/skills/1c-epf-build/scripts/epf-build.ps1" -ProcessorName "МояОбработка"

# С указанием базы
powershell.exe -NoProfile -File ".agents/skills/1c-epf-build/scripts/epf-build.ps1" -ProcessorName "МояОбработка" -InfoBasePath "C:\Bases\MyDB"

# С указанием платформы
powershell.exe -NoProfile -File ".agents/skills/1c-epf-build/scripts/epf-build.ps1" -ProcessorName "МояОбработка" -V8Path "C:\Program Files\1cv8\8.3.24.1234\bin"
```

## Лучшие практики

- **Используй `.v8-project.json`** для хранения путей к платформе и базам
- **Временная база** — если `.v8-project.json` нет, скрипт создаст временную (удаляется после сборки)
- **EPF со ссылочными типами** — требуют реальную базу (CatalogRef, DocumentRef и т.д.)
- **CI/CD** — используй для автоматической сборки в пайплайнах

## Ссылки

- [cc-1c-skills (Nikolay-Shirokov)](https://github.com/Nikolay-Shirokov/cc-1c-skills) — исходный скилл epf-build
- [claude-code-skills-1c (Desko77)](https://github.com/Desko77/claude-code-skills-1c) — исходный скилл 1c-epf-build
