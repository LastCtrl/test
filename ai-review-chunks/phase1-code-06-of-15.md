# PHASE1 PART 6/15

   70: ## Технологический стек (рекомендация)
   71: - **Frontend**: <стек>
   72: - **Backend**: <стек>
   73: - **Database**: <стек>
   74: - **Infrastructure**: <стек>
   75: 
   76: ## Риски и зависимости
   77: - Риск 1: <описание> → митигация: ...
   78: - Зависимость 1: <от чего/кого зависит>
   79: 
   80: ## Roadmap
   81: 1. **Sprint 1 (MVP)**: US-001, US-002 — <срок>
   82: 2. **Sprint 2**: US-003 — <срок>
   83: 3. **Sprint 3**: US-004 — <срок>
   84: ```
   85: 
   86: ### 3. Критерии хороших требований
   87: - User Story понятна без дополнительных вопросов
   88: - Acceptance Criteria проверяемы (можно написать тест)
   89: - Приоритеты реалистичны (MVP — минимум для запуска)
   90: - Стек обоснован (почему выбрали, а не альтернативу)
   91: 
   92: ### 4. Синхронизация с team-lead
   93: - Читай вывод team-lead в CONTEXT-BUFFER.md
   94: - Если team-lead задал вопросы через question tool — отвечай
   95: - Твои requirements → basis для delegation plan team-lead'а
   96: 
   97: ## Протокол ОТКАТА (обязателен)
   98: - Максимум 2 попытки. Откат при неудаче. Запиши blocker.
   99: 
  100: ## Правило СКИЛЛОВ (обязательно)
  101: - Подгружай нужные скиллы ПЕРЕД работой.
  102: 
  103: ## ИНСТРУМЕНТЫ MCP (обязательно применять)
  104: - context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.
  105: - sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.
  106: - hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.
  107: Если инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе.
```

### `.agents/scripts/agent-registry.ps1` lines 1-160

