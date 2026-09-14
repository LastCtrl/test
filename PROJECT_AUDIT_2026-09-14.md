# Полный технический аудит agent-hq

**Дата:** 2026-09-14  
**Репозиторий:** `LastCtrl/test`  
**Базовый коммит:** `cd405d6af28c8ea5712061362a0370953f8ddf07`  
**Объём:** 203 отслеживаемых файла; 30 агентов; 18 PowerShell-скриптов; 29 каталогов skills; 2 JS-плагина; минимальный FastAPI endpoint.  
**Стратегический план развития:** `AGENT_HQ_EVOLUTION_PLAN.md`

> Это единый независимый аудит Arena Agent Mode. Он не выдаётся за три реально выполненных заключения конкретных закрытых моделей Claude/Fable/ChatGPT. Для полноты применены три аналитические линзы: архитектура продукта, инженерная реализация и безопасность/эксплуатация.

---

## 1. Резюме для владельца

Идея проекта сильная: репозиторий формализует роли агентов, очереди, память, изоляцию через worktree, проверки, восстановление и наблюдаемость. Видно значительное внимание к Windows/PowerShell, русскоязычным инструкциям и операционным сценариям.

Однако текущая реализация ближе к **прототипу оркестрационной платформы**, чем к надёжной рабочей системе. Документация описывает возможности увереннее, чем их подтверждает исполняемый код. Зелёный GitHub Actions проверяет главным образом наличие файлов и ключевых слов, но не главный пользовательский путь.

### Итоговая оценка

| Область | Оценка | Комментарий |
|---|---:|---|
| Идея и продуктовая декомпозиция | 8/10 | Хорошо сформулированная мультиагентная модель |
| Архитектурная целостность | 5/10 | Много источников истины и расхождений |
| Исполняемость основного сценария | 3/10 | Есть критические несовместимости конфигурации и прав |
| Качество кода | 5/10 | Код структурирован, но почти не покрыт тестами |
| Безопасность | 4/10 | Есть правила безопасности, но права слишком широкие |
| Наблюдаемость | 4/10 | Есть заготовки, но метрики недостаточны и ошибки скрываются |
| CI/CD и тестирование | 3/10 | CI зелёный, но даёт ложное чувство готовности |
| Документация | 7/10 | Обширная, но противоречивая и местами устаревшая |
| Переносимость | 2/10 | Жёсткая привязка к одной Windows-машине |
| Готовность к эксплуатации | **3.5/10** | Нужна стабилизация P0/P1 до реального использования |

### Главный вывод

Не следует пока увеличивать число агентов или добавлять новые функции. Сначала надо доказать один минимальный end-to-end сценарий:

1. основной агент получает задачу;
2. вызывает product-manager и team-lead;
3. team-lead назначает исполнителя;
4. исполнитель обрабатывает inbox;
5. результат попадает в outbox;
6. QA/compliance действительно отклоняет некорректный отчёт;
7. состояние агента и задачи атомарно обновляется;
8. трасса связывает project/task/agent/model/result.

---

## 2. Что сделано хорошо

1. **Ясное разделение ролей.** Конфиги, prompts, cards и registry охватывают разработку, QA, review, security и документацию.
2. **Изоляция через git worktree заложена концептуально.** Это правильнее, чем разрешать всем агентам писать в одну рабочую копию.
3. **Есть восстановление и dead-letter подход.** `inbox-poller.ps1`, `session-recovery.ps1`, archive/outbox/dead-letter показывают зрелое направление мысли.
4. **Секрет TokenRouter не захардкожен.** Используется `{env:TOKENROUTER_API_KEY}` (`opencode.json:818`).
5. **Есть резервное копирование перед записью JSON.** Registry и queue пытаются валидировать результат и восстановить backup.
6. **Read-only роли частично ограничены.** `code-reviewer` и `security-auditor` не имеют edit/bash.
7. **Документация охватывает эксплуатацию.** README, AGENTS, планы, requirements и memory дают много контекста.
8. **Последний GitHub Actions run успешен.** Это подтверждает прохождение существующего verify-скрипта, хотя не подтверждает работоспособность продукта.

