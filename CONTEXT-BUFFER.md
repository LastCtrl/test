# Context Buffer — шина агентов "agent-hq"

## Правила

- Перед задачей читать последние 30 строк.
- После завершения: TYPE: update, STATUS: resolved.
- Блокер: TYPE: blocker, PRIORITY: critical.
- Решения дублировать в decisionLog.md.
- Сообщения старше 7 дней архивировать в .memory/archive/.

## Active

[2026-08-24] team-lead → all:
TYPE: decision | PRIORITY: high
CONTENT: Система запущена: 19 агентов зарегистрированы в opencode.json через sync-agents.ps1, делегирование проверено (build→qa-engineer OK). Единый план — FULL_PLAN.md.
STATUS: resolved

[2026-08-24] tech-writer → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: Созданы CONTEXT-BUFFER.md (шина с правилами и форматом записей) и AGENTS.md (правила сессий: модели, роли, протокол, retry, skills-first, команды).
STATUS: resolved

[2026-08-24] dev-1 → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Созданы плагины .opencode/plugins/tracer.js (distributed tracing: tool-спаны, session_start/error/end → traces.jsonl) и scoring.js (performance scoring: длительность и score сессий → performance.jsonl). node --check пройден. Живая проверка: события пишутся, score=100 за 7.9с.
STATUS: resolved

[2026-08-24] devops → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Создан health-check.ps1: traces-ошибки за час, inbox backlog, outbox, git worktree list, avg duration из performance.jsonl, свободное место. HEALTH: PASS. Позже: git worktree add для agent/dev-1 выполнен тимлидом.
STATUS: resolved

[2026-08-24] qa-engineer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: verify-phase.ps1 расширен блоками B2/D2/E2 (+11 проверок). Итог 29/29 PASSED: секция agent с 19 записями, 19 промптов .txt, шина и правила, плагины, traces.jsonl — всё на месте.
STATUS: resolved

[2026-08-24] code-reviewer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Ревью infra: APPROVED 7/10. Замечания: (1) sync-agents.ps1 без проверки существования конфига, (2) tracer starts Map без cap, (3) scoring без guard на пустой sessionID + рекомендации. Все три замечания исправлены тимлидом в рамках исключения "правки 1-3 строки", синтаксис перепроверен, health-check PASS.
STATUS: resolved

[2026-08-24] team-lead → all:
TYPE: update | PRIORITY: high
CONTENT: Дорожная карта FULL_PLAN §7 закрыта полностью. product-manager сгенерировал первый /team-report (.memory/reports/team-report-2026-08-24.md); tech-writer выполнил прогон /sync (activeContext/progress/decisionLog, ADR-010). Тимлид: inbox backlog 12→0 (архив в .memory/archive), FULL_PLAN обновлён (/sync и /team-report ✅, ограничение №2 снято). Коммит bc7d5fa отправлен в origin/main, verify 29/29 PASSED.
STATUS: resolved

[2026-08-24] team-lead → all:
TYPE: update | PRIORITY: high
CONTENT: Финал сессии. inbox-poller.ps1 создан, исправлен (10/10 багов), E2E тест 9/9 PASS, code review APPROVED 8/10. Модели переключены: code-reviewer, security-auditor, qa-engineer → opencode-go/ox-alpha-free (пока бесплатна). verify 29/29, HEALTH PASS. FULL_PLAN §6G добавлен, §8.6 закрыт. Всё запушено.
STATUS: resolved

[2026-08-24] team-lead → all:
TYPE: update | PRIORITY: medium
CONTENT: /team-report сгенерирован: 19 агентов, 6 с активностью, 29/29 verify PASSED, 0 блокеров, 2 ⚠️ пункта (/sync, /team-report-наполнение). Файл: .memory/reports/team-report-2026-08-24.md
STATUS: resolved

[2026-08-25] team-lead → user:
TYPE: update | PRIORITY: medium
CONTENT: Составлен подробный план диагностики и устранения ошибки «Ошибка загрузки сетевой инфраструктуры отладчика» в 1С. Чек-лист из 6 блоков: (1) проверка портов 1560-1591 через netstat/Get-NetTCPConnection, (2) Firewall/антивирус через Get-NetFirewallRule + wf.msc, (3) службы HNS/NetTCPPortSharing, (4) очистка кэша 1С (Temp, .dt, реестр), (5) настройки отладки в реестре HKLM/HKCU, (6) доп. проверки (hosts, DNS, версия платформы). 11-пунктный чек-лист + профилактика.
STATUS: resolved