```powershell
    1: ﻿# agent-registry.ps1 - CLI management for agent-registry.json
    2: # US-012 Dynamic Agent Pool
    3: #
    4: # Parameters:
    5: #   -Init                              Regenerate registry from .opencode/agents/registry.json
    6: #   -List [-Status free|busy|error] [-Json]  List agents
    7: #   -Reserve -Agent <name> -Project <project> -Task <taskId>  Reserve an agent
    8: #   -Release -Agent <name>             Release an agent
    9: #   -SetStatus -Agent <name> -Status <free|busy|error>  Set status manually
   10: #   -Acquire -Specialization <sp1,sp2> -Project <name>  Auto-acquire best agent
   11: 
   12: param(
   13:     [switch]$Init,
   14:     [switch]$List,
   15:     [string]$Status,
   16:     [switch]$Json,
   17:     [switch]$Reserve,
   18:     [string]$Agent,
   19:     [string]$Project,
   20:     [string]$Task,
   21:     [switch]$Release,
   22:     [switch]$SetStatus,
   23:     [switch]$Acquire,
   24:     [string]$Specialization
   25: )
   26: 
   27: $ErrorActionPreference = "Stop"
   28: 
   29: # --------------------------------------------------
   30: # Path resolution: script is in .agents/scripts/
   31: # Project root is two levels up
   32: # --------------------------------------------------
   33: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   34: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   35: 
   36: $RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
   37: $BackupPath = $RegistryPath + ".bak"
   38: $RatingsPath = Join-Path $projectRoot ".memory\ratings.jsonl"
   39: $SourceRegistryPath = Join-Path $projectRoot ".opencode\agents\registry.json"
   40: 
   41: # UTF-8 without BOM encoding
   42: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   43: 
   44: # --------------------------------------------------
   45: # Helper: Load registry JSON
   46: # --------------------------------------------------
   47: function Load-Registry {
   48:     if (-not (Test-Path $RegistryPath)) {
   49:         Write-Error "Registry file not found: $RegistryPath"
   50:         return $null
   51:     }
   52:     try {
   53:         $content = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom)
   54:         $registry = $content | ConvertFrom-Json
   55:         return $registry
   56:     } catch {
   57:         Write-Error "Failed to parse registry JSON: $_"
   58:         return $null
   59:     }
   60: }
   61: 
   62: # --------------------------------------------------
   63: # Helper: Save registry JSON with backup and validation
   64: # Creates .bak before writing, writes UTF-8 no BOM,
   65: # validates after write, restores from .bak on failure.
   66: # Uses exclusive file handle during write.
   67: # --------------------------------------------------
   68: function Save-Registry {
   69:     param([object]$data)
   70: 
   71:     # 1. Create backup before writing
   72:     if (Test-Path $RegistryPath) {
   73:         try {
   74:             Copy-Item -Path $RegistryPath -Destination $BackupPath -Force -ErrorAction Stop
   75:         } catch {
   76:             # Backup creation failure is not fatal; proceed to write
   77:         }
   78:     }
   79: 
   80:     # 2. Serialize to JSON
   81:     $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress
   82: 
   83:     # 3. Write with exclusive lock (FileShare None) and UTF-8 no BOM
   84:     $handle = [System.IO.File]::Open($RegistryPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
   85:     try {
   86:         $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
   87:         $writer.Write($jsonContent)
   88:         $writer.Flush()
   89:     } finally {
   90:         $handle.Close()
   91:     }
   92: 
   93:     # 4. Validate JSON after write
   94:     try {
   95:         $null = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom) | ConvertFrom-Json
   96:         return $true
   97:     } catch {
   98:         # 5. Restore from backup if JSON is invalid
   99:         # NOTE: Write-Warning (НЕ Write-Error) — при $ErrorActionPreference="Stop"
  100:         # Write-Error terminating-ошибка, которая прервёт скрипт раньше return $false
  101:         if (Test-Path $BackupPath) {
  102:             try {
  103:                 Copy-Item -Path $BackupPath -Destination $RegistryPath -Force -ErrorAction Stop
  104:             } catch {
  105:                 Write-Warning "Failed to restore registry from backup: $_"
  106:             }
  107:         }
  108:         Write-Warning "Registry JSON invalid after write, restored from backup"
  109:         return $false
  110:     }
  111: }
  112: 
  113: # --------------------------------------------------
  114: # Helper: Read ratings from .memory/ratings.jsonl
  115: # Returns hashtable: agent_name -> average grade (double)
  116: # Each line is a JSON object with "agent" and "grade" fields
  117: # --------------------------------------------------
  118: function Get-AgentRatings {
  119:     $ratings = @{}
  120: 
  121:     if (-not (Test-Path $RatingsPath)) {
  122:         return $ratings
  123:     }
  124: 
  125:     try {
  126:         $content = [System.IO.File]::ReadAllText($RatingsPath, $utf8NoBom)
  127:         $lines = $content -split "`n" | Where-Object { $_.Trim() -ne "" }
  128: 
  129:         $agentGrades = @{}
  130: 
  131:         foreach ($line in $lines) {
  132:             try {
  133:                 $obj = $line | ConvertFrom-Json
  134:                 $agentName = $obj.agent
  135:                 $grade = [double]$obj.grade
  136: 
  137:                 if ($agentName) {
  138:                     if (-not $agentGrades.ContainsKey($agentName)) {
  139:                         $agentGrades[$agentName] = @()
  140:                     }
  141:                     $agentGrades[$agentName] += $grade
  142:                 }
  143:             } catch {
  144:                 # Skip malformed lines
  145:             }
  146:         }
  147: 
  148:         # Compute averages
  149:         foreach ($agentName in $agentGrades.Keys) {
  150:             $grades = $agentGrades[$agentName]
  151:             $sum = 0.0
  152:             foreach ($g in $grades) { $sum += $g }
  153:             $ratings[$agentName] = $sum / $grades.Count
  154:         }
  155:     } catch {
  156:         # File read error; return empty ratings
  157:     }
  158: 
  159:     return $ratings
  160: }