### Уточнение после повторной проверки: 30 агентов как многопроектный пул

Замысел владельца подтверждается репозиторием. `REQUIREMENTS-PARALLEL-PROJECTS.md` прямо определяет агентов как общий пул с dynamic routing; один агент должен работать только в одном проекте, после завершения возвращаться в `free`. Для этого уже реализованы существенные части:

- `.memory/agent-registry.json` содержит 30 агентов и состояния `free/busy/error`;
- `agent-registry.ps1 -Acquire` фильтрует свободных по специализации и учитывает match count, daily load и rating (`agent-registry.ps1:381-505`);
- доступны явные `Reserve` и `Release` (`agent-registry.ps1:198-268`);
- каждый проект получает отдельный `queue.json`, context buffer и memory;
- `project-queue.ps1` поддерживает priority/FIFO, complete, stale/retry/dead;
- при `Complete` назначенный агент освобождается (`project-queue.ps1:340-387`);
- `agent-utilization.ps1` считает busy/free и распределение по проектам;
- `create-project.ps1` принимает ограниченный список `-Agents` и умеет создавать для них worktrees.

**Скорректированный вывод:** архитектурная идея «30 зарегистрированных агентов, из которых для каждого проекта выбирается небольшая временная команда» в проекте действительно заложена. Моя первоначальная рекомендация сократить сам пул до пяти ролей была излишне жёсткой. Сохранять 30 агентов разумно.

Но сейчас это ещё **набор частично связанных механизмов**, а не полностью замкнутый автоматический scheduler:

1. В исполняемых скриптах нет связки, которая автоматически делает `queue task → Acquire → Reserve с реальным task ID → inbox → Complete/Release`. Поиск вызовов `-Acquire/-Reserve/-LogAssignment` находит проверки и документацию, но не production scheduler.
2. Team-lead prompts в текущих `.txt` и исходных agent JSON не содержат команд `agent-registry.ps1`/`project-queue.ps1`, хотя `CONTEXT-BUFFER.md` заявляет, что такой workflow туда добавлялся. Это фактический drift между отчётом и файлами.
3. `Acquire` записывает фиктивный `current_task = "$ProjectName-acquire"`, не ID задачи очереди (`agent-registry.ps1:490-495`).
4. `project-queue.ps1 -Add -Agent X` помечает задачу assigned, но не резервирует X в registry (`project-queue.ps1:237-257`).
5. Inbox poller вообще не читает project queue/registry и не обновляет их; он сканирует все inbox и обрабатывает файлы последовательно (`inbox-poller.ps1:302-313`). Глобальный mutex не допускает второй poller, поэтому этот путь сам по себе не даёт параллельного исполнения.
6. Stale/dead переходы не освобождают назначенного агента; возможен вечный `busy`.
7. В `Complete` агент освобождается до успешного сохранения `done`; при ошибке Save-Queue registry и queue расходятся.
8. Текущий registry показывает всех агентов `free`; исторические `daily_load` есть лишь у нескольких. Это подтверждает наличие механизма, но не активную многопроектную работу в данном checkout.
9. Сохранённый `.memory/outbox/test-001.json` особенно показателен: OpenCode сообщил `agent "dev-1" not found`, fallback и отказ permission, но poller записал запись со `status: done`. Это подтверждает разрыв runtime integration и ошибку определения успеха.

Таким образом, правильная стратегия — **не удалять 30 агентов**, а завершить и протестировать scheduler вокруг уже существующего пула.

---

## 3. Критические проблемы — P0

### P0-1. `opencode.json` не соответствует актуальной схеме OpenCode

**Доказательства:**

- используется верхнеуровневый ключ `"agents"` (`opencode.json:67`), тогда как актуальная схема и документация используют `"agent"`;
- добавлены неизвестные схеме верхнеуровневые блоки `memory`, `workspace`, `projects`, `modules` (`opencode.json:758-812`);
- актуальная схема имеет `additionalProperties: false` на верхнем уровне;
- `sync-agents.ps1` намеренно генерирует именно `"agents"` (`sync-agents.ps1:433`), поэтому ошибка воспроизводится после каждой синхронизации.

