# PHASE1 PART 13/15

  344:     $hasMode = $data.mode -and ($data.mode -is [string]) -and ($data.mode.Trim().Length -gt 0)
  345:     $hasModel = $data.model -and ($data.model -is [string]) -and ($data.model.Trim().Length -gt 0)
  346: 
  347:     if (-not $hasDescription) {
  348:         Write-Warning "SKIP $($file.Name): missing or empty required field 'description'"
  349:         continue
  350:     }
  351:     if (-not $hasMode) {
  352:         Write-Warning "SKIP $($file.Name): missing or empty required field 'mode'"
  353:         continue
  354:     }
  355:     if (-not $hasModel) {
  356:         Write-Warning "SKIP $($file.Name): missing or empty required field 'model'"
  357:         continue
  358:     }
  359: 
  360:     $name = if ($data.name) { $data.name } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
  361: 
  362:     $promptFile = Join-Path $promptsDir "$name.txt"
  363:     [System.IO.File]::WriteAllText($promptFile, $data.prompt, (New-Object System.Text.UTF8Encoding($false)))
  364: 
  365:     $perm = [ordered]@{}
  366:     foreach ($key in $allowKeys) {
  367:         if ($data.permissions -contains $key) {
  368:             $perm[$key] = "allow"
  369:         } elseif ($denyIfMissing -contains $key) {
  370:             $perm[$key] = "deny"
  371:         }
  372:     }
  373:     # external_directory: глобальные доверенные зоны (D:\Тест + opencode-пути на C:)
  374:     # Без этого per-agent permission перекрывает top-level и агенты просят подтверждение
  375:     $perm["external_directory"] = [ordered]@{
  376:         "D:\Тест\**"                                        = "allow"
  377:         "C:\Users\Ermak_DS\.local\share\opencode\**"        = "allow"
  378:         "C:\Users\Ermak_DS\AppData\Local\opencode\**"       = "allow"
  379:         "C:\Users\Ermak_DS\.config\opencode\**"             = "allow"
  380:     }
  381: 
  382:     # Собираем entry как хэштаблицу (не PSCustomObject — для ручной сериализации)
  383:     $entry = @{
  384:         name        = $name
  385:         description = [string]$data.description
  386:         mode        = if ($data.mode) { [string]$data.mode } else { "subagent" }
  387:         model       = if ($data.model) { [string]$data.model } else { "" }
  388:         temperature = if ($null -ne $data.temperature) { [double]$data.temperature } else { $null }
  389:         permission  = $perm
  390:         prompt      = "{file:.opencode/agents/prompts/$name.txt}"
  391:     }
  392: 
  393:     $agentEntries.Add($entry) | Out-Null
  394:     $count++
  395:     Write-Host "  [$count] $name -> $($data.model)" -ForegroundColor Green
  396: }
  397: 
  398: if ($count -eq 0) {
  399:     Write-Warning "No valid agents found — aborting"
  400:     exit 1
  401: }
  402: 
  403: # --- DryRun: показать превью и выйти ---
  404: if ($DryRun) {
  405:     Write-Host "`n=== DRY RUN: generated agent section preview ===" -ForegroundColor Yellow
  406:     Write-Host '  "agent": {'
  407:     for ($i = 0; $i -lt $agentEntries.Count; $i++) {
  408:         $e = $agentEntries[$i]
  409:         $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
  410:         $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
  411:         Write-Host ($jsonBlock + $comma)
  412:     }
  413:     Write-Host '  }'
  414:     Write-Host "`n=== DRY RUN: opencode.json NOT modified ===" -ForegroundColor Yellow
  415:     exit 0
  416: }
  417: 
  418: # ============================================================
  419: # ТОЧЕЧНАЯ ТЕКСТОВАЯ ЗАМЕНА секции "agent" в opencode.json
  420: # НЕ используем ConvertFrom-Json/ConvertTo-Json на всём файле —
  421: # PS 5.1 теряет NoteProperty-секции и портит кириллицу.
  422: # ============================================================
  423: 
  424: if (-not (Test-Path $configPath)) {
  425:     throw "opencode.json not found: $configPath"
  426: }
  427: 
  428: # 1. Прочитать как ТЕКСТ с явным UTF-8
  429: $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  430: 
  431: # 2. Собрать JSON секции agent вручную (без ConvertTo-Json — PS 5.1 ломает кириллицу)
  432: $agentLines = [System.Collections.ArrayList]::new()
  433: [void]$agentLines.Add('  "agents": {')
  434: for ($i = 0; $i -lt $agentEntries.Count; $i++) {
  435:     $e = $agentEntries[$i]
  436:     $jsonBlock = ConvertTo-AgentJson -name $e.name -description $e.description -mode $e.mode -model $e.model -temperature $e.temperature -permission $e.permission -prompt $e.prompt
  437:     $comma = if ($i -lt $agentEntries.Count - 1) { ',' } else { '' }
  438:     [void]$agentLines.Add($jsonBlock + $comma)
  439: }
  440: [void]$agentLines.Add('  }')
  441: $agentJsonBlock = $agentLines -join "`n"
  442: 
  443: # 3. Найти верхнеуровневый ключ "agents" (любой отступ, но ТОЛЬКО top-level)
  444: #    Устойчиво к отступам; дубль-защита: секция "agent" (ед.ч., легаси-баг) удаляется
  445: $agentPattern = '(?m)^[ \t]*"agents"\s*:\s*\{'
  446: $agentMatch = [regex]::Match($configText, $agentPattern)
  447: 
  448: # Легаси-дубль: удалить top-level "agent" (единственное число) если существует
  449: $legacyPattern = '(?m)^[ \t]*"agent"\s*:\s*\{'
  450: $legacyMatch = [regex]::Match($configText, $legacyPattern)
  451: if ($legacyMatch.Success) {
  452:     $newText = Remove-JsonTopLevelSection -text $configText -keyName "agent"
  453:     if ($null -ne $newText) {
  454:         $configText = $newText
  455:         Write-Warning "Legacy duplicate 'agent' section removed"
  456:         # Повторно ищем agents (позиции сместились)
  457:         $agentMatch = [regex]::Match($configText, $agentPattern)
  458:     }
  459: }
  460: 
  461: if (-not $agentMatch.Success) {
  462:     Write-Warning "Top-level 'agents' key not found — appending before final }"
  463:     $lastBrace = $configText.LastIndexOf("}")
  464:     if ($lastBrace -lt 0) {
  465:         throw "opencode.json has no closing brace — cannot inject agent section"
  466:     }
  467:     $beforeLast = $configText.Substring(0, $lastBrace).TrimEnd()
  468:     $needsComma = (-not $beforeLast.EndsWith(",")) -and ($beforeLast.Length -gt 0)
  469:     $comma = if ($needsComma) { "," } else { "" }
  470:     $inject = "`n" + $agentJsonBlock + "`n"
  471:     $configText = $configText.Substring(0, $lastBrace) + $comma + $inject + "}"
  472: }
  473: else {
  474:     # 4. Найти конец секции agent через balanced braces
  475:     $braceStart = $agentMatch.Index + $agentMatch.Length - 1  # индекс открывающей {
  476:     $braceEnd = Find-JsonBlockEnd -text $configText -startBraceIndex $braceStart
  477: 
  478:     if ($braceEnd -lt 0) {
  479:         throw "Cannot find matching closing brace for 'agent' section — aborting"
  480:     }
  481: 
  482:     # 5. Заменить подстроку от начала совпадения до парной } включительно
  483:     $replaceFrom = $agentMatch.Index
  484:     $replaceTo = $braceEnd + 1  # включая }
  485:     $configText = $configText.Remove($replaceFrom, $replaceTo - $replaceFrom).Insert($replaceFrom, $agentJsonBlock)
  486: }
  487: 
  488: # 6. Бэкап ПЕРЕД перезаписью
  489: $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  490: $backupPath = Join-Path $root "opencode.json.bak.$timestamp"
  491: 
  492: try {
  493:     Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
  494:     Write-Host "`nBackup created: $backupPath" -ForegroundColor Gray
  495: }
  496: catch {
  497:     Write-Warning "Failed to create backup: $($_.Exception.Message) — aborting to prevent data loss"
  498:     exit 1
  499: }
  500: 
  501: # 7. Записать UTF-8 без BOM
  502: [System.IO.File]::WriteAllText($configPath, $configText, (New-Object System.Text.UTF8Encoding($false)))
  503: 
  504: # 8. Проверка размера (>100 КБ — аномалия, откат)
  505: $writtenFile = Get-Item -LiteralPath $configPath
  506: if ($writtenFile.Length -gt 102400) {
  507:     Write-Error "opencode.json size $([math]::Round($writtenFile.Length / 1024, 1)) KB exceeds 100 KB limit — rolling back from backup"
  508:     Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
  509:     exit 1
  510: }
  511: 
  512: # 9. Валидация JSON ПОСЛЕ записи (ConvertFrom-Json ТОЛЬКО для проверки!)
  513: try {
  514:     $verifyRaw = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
  515:     $null = $verifyRaw | ConvertFrom-Json
  516: }
  517: catch {
  518:     Write-Error "opencode.json is invalid JSON after write — rolling back from backup: $($_.Exception.Message)"
  519:     Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
  520:     exit 1
  521: }
  522: 
  523: # 10. Удаление старых бэкапов — оставить только последние 3
  524: $allBackups = Get-ChildItem -LiteralPath $root -Filter "opencode.json.bak.*" | Sort-Object Name -Descending
  525: if ($allBackups.Count -gt 3) {
  526:     $toDelete = $allBackups | Select-Object -Skip 3
  527:     foreach ($old in $toDelete) {
  528:         Remove-Item -LiteralPath $old.FullName -Force
  529:         Write-Host "Old backup removed: $($old.Name)" -ForegroundColor Gray
  530:     }
  531: }
  532: 
  533: Write-Host "`n=== DONE: $count agents written to opencode.json (text replacement, manual JSON serialization) ===" -ForegroundColor Cyan
  534: Write-Host "Prompts saved to: $promptsDir" -ForegroundColor Gray
