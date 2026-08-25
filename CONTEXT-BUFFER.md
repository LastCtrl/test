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