**Последствие:** OpenCode может отвергнуть конфиг либо игнорировать ключевые настройки. CI проверяет только синтаксический JSON через `ConvertFrom-Json`, но не JSON Schema.

**Исправление:**

- мигрировать `agents` → `agent`;
- вынести custom metadata (`memory/workspace/projects/modules`) в отдельный `agent-hq.json` со своей схемой;
- обновить `sync-agents.ps1`;
- добавить schema validation в CI против `https://opencode.ai/config.json` с зафиксированной версией/копией схемы.

### P0-2. Оркестрация запрещена собственными permissions

Все 30 агентов имеют `permission.task = "deny"`. В частности, `team-lead` и его копии не могут вызвать product-manager, исполнителей или проверяющих. При этом prompts требуют многочисленные вызовы `task`.

**Доказательства:** `opencode.json`, конфиги team-lead; автоматический подсчёт: `task allow = 0`.

**Последствие:** заявленный dual-agent delegation не может работать согласно собственному конфигу.

**Исправление:**

- создать primary orchestrator;
- выдать ему pattern-based task permissions только на разрешённые роли;
- запретить рекурсивный вызов самого себя;
- оставить исполнителям `task: deny`;
- добавить интеграционный тест разрешённых/запрещённых делегаций.

### P0-3. Все skills, вероятно, не обнаруживаются актуальным OpenCode

Все 29 `SKILL.md` начинаются сразу с Markdown-заголовка и не имеют YAML frontmatter с обязательными `name` и `description`. Актуальная документация OpenCode требует frontmatter и отдельно рекомендует проверять эти поля при проблемах загрузки.

**Последствие:** проект требует skills-first и отклоняет задачи без skills, но сам runtime может не видеть ни одного skill.

**Исправление:** добавить каждому skill корректный frontmatter, валидировать уникальность name, допустимость имени и наличие description в CI.

### P0-4. `compliance-gate.ps1` фактически не проверяет реальные отчёты

Regex ожидает разделитель `>>` (`compliance-gate.ps1:25`), а реальные записи используют `->` и `→`. В текущем `CONTEXT-BUFFER.md` нет соответствующего формату `>>` потока отчётов. При отсутствии совпадений gate пишет INFO и возвращает успех (`compliance-gate.ps1:72-74,102`).

Дополнительно:

- наличие произвольного непустого текста в массивах считается достаточным;
- не проверяются заявленные условия context7/sequential-thinking;
- health-check запускает gate с `Strict:$false` (`health-check.ps1:127`);
- health-check ориентируется на `$LASTEXITCODE`, хотя non-strict нарушение может лишь вернуть `$false` без ненулевого exit code;
- `verify-phase.ps1` вообще не запускает строгую compliance-проверку.

**Последствие:** enforcement существует в документации, но fail-open в коде.

**Исправление:** отказаться от regex по свободному Markdown. Писать отчёты как JSONL/JSON Schema и отображать Markdown как производное представление. При `0 parsed records`, если ожидалась задача, возвращать ошибку. В merge gate использовать только strict mode.

### P0-5. `inbox-poller.ps1` теряет реальный exit code OpenCode

После `Start-Job` код устанавливает успех, если результат просто непустой (`inbox-poller.ps1:247-251`). Текст ошибки CLI обычно непустой, поэтому неуспешный процесс может быть записан как успешный outbox. Та же ошибка есть в retry (`276-279`).

**Последствие:** ложные DONE, потеря задач и обход dead-letter.

**Исправление:** внутри job возвращать структурированный объект `{stdout, stderr, exitCode}` и явно сохранять `$LASTEXITCODE`; валидировать контракт результата; добавить тесты exit 0/1/124, пустой вывод, stderr-only и timeout.

---

## 4. Высокий приоритет — P1

### P1-1. Очереди и registry не атомарны на уровне транзакции