```

### `.opencode/plugins/tracer.js` lines 1-78

```javascript
    1: import fs from "node:fs";
    2: import path from "node:path";
    3: import os from "node:os";
    4: 
    5: export const TracerPlugin = ({ directory }) => {
    6:   const starts = new Map();
    7:   const tracesDir = path.join(
    8:     process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    9:     "opencode",
   10:     "agent-hq-traces"
   11:   );
   12:   const tracesFile = path.join(tracesDir, "traces.jsonl");
   13: 
   14:   const writeJsonl = (obj) => {
   15:     try {
   16:       fs.mkdirSync(tracesDir, { recursive: true });
   17:       fs.appendFileSync(tracesFile, JSON.stringify(obj) + "\n", "utf-8");
   18:     } catch (_) {}
   19:   };
   20: 
   21:   return {
   22:     "tool.execute.before": async (input, _output) => {
   23:       try {
   24:         const callID = input?.callID;
   25:         if (callID) {
   26:           if (starts.size >= 1000) {
   27:             const oldest = starts.keys().next().value;
   28:             starts.delete(oldest);
   29:           }
   30:           starts.set(callID, Date.now());
   31:         }
   32:       } catch (_) {}
   33:     },
   34: 
   35:     "tool.execute.after": async (input, _output) => {
   36:       try {
   37:         const callID = input?.callID;
   38:         const ms = callID && starts.has(callID) ? Date.now() - starts.get(callID) : 0;
   39:         if (callID) starts.delete(callID);
   40:         writeJsonl({
   41:           ts: new Date().toISOString(),
   42:           type: "tool",
   43:           tool: input?.tool,
   44:           ms,
   45:         });
   46:       } catch (_) {}
   47:     },
   48: 
   49:     event: async ({ event }) => {
   50:       try {
   51:         const id = event?.properties?.sessionID;
   52:         if (!id) return;
   53:         if (event?.type === "session.created") {
   54:           writeJsonl({ ts: new Date().toISOString(), type: "session_start", id });
   55:         } else if (event?.type === "session.error") {
   56:           const props = event?.properties ?? event ?? {};
   57:           const msg =
   58:             props.message ??
   59:             props.error ??
   60:             props.data ??
   61:             props.reason ??
   62:             props.detail ??
   63:             "";
   64:           const raw = JSON.stringify(props, null, 0);
   65:           writeJsonl({
   66:             ts: new Date().toISOString(),
   67:             type: "error",
   68:             id,
   69:             message: String(msg).slice(0, 300),
   70:             props: String(raw).slice(0, 500),
   71:           });
   72:         } else if (event?.type === "session.idle") {
   73:           writeJsonl({ ts: new Date().toISOString(), type: "session_end", id });
   74:         }
   75:       } catch (_) {}
   76:     },
   77:   };
   78: };
