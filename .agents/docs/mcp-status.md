# MCP status — диагностика и решения (2026-09-25)

Источник: `opencode.json` → `mcp`, логи `~/.local/share/opencode/log/opencode.log`, живые пробы.

## Итог одной строкой
Сетевые Node-MCP (`context7`, `hermes-atlas-mcp`) **падали из-за глобального proxy-env** `NODE_USE_ENV_PROXY=1` + `HTTP_PROXY=http://127.0.0.1:3128` (proxy URL указывается **со схемой** `http://`; строка без схемы парсится undici некорректно): в зависимости от версии Node ошибка выглядит как `Request was cancelled` **или** `TypeError: fetch failed`; без proxy-env — `OK 200`. 1С-MCP вообще не установлены. `sequential-thinking` (локальный stdio) — единственный, кто всегда работал.

## Статус серверов

| Сервер | Что это | Статус до | Причина | Решение |
|--------|---------|-----------|---------|---------|
| `context7` | `@upstash/context7-mcp` v4.0.6 — актуальная документация библиотек | `fetch failed` | proxy-env ломает undici | per-MCP env: очистка proxy (direct egress работает) |
| `hermes-atlas-mcp` | `hermes-atlas-mcp` v0.2.0 (experimental) — каталог экосистемы **Hermes Agent (Nous Research)**, тянет live с `hermesatlas.com` | `fetch failed` | тот же proxy-env | тот же env-override (но ценность для нас низкая, см. ниже) |
| `sequential-thinking` | локальный stdio, без сети | работал | — | оставлен; НЕ использовать «для галочки» |
| `serena` | LSP-подобный агент (`uvx` из `git+`) | `enabled:false` | не нужен | **удалён из конфига** |
| `bsl-platform-help` (skill `1c-platform-docs`) | MCP-справка API платформы 1С | 0 вызовов | **не установлен/не зарегистрирован**, нет в npm (E404) | офлайн-скиллы вместо него |
| `1c-naparnik` (skill `1c-naparnik`) | MCP code review по стандартам ИТС | 0 вызовов | **не установлен**, нет в npm | офлайн-скиллы вместо него |

## context7 — корень и фикс
**Симптом:** `resolve-library-id`/`query-docs` → `TypeError: fetch failed`, в self-report'ах «context7: offline».
**Проба:** curl к `context7.com` и `context7.com/api/v1/search` — `200` и напрямую, и через cntlm.
**Решающий тест (Node):**
```
с env (NODE_USE_ENV_PROXY=1, HTTP_PROXY=http://127.0.0.1:3128)  -> ERR Request was cancelled (или ERR fetch failed на другой версии Node)
без proxy-env                                                   -> OK 200
```
**Вывод:** глобальный proxy-env (HKCU) ломает undici. **Фикс:** очистка proxy для MCP — либо `environment` в `opencode.json`, либо обёртка `.agents/scripts/mcp-<name>.cmd` (реализованы оба; `mcp-health.ps1` считает сервер защищённым при наличии хотя бы одного). **Требуется рестарт opencode** (конфиг читается при старте).

## hermes-atlas-mcp — максимально подробно
- **Что это:** MCP-сервер (v0.2.0, статус «experimental, 0.x»), предоставляющий **каталог экосистемы Hermes Atlas** — 100+ community-инструментов/скиллов/плагинов/memory-провайдеров/workspace'ов для **Hermes Agent** (проект **Nous Research**, `github.com/NousResearch/hermes-agent` — это отдельный агентский фреймворк, НЕ opencode).
- **Как работает:** данные тянет **вживую с `hermesatlas.com`** (кеш в памяти 1 час), поэтому ответы отражают текущую экосистему.
- **Инструменты:** `search_projects`, `get_project`, `list_by_category`, `ask_atlas`, `get_guide` (slug: hub/install/vs-claude-code).
- **Зачем в нашей системе** (AGENTS.md §3.6): «нужен новый скилл/тул, которого нет в `.agents/skills/`» — как источник идей/готовых решений.
- **Почему почти не использовался (10 вызовов):** (1) тот же proxy-баг → `fetch failed`; (2) **слабая релевантность** — каталог про Hermes Agent (Nous), а мы на opencode; для задач 1С/нашей шины он бесполезен.
- **Решение:** технически починен тем же env-override; в §3.6 больше не обязателен — использовать только если реально ищем что-то в экосистеме Hermes.
- **Хост:** `hermesatlas.com` резолвится (216.150.16.1) и отвечает `200` и напрямую, и через cntlm.

## 1С-MCP — почему не установлены и нужны ли
- **Почему 0 вызовов:** `bsl-platform-help` и `1c-naparnik` **не зарегистрированы** ни в `opencode.json → mcp`, ни в глобальном конфиге; **нет `.cmd`-обёрток**; **нет в публичном npm** (`E404`). Они существуют только как **описания в скиллах** (`1c-platform-docs`, `1c-naparnik`) и в `capability-passport.json`/`registry.json`. Вызвать физически нечего.
- **Нужны ли:** базовую задачу (проверка имён модулей/методов BSL, полей/таблиц запросов, состава конфигурации, справка БСП) **уже закрывают офлайн-скиллы**, работающие по XML-выгрузке без сети:
  - `1c-config-index` — однопроходный индекс конфигурации (объекты/реквизиты/ТЧ/методы);
  - `1c-query-validate` / `1c-bsl-validate` — проверка имён без выполнения;
  - `1c-bsp-api` — офлайн-справочник БСП; `1c-query`, `1c-dev`, `1c-meta-edit`, `1c-support-state`, `1c-storage-ops`, `1c-epf-build`, `1c-edt-configurator`, `1c-form-patterns`, `1c-vanessa-steps`, `1c-query-optimization`.
- **Вывод:** офлайн-скиллы = основной механизм; MCP-варианты — **опциональны/не развёрнуты**. Подключать только если появится доступ к серверу (напр. `code.1c.ai`) и он даст то, чего нет офлайн.

## Почему «умная система» не поймала это сама
`health-check.ps1` проверяет конфиг агентов, compliance и инфраструктуру, но **не проверяет доступность backend'ов MCP**. Сбои MCP фиксировались только как пометки «context7: offline» в self-report'ах и никогда не всплывали как алерт. Устранение: добавлен `mcp-health.ps1` (проба обёрток + backend-доступности) с интеграцией в `health-check`.

## Что сделать после рестарта opencode
1. Перезапустить opencode (конфиг `mcp` читается при старте).
2. Проверить: вызовы `context7_resolve-library-id` / `query-docs` и `hermes-atlas-mcp_search_projects` должны отвечать без `fetch failed`.
3. Если какой-то хост окажется доступен **только** через cntlm — для него вернуть proxy-env в его записи `mcp` (точечно), НЕ глобально (и предпочесть прямой egress, т.к. undici+cntlm ломается).