`Load-Queue` читает файл без общей блокировки, бизнес-логика меняет объект, а `Save-Queue` блокирует только момент записи (`project-queue.ps1:87-171`). Два процесса могут прочитать одну версию, сгенерировать одинаковый ID или перезаписать изменения друг друга. Аналогично reserve: проверка `free` выполняется до получения write lock (`agent-registry.ps1:204-228`).

**Решение:** lock должен охватывать read-modify-write. Лучше SQLite с транзакциями, unique constraints и WAL. Минимальный вариант — lockfile/Mutex + atomic temp-file rename + version/CAS.

### P1-2. Права внешних директорий чрезмерны

22 агента имеют полный bash, 25 — edit. Каждый агент получает allow на `D:\Тест\**`, пользовательские каталоги конфигурации и локальные данные OpenCode. Это противоречит принципу least privilege и увеличивает blast radius prompt injection/ошибки.

**Решение:**

- по умолчанию `"*": "ask"` или deny;
- разрешать edit только внутри конкретного worktree;
- гранулярно разрешить безопасные bash-команды;
- запретить git push/credential/system operations;
- пользовательские глобальные каталоги не раздавать каждому агенту.

### P1-3. CI проверяет форму, а не поведение

`verify-phase.ps1` в основном проверяет наличие папок, количество файлов, ключевые слова и простые команды. В CI многие runtime checks пропускаются (`Test-LocalCheck`). Нет:

- запуска OpenCode с конфигом;
- schema validation;
- Pester unit tests;
- тестов конкурентности;
- тестов poller exit codes/timeouts;
- тестов plugins;
- теста FastAPI;
- security/dependency scanning;
- проверки encoding/frontmatter.

**Решение:** создать уровни CI: static → unit → integration → Windows E2E. Зелёный build должен означать рабочий happy path и ключевые failure paths.

### P1-4. Наблюдаемость недостаточна и скрывает собственные ошибки

JS-плагины подавляют все исключения пустыми `catch (_) {}`. Tracer пишет только tool и duration без project/task/agent/model/call result. Scoring считает `100 - duration_in_minutes`; это не качество и поощряет быстрый, но неверный ответ. Токены и стоимость, обещанные `/cost-report`, плагины не записывают.

**Решение:** OpenTelemetry или хотя бы единая JSON event schema; correlation IDs; result status; model; tokens; retries; queue latency; redaction; rotation; metric definitions. Ошибки логирования считать отдельной метрикой, а не скрывать.

### P1-5. Источники истины размножены

Один агент представлен минимум в:

1. `.opencode/agents/*.json`;
2. `opencode.json`;
3. `.opencode/agents/registry.json`;
4. `.memory/agent-registry.json`;
5. `.agents/cards/*.json`;
6. prompt `.txt`;
7. README/AGENTS.

Автоматическое сравнение показало различия между всеми 30 standalone configs и агрегированными объектами (частично различия ожидаемы из-за трансформации, но это всё равно drift-risk). Registry уже содержит mojibake.

**Решение:** один declarative source (`agents.yaml/json`), из которого детерминированно генерируются runtime config, cards и docs. CI запускает generator и требует clean git diff.

### P1-6. Кодировка данных повреждена

`.opencode/agents/registry.json` содержит mojibake в русских descriptions. `CONTEXT-BUFFER.md` содержит большой объём повреждённого текста. Два отслеживаемых JSON имеют UTF-8 BOM, из-за чего строгий стандартный Python JSON loader их не читает.

**Решение:** UTF-8 without BOM policy через `.editorconfig`, normalizer и CI test; миграция испорченных данных; структурированные runtime events вместо многократного преобразования Markdown.

### P1-7. Портируемость практически отсутствует

Конфиг жёстко содержит пользователя `Ermak_DS`, диск `D:`, каталог `D:\Тест\agent-hq`, локальный прокси `127.0.0.1:3128` и внутренний домен. README quick start также привязан к этому пути.

**Решение:** `opencode.example.json` + локальный gitignored override; переменные окружения; `$PSScriptRoot`; профили `windows-corporate`, `windows-standard`, `linux-ci`; preflight command.