```

### `.opencode/plugins/scoring.js` lines 1-57

```javascript
    1: import fs from "node:fs";
    2: import path from "node:path";
    3: import os from "node:os";
    4: 
    5: export const ScoringPlugin = ({ directory }) => {
    6:   const sessions = new Map();
    7:   const tracesDir = path.join(
    8:     process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
    9:     "opencode",
   10:     "agent-hq-traces"
   11:   );
   12:   const perfFile = path.join(tracesDir, "performance.jsonl");
   13: 
   14:   const writeJsonl = (obj) => {
   15:     try {
   16:       fs.mkdirSync(tracesDir, { recursive: true });
   17:       fs.appendFileSync(perfFile, JSON.stringify(obj) + "\n", "utf-8");
   18:     } catch (_) {}
   19:   };
   20: 
   21:   return {
   22:     event: async ({ event }) => {
   23:       try {
   24:         const id = event?.properties?.sessionID;
   25:         if (!id) return;
   26:         if (event?.type === "session.created") {
   27:           sessions.set(id, Date.now());
   28:         } else if (event?.type === "session.idle") {
   29:           const start = sessions.get(id);
   30:           if (start !== undefined) {
   31:             const duration_ms = Date.now() - start;
   32:             const score = Math.max(0, 100 - Math.round(duration_ms / 60000));
   33:             writeJsonl({
   34:               ts: new Date().toISOString(),
   35:               session_id: id,
   36:               duration_ms,
   37:               score,
   38:             });
   39:             sessions.delete(id);
   40:           }
   41:         }
   42:       } catch (_) {}
   43:     },
   44: 
   45:     "tool.execute.after": async (input, _output) => {
   46:       try {
   47:         if (input?.tool === "task") {
   48:           writeJsonl({
   49:             ts: new Date().toISOString(),
   50:             type: "delegation",
   51:             tool: "task",
   52:           });
   53:         }
   54:       } catch (_) {}
   55:     },
   56:   };
   57: };
