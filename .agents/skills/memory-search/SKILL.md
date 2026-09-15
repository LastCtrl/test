---
name: memory-search
description: "Keyword-grep поиск по каталогу .memory/ (activeContext, decisionLog, progress). Применять для поиска ранее принятых решений, текущего прогресса и контекста проекта."
---

# Memory Search Skill

## Keyword grep по .memory/

### Поиск по файлам

1. **activeContext.md** — основной файл поиска
   - `grep -i "выполнено" .memory/activeContext.md`
   - `grep -i "заблокировано" .memory/activeContext.md`
   - `grep -i "ADR" .memory/decisionLog.md`

2. **decisionLog.md** — поиск архитектурных решений
   - `grep -i "решение" .memory/decisionLog.md`
   - `grep -i "ADR-" .memory/decisionLog.md`

3. **progress.md** — поиск текущего прогресса
   - `grep -i "в работе" .memory/progress.md`
   - `grep -i "заблокировано" .memory/progress.md`

4. **productContext.md** — поиск общей информации о проекте
   - `grep -i "цель" .memory/productContext.md`
   - `grep -i "стек" .memory/productContext.md`

### Поиск по ключевым словам (упрощенный алгоритм)

```
INPUT: query от агента
1. Разбить query на отдельные слова
2. Пройти по 5 файлам памяти по очереди
3. Для каждого вхождения записать:
   - Имя файла
   - Строку с вхождением
   - Контекст: 2 предложения до и после
4. Удалить дубликаты
5. Отсортировать: сначала activeContext.md, потом decisionLog.md, и т.д.
6. Вернуть список из максимум 5 наиболее релевантных результатов
```

### Примеры использования

- Агент: "какие были Decision Records о бэкапе?"
  → `memory-search` находит в `decisionLog.md` строки про бэкап

- Агент: "кто заблокировал пользователя Ivanov?"
  → `memory-search` находит в `activeContext.md` и `progress.md`

- Агент: "какой стек использовали в news-bot?"
  → `memory-search` находит в `productContext.md`