---

## 5. Средний приоритет — P2

### P2-1. FastAPI API не интегрирован

`api/main.py` содержит только `/health`; на него нет ссылок в архитектуре, CI или scripts. Нет lockfile, теста, Dockerfile и deployment path. Сейчас это orphan/placeholder.

**Решение:** либо удалить API до появления use case, либо сделать control plane: health/readiness, queue status, agents status, metrics; добавить auth для mutation endpoints и тесты.

### P2-2. Документация противоречит runtime

Примеры:

- README обещает распределение по GLM/Nemotron, но все 30 runtime agents используют GLM;
- AGENTS одновременно описывает Nemotron escalation и утверждает, что единственная модель — GLM;
- указано 24 skills, фактически каталогов 29 (17 1C + 8 core + 4 superpowers);
- AGENTS говорит о 19 специалистах, runtime содержит 30 агентов;
- `/new-project` говорит `.agents/projects/`, а архитектура и скрипты используют `projects/`;
- README заявляет `$0 всегда`, хотя доступность и коммерческие условия внешних providers не контролируются репозиторием.

**Решение:** генерировать таблицы из source config; помечать claims как current/target; убрать абсолютные гарантии стоимости и latency.

### P2-3. README перегружен внутренними деталями

Для нового пользователя не хватает короткого проверяемого пути: prerequisites, install, env vars, preflight, first task, expected output, troubleshooting. Вместо этого сразу представлены десятки внутренних компонентов.

**Решение:** разделить User Guide, Architecture, Operations, Contributor Guide и ADR. README оставить коротким.

### P2-4. Нет управления зависимостями

`api/requirements.txt` использует широкие `>=`, lockfile отсутствует. Нет package manifest для JS-плагинов, Dependabot/Renovate, SBOM и vulnerability scan.

**Решение:** pin/lock зависимости, Dependabot, `pip-audit`, CodeQL, secret scanning, action SHA pinning для повышенной supply-chain защиты.

### P2-5. Performance score некорректно назван

Текущая формула измеряет только длительность сессии. Это latency score, а не performance/quality score.

**Решение:** разделить latency, correctness, retry rate, acceptance rate, token efficiency и user rating. Не сводить их в одно число без документированной модели.

### P2-6. Memory и context bus не масштабируются

Общий append-oriented Markdown создаёт конфликты, не имеет схемы, идемпотентности, sequence number и устойчивого consumer offset. Чтение «последних 30 строк» может обрезать одну большую запись или пропустить контекст.

**Решение:** event store SQLite/JSONL с project/task IDs и sequence; Markdown summary генерировать отдельно.

---

## 6. Взгляд с трёх аналитических позиций

### Архитектор продукта

- Сильная сторона — роли и desired workflow описаны подробно.
- 30 агентов обоснованы как **общий пул для нескольких одновременных проектов**; сокращать каталог ролей не обязательно.
- Главная проблема не в размере пула, а в незавершённой автоматической связке `project queue → acquire/reserve → inbox worker → complete/release`.
- Рекомендация — сохранить 30 зарегистрированных ролей, но сначала подтвердить MVP-путь на временной команде из 3–5 выбранных агентов. Остальные должны оставаться `free`, а не запускаться на каждый запрос.

### Senior/Staff инженер

- Главные риски — конфигурационный drift, non-atomic state, отсутствие контрактных тестов и fail-open validation.
- Рекомендация — typed schemas, один generator, SQLite state store, Pester tests, настоящий E2E.
- PowerShell можно сохранить как CLI shell, но core state machine лучше вынести в тестируемый Python/TypeScript модуль.

### Security/SRE

- Главные риски — broad bash/edit/external access, непроверяемый supply chain MCP-команд, скрытые исключения и отсутствие audit correlation.
- Рекомендация — deny by default, sandbox boundary, allowlist commands/providers, redaction, signed/locked dependencies, metrics/SLO и disaster-recovery tests.

---

## 7. Рекомендуемая целевая архитектура