```

### `api/main.py` lines 1-9

```python
    1: from fastapi import FastAPI
    2: from fastapi.responses import JSONResponse
    3: 
    4: app = FastAPI(title="Health Check API")
    5: 
    6: 
    7: @app.get("/health")
    8: def health_check():
    9:     return JSONResponse(content={"status": "ok"})
```

### `api/requirements.txt` lines 1-2

```text
    1: fastapi>=0.115.0
    2: uvicorn[standard]>=0.30.0
```

### `.agents/templates/project/project.json` lines 1-9

```json
    1: {
    2:   "name": "{name}",
    3:   "type": "{type}",
    4:   "priority": "normal",
    5:   "agents": [],
    6:   "created_at": "{created_at}",
    7:   "status": "active",
    8:   "description": ""
    9: }
```

### `.agents/templates/project/queue.json` lines 1-3

```json
    1: {
    2:   "tasks": []
    3: }
```

## Начало каждого SKILL.md (для проверки discovery format)

### .agents/skills/1c-bsl-validate/SKILL.md
```markdown
# 1C:Enterprise — Проверка вызовов общих модулей BSL

## Описание

Проверка вызовов общих модулей в BSL по выгрузке конфигурации: существует ли модуль и экспортный ли у него метод. Работает без EDT, без платформы и без базы — по индексу от 1c-config-index. Ловит ошибки «переименовали метод, а вызовы в других модулях не обновили» до запуска.

## Когда использовать

- Переименовали метод или сняли `Экспорт` — нужно найти все вызовы
- Проверка BSL-кода перед коммитом
```

### .agents/skills/1c-bsp-api/SKILL.md
```markdown
# 1C:Enterprise — Справочник API БСП

## Описание

Офлайн-справочник по программному интерфейсу Библиотеки стандартных подсистем (БСП) 1С: 2624 метода в 284 модулях, 71 подсистема, версии 3.1.11 и 3.2.1. Позволяет проверить вызов метода БСП перед написанием кода. **НЕ** для API самой платформы (см. 1c-platform-docs) и **НЕ** для прикладных конфигураций (ERP, ЗУП, БП).

## Когда использовать

- Пишешь код на конфигурации с БСП и нужно узнать имя модуля или метода
- Нужна сигнатура метода, его контекст выполнения (сервер/клиент)
```

### .agents/skills/1c-config-index/SKILL.md
```markdown
# 1C:Enterprise — Индекс XML-выгрузки конфигурации

## Описание

Один проход по XML-выгрузке конфигурации 1С → один JSON. Индекс отвечает на вопрос «что вообще есть в этой конфигурации и из чего оно состоит»: объекты, реквизиты, ТЧ, измерения, ресурсы регистров, экспортные методы общих модулей. Работает без EDT, без платформы и без запущенной базы — только файлы выгрузки.

## Когда использовать

- Нужно проверить объект против остальной конфигурации
- Нужен список всех объектов/модулей/методов конфигурации
```

### .agents/skills/1c-config-router/SKILL.md
```markdown
# 1C:Enterprise — Маршрутизатор задач по конфигурации

## Описание

Мета-скилл: определяет какой workflow или отдельный скилл использовать для задачи пользователя. Таблица маршрутизации по всем 1С-скиллам.

## Когда использовать

- Не знаешь, какой скилл использовать для задачи
- Задача комплексная и требует цепочки операций
```

### .agents/skills/1c-dev/SKILL.md
```markdown


---
Ответь только: `Принято 13/15`. Жди следующую часть.