```

### `.agents/scripts/agent-registry.ps1` lines 198-268

```powershell
  198: # --------------------------------------------------
  199: # Reserve agent: free -> busy + project + task + last_assignment + daily_load++
  200: # --------------------------------------------------
  201: function Reserve-Agent {
  202:     param([string]$AgentName, [string]$ProjectName, [string]$TaskId)
  203: 
  204:     $registry = Load-Registry
  205:     if (-not $registry) {
  206:         Write-Error "Could not load registry"
  207:         exit 1
  208:     }
  209: 
  210:     if (-not $registry.agents.PSObject.Properties[$AgentName]) {
  211:         Write-Error "Agent '$AgentName' not found in registry"
  212:         exit 1
  213:     }
  214: 
  215:     $agent = $registry.agents.$AgentName
  216: 
  217:     if ($agent.status -ne "free") {
  218:         Write-Error "Agent '$AgentName' is not free (status: $($agent.status))"
  219:         exit 1
  220:     }
  221: 
  222:     $agent.status = "busy"
  223:     $agent.current_project = $ProjectName
  224:     $agent.current_task = $TaskId
  225:     $agent.last_assignment = "$ProjectName-$TaskId"
  226:     $agent.daily_load++
  227: 
  228:     if (-not (Save-Registry $registry)) {
  229:         # Rollback не нужен: Save-Registry уже восстановил файл из .bak.
  230:         # In-memory откат $agent бессмысленен — объект не сохраняется.
  231:         Write-Error "Failed to save registry, rolled back from backup"
  232:         exit 1
  233:     }
  234: 
  235:     Write-Output "Agent '$AgentName' reserved for project '$ProjectName', task '$TaskId'"
  236: }
  237: 
  238: # --------------------------------------------------
  239: # Release agent: sets free, cleans project/task
  240: # --------------------------------------------------
  241: function Release-Agent {
  242:     param([string]$AgentName)
  243: 
  244:     $registry = Load-Registry
  245:     if (-not $registry) {
  246:         exit 1
  247:     }
  248: 
  249:     if (-not $registry.agents.PSObject.Properties[$AgentName]) {
  250:         Write-Error "Agent '$AgentName' not found in registry"
  251:         exit 1
  252:     }
  253: 
  254:     $agent = $registry.agents.$AgentName
  255: 
  256:     $agent.status = "free"
  257:     $agent.current_project = $null
  258:     $agent.current_task = $null
  259:     $agent.last_assignment = $null
  260:     # daily_load not decremented (daily counter)
  261: 
  262:     if (-not (Save-Registry $registry)) {
  263:         Write-Error "Failed to save registry after release"
  264:         exit 1
  265:     }
  266: 
  267:     Write-Output "Agent '$AgentName' released, status set to free"
  268: }