```text
agent-hq.yaml (единственный declarative source)
        │
        ├── generator → opencode.json (только валидные OpenCode keys)
        ├── generator → agent cards/docs
        └── validator → JSON Schema + semantic checks

CLI / OpenCode orchestrator
        │
        ▼
SQLite state store
(projects, tasks, attempts, agents, leases, events)
        │
        ├── scheduler/lease manager
        ├── worker runner (structured exit/result)
        ├── policy engine (permissions/compliance)
        └── telemetry exporter

Markdown README / CONTEXT summary = generated views, не база данных
```

Ключевые свойства:

- transactional task claim;
- lease timeout и heartbeat;
- idempotency key;
- bounded retries;
- structured result contract;
- append-only audit events;
- project isolation;
- policy deny-by-default;
- reproducible config generation.

---

## 8. План доработок

### Этап 0 — сохранить воспроизводимость (0.5–1 день)

- Зафиксировать используемую версию OpenCode.
- Сохранить её JSON Schema в repo или pin download checksum.
- Записать один реальный failing/successful launch log.
- Создать baseline smoke test.

**Готово, когда:** чистая машина может воспроизвести текущий запуск по инструкции.

### Этап 1 — устранить P0 (2–4 дня)

- Исправить `agent`/custom config blocks.
- Выдать orchestrator корректный task allowlist.
- Добавить frontmatter всем skills.
- Переписать compliance на structured records.
- Сохранять настоящий exit code poller.
- Добавить тест каждого исправления.

**Готово, когда:** schema validation и минимальный E2E проходят на Windows CI.

### Этап 2 — надёжное состояние (3–6 дней)

- Перенести registry/queue/attempts в SQLite.
- Реализовать lease/heartbeat/idempotency.
- Добавить concurrent tests (2–20 workers).
- Оставить JSON/Markdown exports для просмотра.

**Готово, когда:** конкурентные reserve/claim не теряют задачи и не назначают агента дважды.

### Этап 3 — безопасность и наблюдаемость (2–4 дня)

- Перейти на deny-by-default permissions.
- Убрать персональные абсолютные пути.
- Ввести correlation IDs и event schema.
- Добавить log rotation/redaction/error counters.
- Подключить dependency/security scans.

**Готово, когда:** security test подтверждает границы worktree и отсутствие доступа к посторонним каталогам.

### Этап 4 — документация и UX (1–3 дня)

- Перегенерировать docs из source config.
- Написать 10-минутный quick start.
- Разделить current state и roadmap.
- Добавить команды `doctor`, `validate`, `smoke-test`.

**Готово, когда:** новый пользователь запускает demo без знания внутренней архитектуры.

### Этап 5 — проверка многопроектного пула после стабилизации

- Сохранить каталог из 30 агентов как общий пул.
- Сначала проверить динамическое выделение 3–5 агентов двум проектам.
- Затем провести нагрузочный тест пяти проектов с разными временными командами.
- Добавлять новые копии ролей только при измеренной queue latency/utilization; существующие копии пока можно оставить.
- Проверить, что незадействованные агенты остаются `free`, один agent ID не назначается двум проектам, а завершение задачи всегда освобождает агента.
- Сравнивать модели на фиксированном benchmark-наборе, а не по субъективным единичным ratings.

---

## 9. Предлагаемая CI-матрица

| Job | ОС | Что проверяет |
|---|---|---|
| config | ubuntu | JSON Schema, generated diff, prompt refs, skill frontmatter |
| powershell-unit | windows | Pester для queue/registry/poller/compliance |
| node-unit | ubuntu/windows | tracer/scoring events и failures |
| python-unit | ubuntu/windows | FastAPI health/control-plane, если API остаётся |
| security | ubuntu | gitleaks, CodeQL, dependency audit |
| integration | windows | fake OpenCode CLI: exit codes, timeout, retry, dead-letter |
| e2e | windows | реальный pinned OpenCode, одна делегация и QA rejection |
| concurrency | windows | race tests reserve/claim/complete |

CI должен падать при:

- неизвестном ключе OpenCode config;
- нераспознанном skill;
- пустом/невалидном self-report;
- nonzero worker exit;
- duplicate task claim;
- несовпадении generated files;
- mojibake/BOM policy violation.

---

## 10. Дополнительные функции и идеи развития

Подробная реализация и место каждой функции в roadmap описаны в `AGENT_HQ_EVOLUTION_PLAN.md`. Ниже — сводный список предложений, дополняющих исходную концепцию проекта.

### 10.1 Explainable Routing

Для каждого назначения сохранять объяснение выбора агента и модели: специализация, рейтинг, доступность, квота, риск, стоимость и причины отклонения альтернатив. Это позволит проверять решения router и отлаживать неверные назначения.

### 10.2 Capability Passport модели

Поддерживать автоматически обновляемую карточку каждой модели:

- сильные и слабые типы задач;
- качество tool calling;
- поддерживаемые языки и технологии;
- context window;
- latency и стоимость;
- provider limits;
- reliability;
- количество наблюдений и confidence.

### 10.3 Prompt A/B Testing

Версионировать prompts по hash, безопасно направлять часть Low-risk задач на candidate-версию и сравнивать acceptance rate, retries, latency и tokens. Новая версия становится основной только после устойчивого улучшения; при деградации выполняется rollback.

### 10.4 Team Composition Optimizer

Оценивать не только отдельных агентов, но и состав команды. Например, сравнивать `backend + QA`, `backend + reviewer` и `backend + QA + reviewer`, чтобы находить минимальную команду, обеспечивающую необходимое качество для конкретного риска.

### 10.5 Reviewer Disagreement Detector

Если QA, code-reviewer и security-auditor дают противоречивые verdict, система не выбирает простое большинство, а сравнивает evidence, запускает детерминированные тесты и при необходимости назначает независимого tie-breaker.

### 10.6 Failure Memory

Хранить структурированные сигнатуры прошлых ошибок, неудачные подходы, успешные исправления и модели, которые справились. Перед retry искать похожие случаи и добавлять релевантный опыт в задание, не передавая агенту весь общий журнал.

### 10.7 Task Replay

Сохранять достаточно данных для воспроизведения выполнения: исходный prompt, base commit, версии файлов, model parameters, tool calls, результаты и verdict. Это необходимо для отладки, расследования false DONE и честного сравнения моделей.

### 10.8 Canary Model Rollout

Подключать новые модели по этапам: shadow tasks → 5% Low-risk → 15% Normal-risk → production promotion. При превышении порога ошибок или снижении качества автоматически откатывать routing.

### 10.9 Confidence-aware Automation

Учитывать уверенность классификатора, evaluator и model ratings. Низкая уверенность приводит не к случайному автоматическому решению, а к дополнительному planner/reviewer, тестам или запросу подтверждения.

### 10.10 Dynamic Verification Depth

Выбирать глубину проверки по risk, novelty, reversibility и blast radius. Документационная правка получает лёгкую проверку, а authentication, DB migration или destructive operation — полный QA/review/security pipeline.

### 10.11 Semantic Task Deduplication

Находить одинаковые research/documentation задачи в разных проектах и безопасно переиспользовать уже проверенный общий результат, сохраняя изоляцию приватного контекста проектов.

### 10.12 Cost/Quality Frontier

Показывать не единственного «победителя», а Pareto-варианты: самая быстрая, самая дешёвая, самая качественная модель и лучший баланс. Project policy выбирает подходящий режим.

### 10.13 Project Autopilot Levels

Ввести уровни автономности:

| Уровень | Режим |
|---|---|
| 0 | Observe — только рекомендации |
| 1 | Assist — выполнение после подтверждения |
| 2 | Auto-safe — автономные обратимые Low/Normal задачи |
| 3 | Auto-project — автономный workflow с checkpoints |
| 4 | Full autonomy — human approval только для Critical действий |

### 10.14 Chaos Testing

Регулярно моделировать timeout, quota exhaustion, malformed output, зависший worker, потерю heartbeat, повреждение state, конфликт worktree, недоступный MCP и противоречие reviewers. Система должна доказать, что не теряет задачу и не создаёт false DONE.