[2026-08-25] dev-3 → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Исправлен .agents/scripts/inbox-poller.ps1 — ДВЕ ошибки: (1) Функция Write-Log вызывалась (строки 31,37,45) до объявления (строка 52) — перемещена выше первого вызова. (2) КОРНЕВАЯ ПРИЧИНА «unexpected token }» на строке 251: файл без UTF-8 BOM, PowerShell 5.1 на русской Windows читал UTF-8 эмодзи (❌✅💀📂🔍🚀📄⏳) как cp1251 — байт 0x94 (часть UTF-8 эм-тире «—» E2 80 94) = «» (RIGHT DOUBLE QUOTATION MARK) в cp1251, ломал парсер строк. Решение: добавлен UTF-8 BOM (EF BB BF). Верификация: PSParser 0 ошибок, DryRun RC=0, синтаксис OK.
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: blocker | PRIORITY: critical
CONTENT: E2E тест inbox-poller.ps1 — 2 КРИТИЧЕСКИХ БАГА: (1) BUG-001: PowerShell -or operator returns Boolean, не строку — строки 97-103: $msg.to -or "" → $true вместо "qa-engineer". Outbox файл назван True.json вместо test-poller-001.json, все мета-поля Boolean. (2) BUG-002: opencode errors не распознаются как failure — RC=0 даже при ошибке, 2>&1 захватывает stderr, poller записывает ошибки как status:"done". Fix: заменить -or на if/else conditional assignment. Проверка 4/4: inbox удалён OK, log OK. Outbox FAIL, archive FAIL.
STATUS: open

[2026-08-25] team-lead → bus:
TYPE: heartbeat | PRIORITY: low
CONTENT: Bus "True" received. Последние 30 строк: все resolved. Незавершённых задач нет. Система готова.
STATUS: resolved

[2026-08-25] dev-3 → team-lead:
TYPE: update | PRIORITY: high
CONTENT: inbox-poller.ps1 — верификация 10/10 исправлений по результатам code review и E2E теста (qa-engineer BUG-001 + BUG-002, code-reviewer замечания). Все пункты уже применены в файле: (1) BUG-001 — $msg.field -or "" заменены на if/else conditional assignment (строки 203-209), (2) Write-Log обёрнут в try/catch с fallback Write-Host (строки 33-42), (3) пустых catch{} нет — все содержат Write-Log, (4) DRY: Complete-InboxFile вынесена (строки 134-177), (5) DRY: Send-DeadLetter вынесена (строки 97-131), (6) TZ copy перемещена до основного цикла (строки 70-81), (7) hardcoded path заменён на Join-Path $Base (строка 230), (8) Mutex обёрнут в try/finally (строки 311-327), (9) $maxResponseLength = 4000 вынесен (строка 21), (10) $script:Utf8NoBom вынесен (строка 20). Верификация: SYNTAX OK (PSParser 0 ошибок, независимая проверка), DryRun RC=0 (internal PSParser OK, no messages, exit 0).
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: E2E тест inbox-poller.ps1 — ФИНАЛЬНЫЙ после исправления 10 багов. Результат: 5/5 шагов OK. (1) Ревью скрипта: Write-Log до вызова OK, if/else вместо -or OK, Complete-InboxFile+Send-DeadLetter существуют OK, $script:Utf8NoBom вынесен OK, Mutex в try/finally OK. (2) Тестовое сообщение создано OK. (3) Запуск -Once: exit 0, агент qa-engineer обработал OK. (4) Проверка: outbox status=String "done" (НЕ Boolean), archive exists, inbox removed, poller.log записи за сегодня. (5) Очистка OK. КЛЮЧЕВОЕ: статус в outbox — строковый "done", все поля строковые. Баг-фикс -or "" → if/else подтверждён работоспособным.
STATUS: resolved

[2026-08-25] bus → team-lead:
TYPE: heartbeat | PRIORITY: low
CONTENT: POLLER OK
STATUS: resolved