```

### `.agents/scripts/agent-registry.ps1` lines 303-565

```powershell
  303: # Init: regenerate registry from .opencode/agents/registry.json
  304: # Preserves daily_load and last_assignment from existing registry
  305: # --------------------------------------------------
  306: function Init-Registry {
  307:     if (-not (Test-Path $SourceRegistryPath)) {
  308:         Write-Error "Source registry not found: $SourceRegistryPath"
  309:         exit 1
  310:     }
  311: 
  312:     $sourceContent = [System.IO.File]::ReadAllText($SourceRegistryPath, $utf8NoBom)
  313:     $sourceData = $sourceContent | ConvertFrom-Json
  314: 
  315:     # Load existing registry to preserve daily_load and last_assignment
  316:     $existingAgents = @{}
  317:     if (Test-Path $RegistryPath) {
  318:         $existingRegistry = Load-Registry
  319:         if ($existingRegistry -and $existingRegistry.agents) {
  320:             foreach ($name in $existingRegistry.agents.PSObject.Properties.Name) {
  321:                 $existingAgents[$name] = $existingRegistry.agents.$name
  322:             }
  323:         }
  324:     }
  325: 
  326:     $newAgents = @{}
  327: 
  328:     foreach ($name in $sourceData.agents.PSObject.Properties.Name) {
  329:         $sourceAgent = $sourceData.agents.$name
  330: 
  331:         # Build specialization: primary + secondary from source
  332:         $spec = @()
  333:         if ($sourceAgent.specialization) {
  334:             $primary = @()
  335:             $secondary = @()
  336:             if ($sourceAgent.specialization.primary) {
  337:                 $primary = @($sourceAgent.specialization.primary)
  338:             }
  339:             if ($sourceAgent.specialization.secondary) {
  340:                 $secondary = @($sourceAgent.specialization.secondary)
  341:             }
  342:             $spec = @($primary + $secondary)
  343:         }
  344: 
  345:         # Preserve daily_load and last_assignment from existing registry
  346:         $dailyLoad = 0
  347:         $lastAssgn = $null
  348:         if ($existingAgents.ContainsKey($name)) {
  349:             $existing = $existingAgents[$name]
  350:             if ($existing.daily_load -ne $null) {
  351:                 $dailyLoad = [int]$existing.daily_load
  352:             }
  353:             $lastAssgn = $existing.last_assignment
  354:         }
  355: 
  356:         $agentObj = [PSCustomObject]@{
  357:             name             = $name
  358:             role             = $sourceAgent.role
  359:             specialization   = $spec
  360:             status           = "free"
  361:             current_project  = $null
  362:             current_task     = $null
  363:             last_assignment  = $lastAssgn
  364:             daily_load       = $dailyLoad
  365:         }
  366: 
  367:         $newAgents[$name] = $agentObj
  368:     }
  369: 
  370:     $newRegistry = [PSCustomObject]@{ agents = $newAgents }
  371: 
  372:     if (-not (Save-Registry $newRegistry)) {
  373:         Write-Error "Failed to save initialized registry"
  374:         exit 1
  375:     }
  376: 
  377:     $count = $newAgents.Count
  378:     Write-Output "Registry initialized from source ($count agents), preserving daily_load and last_assignment"
  379: }
  380: 
  381: # --------------------------------------------------
  382: # Acquire agent: select best based on specialization algorithm
  383: # - Filters: free + specialization IN required
  384: # - Sorts: same_project first, daily_load asc, rating desc (higher is better)
  385: # - Reads rating from .memory/ratings.jsonl (average grade, default 5.0)
  386: # - Reserves best agent, outputs its name
  387: # - Exit 2 if no free agent matches
  388: # --------------------------------------------------
  389: function Acquire-Agent {
  390:     param([string]$RequiredSpec, [string]$ProjectName)
  391: 
  392:     $requiredSps = $RequiredSpec -split ',' | ForEach-Object { $_.Trim() }
  393:     $requiredSps = $requiredSps | Where-Object { $_ -ne "" }
  394: 
  395:     $registry = Load-Registry
  396:     if (-not $registry) {
  397:         Write-Error "Could not load registry"
  398:         exit 1
  399:     }
  400: 
  401:     # Load agent ratings
  402:     $ratings = Get-AgentRatings
  403: 
  404:     # Filter: free agents with at least one matching specialization
  405:     $candidates = @()
  406: 
  407:     foreach ($name in $registry.agents.PSObject.Properties.Name) {
  408:         $agent = $registry.agents.$name
  409: 
  410:         if ($agent.status -ne "free") { continue }
  411: 
  412:         # Check specialization match
  413:         $agentSps = @()
  414:         if ($agent.specialization) {
  415:             $agentSps = @($agent.specialization)
  416:         }
  417:         $hasMatch = $false
  418:         foreach ($req in $requiredSps) {
  419:             foreach ($sp in $agentSps) {
  420:                 if ($sp -eq $req) {
  421:                     $hasMatch = $true
  422:                     break
  423:                 }
  424:             }
  425:             if ($hasMatch) { break }
  426:         }
  427:         if (-not $hasMatch) { continue }
  428: 
  429:         # Count matching specializations (more matches = better fit)
  430:         $matchCount = 0
  431:         foreach ($req in $requiredSps) {
  432:             foreach ($sp in $agentSps) {
  433:                 if ($sp -eq $req) { $matchCount++; break }
  434:             }
  435:         }
  436: 
  437:         # same_project: 0 if agent has no current project or same project, 1 otherwise
  438:         $sameProjNum = 0
  439:         if ($agent.current_project -and $agent.current_project -ne $ProjectName) {
  440:             $sameProjNum = 1
  441:         }
  442: 
  443:         # Get rating (default 5.0)
  444:         $rating = 5.0
  445:         if ($ratings.ContainsKey($name)) {
  446:             $rating = $ratings[$name]
  447:         }
  448: 
  449:         $candidates += [PSCustomObject]@{
  450:             Name        = $name
  451:             SameProj    = $sameProjNum
  452:             MatchCount  = $matchCount
  453:             DailyLoad   = [int]$agent.daily_load
  454:             Rating      = $rating
  455:         }


---
Ответь только: `Принято 6/15`. Жди следующую часть.