### 10.15 Policy Simulator

Перед включением новой routing/permission policy проигрывать исторические события и показывать, какие назначения изменились бы, где выросли бы стоимость или latency и какие операции были бы запрещены.

### Приоритет внедрения

Эти функции не должны задерживать исправление P0. Рекомендуемый порядок:

1. после надёжного scheduler — Explainable Routing, Task Replay и Failure Memory;
2. после Evaluation v1 — Capability Passport и Cost/Quality Frontier;
3. после накопления статистики — Canary Models, Prompt A/B и Team Optimizer;
4. после стабилизации production workflow — Autopilot Levels, Chaos Testing и Policy Simulator.

---

## 11. Конкретный backlog

### P0

- [ ] Мигрировать `opencode.json` на актуальную schema (`agent`, только допустимые keys).
- [ ] Исправить generator `sync-agents.ps1`.
- [ ] Разрешить task tool только orchestrator по allowlist.
- [ ] Добавить YAML frontmatter 29 skills.
- [ ] Заменить Markdown-regex compliance структурированной схемой.
- [ ] Исправить передачу native exit code в poller.
- [ ] Написать E2E happy path + intentional rejection.

### P1

- [ ] Сделать queue/registry transactional.
- [ ] Сузить bash/edit/external permissions.
- [ ] Создать единый source агента и deterministic generator.
- [ ] Исправить encoding/mojibake/BOM.
- [ ] Добавить Pester и CI schema validation.
- [ ] Ввести correlation IDs и честные telemetry metrics.
- [ ] Убрать machine-specific paths в local override.

### P2

- [ ] Решить судьбу FastAPI API.
- [ ] Pin/lock dependencies и включить update/security automation.
- [ ] Разделить документацию current/target.
- [ ] Сгенерировать agent/model/skill tables.
- [ ] Переработать scoring.
- [ ] Ввести retention/rotation для events и memory.

---

## 12. Выполненные проверки

- `git status`, дерево и история репозитория;
- строгий JSON parse 81 файла: 2 файла с BOM не проходят обычное чтение UTF-8;
- Node syntax check двух plugins: успешно;
- Python compile `api`: успешно;
- импорт API не выполнялся из-за отсутствующих в sandbox зависимостей;
- подсчёт и сопоставление 30 agent configs/registries/prompts;
- анализ permissions;
- поиск секретов и опасных process/file patterns;
- проверка текущего GitHub Actions: последний run успешен;
- проверка актуальной OpenCode schema/docs на 2026-09-14;
- анализ PowerShell read-modify-write, poller и compliance flow;
- проверка encoding и документальных противоречий.

### Ограничения аудита

- В Linux sandbox нет `powershell`/`pwsh`, поэтому PowerShell scripts не были исполнены локально.
- Не выполнялся реальный OpenCode/TokenRouter запрос: это могло бы расходовать внешнюю квоту и требует локального окружения владельца.
- Нет независимых запусков конкретных закрытых моделей под их именами.

---

## 13. Финальная рекомендация

Проект стоит продолжать: концепция полезная, а значительная часть каркаса уже создана. Но следующая версия должна быть не «ещё больше агентов», а **стабилизационный релиз**.

Предлагаемая цель релиза:

> `v0.1 — один воспроизводимый, безопасный, транзакционный и наблюдаемый end-to-end workflow на Windows: из общего пула 30 агентов выбирается минимальная команда, задача проходит acquire → execute → review → release, а результат подтверждается CI.`

После этого можно объективно измерять, сколько агентов одновременно нужно каждому проекту, какие роли становятся узкими местами, какие модели лучше и где параллелизм действительно даёт выигрыш.

---

## Актуальные внешние ориентиры

- OpenCode config schema: `https://opencode.ai/config.json`
- OpenCode agents: `https://opencode.ai/docs/agents/`
- OpenCode permissions: `https://opencode.ai/docs/permissions/`
- OpenCode skills: `https://opencode.ai/docs/skills/`
- OpenCode plugins: `https://opencode.ai/docs/plugins/`