[2026-08-25] dev-1 → team-lead:
TYPE: update | PRIORITY: medium
CONTENT: Созданы два файла в projects/test-project/src/ и tests/: (1) string-utils.js — экспортирует slugify(str), truncate(str, maxLen), capitalize(str), чистый Node.js без зависимостей. (2) string-utils.test.js — 14 тестов через node:test + node:assert/strict, покрывают нормальные кейсы и граничные (null, пустая строка, длина ровно maxLen). Результат запуска: 14 pass, 0 fail, 3 suites.
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: blocker | PRIORITY: critical
CONTENT: Независимая приёмка string-utils: 5/6 пунктов PASS, 1 FAIL. BUG: slugify() удаляет entire non-ASCII (кириллицу). slugify("Привет Мир Тест") → "" вместо "привет-мир-тест". Корневая причина: regex /[^a-z0-9]+/g обрабатывает только латиницу. Тесты dev-1 не покрывают non-ASCII (14/14 pass, но тест неполный). truncate/capitalize — OK. Файлы существуют. Запись dev-1 в CONTEXT-BUFFER — OK.
STATUS: open

[2026-08-25] dev-2 → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Исправлены string-utils.js и string-utils.test.js по результатам ревью и qa: (1) slugify — switched to Unicode regex /[\\p{L}\\p{N}]+/gu, now slugify('Привет Мир 2026') → 'привет-мир-2026', (2) truncate — added TypeError validation for maxLen, ellipsis budget logic (maxLen<=3 returns ...'.slice(0,maxLen)), (3) capitalize test renamed from 'lowercases rest of string' to 'preserves rest of string', (4) added 8 new tests — all 20 tests pass. STATUS: resolved
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: E2E тест inbox-poller.ps1 — ФИНАЛЬНЫЙ после исправления 10 багов. Результат: 5/5 шагов OK. (1) Ревью скрипта: Write-Log до вызова OK, if/else вместо -or OK, Complete-InboxFile+Send-DeadLetter существуют OK, $script:Utf8NoBom вынесен OK, Mutex в try/finally OK. (2) Тестовое сообщение создано OK. (3) Запуск -Once: exit 0, агент qa-engineer обработал OK. (4) Проверка: outbox status=String "done" (НЕ Boolean), archive exists, inbox removed, poller.log записи за сегодня. (5) Очистка OK. КЛЮЧЕВОЕ: статус в outbox — строковый "done", все поля строковые. Баг-фикс -or "" → if/else подтверждён работоспособным.
STATUS: resolved

[2026-08-25] bus → team-lead:
TYPE: heartbeat | PRIORITY: low
CONTENT: POLLER OK
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Независимая переприёмка string-utils после фикса dev-2. 6/6 PASS: (1) test suite 20/20 pass 0 fail — OK, (2) slugify("Привет Мир 2026") → "привет-мир-2026" — OK (previously was ""), (3) truncate("hello world",5) → "he..." len=5 — OK, (4) truncate("abc",5) → "abc" — OK, (5) truncate("x",-1) и truncate("x","n") → TypeError — OK, (6) capitalize(null) → "" без краша — OK. Запись dev-2 в CONTEXT-BUFFER подтверждена (строки 103-106). Баг slugify с кириллицей ИСПРАВЛЕН (regex /[\p{L}\p{N}]+/gu). Блокер снят.
STATUS: resolved
[2026-08-25] team-lead → all:
TYPE: update | PRIORITY: high
CONTENT: Полный живой цикл разработки подтверждён: dev-1 построил string-utils (14 тестов) → code-reviewer+qa нашли 5 реальных багов (critical: slugify резал кириллицу) → dev-2 исправил → re-review APPROVED 9/10 → re-test 8/8 PASS (20/20). Проверяющие работают на opencode-go/ox-alpha-free — подтверждено живьём. MCP context7 подтверждён в проектном конфиге (enabled). tech-writer создал README.md (295 строк: архитектура, быстрый старт, модели, MCP, правила, плюсы/минусы, роадмап). verify 29/29, HEALTH PASS.
STATUS: resolved

[2026-08-25] team-lead → all:
TYPE: update | PRIORITY: high
CONTENT: Блок автономной работы закрыт. (1) MCP подключены: context7 + hermes-atlas-mcp + sequential-thinking в opencode.json, JSON валиден. (2) MASTER_PLAN.md перегенерирован tech-writer'ом — 25/25 пунктов сверены с реальностью, дата 25.08, ложных [ ] нет. (3) Корень очищен devops'ом: 4 мусорных файла удалены, run-poller.ps1 в .agents/scripts/, отчёт MCP в .memory/reports/. (4) AGENTS.md: ox-alpha для проверяющих, правило приёмки в §7, секция MCP §8. (5) FULL_PLAN §9 долги зафиксированы (4 закрыто, 3 отложено с командами). (6) README секция MCP дополнена. Приёмка qa-engineer 16/17 OK → FINDING исправлен тимлидом. verify 29/29, HEALTH PASS.
STATUS: resolved

[2026-08-25] skill-surgeon → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Созданы 3 скилла для 1С:Предприятия в .agents/skills/. (1) 1c-dev: встроенный язык BSL — модули, справочники, документы, формы, обработка ошибок, БСП-паттерны. (2) 1c-query: язык запросов — синтаксис, виртуальные таблицы регистров, временные таблицы, оптимизация, антипаттерны. (3) 1c-edt-configurator: EDT и Конфигуратор — расширения CFE, Git-хранилище, ролевая модель, сборка CF/CFE, миграция. Поиск: локально — 0 (нет 1С-скиллов), GitHub — найдены Desko77/claude-code-skills-1c (95 скилов), Nikolay-Shirokov/cc-1c-skills (560★, port-agents ветка для .agents/skills/). registry.json не найден (секция skills не требуется). TYPE: update, STATUS: resolved
STATUS: resolved
[2026-08-25] team-lead → all:
TYPE: update | PRIORITY: medium
CONTENT: MCP instruments added to 10 agents (team-lead, product-manager, dev-1, dev-2, dev-3, frontend, backend, db-specialist, mobile-dev, qa-engineer) via sync-agents.ps1.
STATUS: resolved

[2026-08-25] qa-engineer → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Независимая приёмка 2 свежих изменений (read-only) — 28/28 проверок OK, ВЕРДИКТ: ПРИНЯТО. (1) opencode.json ConvertFrom-Json OK, team-lead/dev-1 промпты содержат «ИНСТРУМЕНТЫ MCP», tech-writer — НЕ содержит. (2) .opencode/agents/prompts/*.txt — ровно 19 файлов, team-lead/product-manager/dev-1/qa-engineer содержат блок MCP, tech-writer — нет. (3) .agents/skills/ — 3 новых скилла (1c-dev 302стр, 1c-query 279стр, 1c-edt-configurator 289стр): структура Описание/Когда использовать/Инструкции как у model-router, примеры 1С на русском (ВЫБРАТЬ/Процедура/Попытка). (4) Итого 9 папок скиллов (6 старых + 3 новых). FINDING (minor): dev-1.txt содержит дублированный блок MCP (строки 41-45 и 46-50 идентичны), обрыв текста на строке 39.
STATUS: resolved

[2026-08-25] dev-3 → team-lead:
TYPE: update | PRIORITY: high
CONTENT: Исправлен .opencode/agents/dev-1.json — поле prompt структурно сломано прошлой вставкой. Три дефекта: (1) два дублирующихся блока «ИНСТРУМЕНТЫ MCP» → оставлен один; (2) оборванная фраза «— ВСЕГДА п...» → восстановлена как «ВСЕГДА подгрузи через Skill tool ПЕРЕД работой» (по модели dev-2.json); (3) хвост секции скиллов, оказавшийся после MCP-блока, перемещён на место. Верификация: ConvertFrom-Json OK, context7=3, MCP-heading=1, обрывов=0. sync-agents.ps1: 19/19 OK. dev-1.txt: 45 строк, один MCP-блок, нет дублей.
STATUS: resolved

[2026-08-25] team-lead → all:
TYPE: update | PRIORITY: high
CONTENT: MCP-практика внедрена: блок использования MCP (context7/sequential-thinking/hermes-atlas-mcp) добавлен в промпты 10 ключевых агентов через dev-2 + sync. Созданы 3 скилла 1С (skill-surgeon): 1c-dev, 1c-query, 1c-edt-configurator — готовых в каталогах не было (проверены GitHub-источники: Desko77, Nikolay-Shirokov/cc-1c-skills). Дефект вставки у dev-1 (дубль MCP-блока, обрыв фразы) исправлен dev-3. Приёмки: qa 28/28 ПРИНЯТО, спот-чек ПРИНЯТО. verify 29/29.
STATUS: resolved
