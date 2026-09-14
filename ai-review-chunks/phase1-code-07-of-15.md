# PHASE1 PART 7/15

  456:     }
  457: 
  458:     if ($candidates.Count -eq 0) {
  459:         [Console]::Error.WriteLine("NO_FREE_AGENT: No free agent with specializations: $($requiredSps -join ', ') for project '$ProjectName'")
  460:         exit 2
  461:     }
  462: 
  463:     # Sort by composite score:
  464:     # same_project=0 better; matchCount higher better; daily_load lower better; rating higher better
  465:     # Composite formula (lower = better):
  466:     #   sameProj*1000000 - matchCount*10000 + dailyLoad*100 - rating*10
  467:     $scored = $candidates | ForEach-Object {
  468:         $score = [double]$_.SameProj * 1000000 - [double]$_.MatchCount * 10000 + [double]$_.DailyLoad * 100 - [double]$_.Rating * 10
  469:         [PSCustomObject]@{
  470:             Name      = $_.Name
  471:             Score     = $score
  472:             SameProj  = $_.SameProj
  473:             MatchCount = $_.MatchCount
  474:             DailyLoad = $_.DailyLoad
  475:             Rating    = $_.Rating
  476:         }
  477:     }
  478:     $sorted = $scored | Sort-Object Score
  479: 
  480:     $best = $sorted[0]
  481:     $agentName = $best.Name
  482: 
  483:     # Double-check agent is still free
  484:     $agent = $registry.agents.$agentName
  485:     if ($agent.status -ne "free") {
  486:         Write-Error "Agent '$agentName' is no longer free (race condition)"
  487:         exit 2
  488:     }
  489: 
  490:     # Reserve
  491:     $agent.status = "busy"
  492:     $agent.current_project = $ProjectName
  493:     $agent.current_task = "$ProjectName-acquire"
  494:     $agent.last_assignment = "$ProjectName-acquire"
  495:     $agent.daily_load++
  496: 
  497:     if (-not (Save-Registry $registry)) {
  498:         # Rollback не нужен: Save-Registry уже восстановил файл из .bak.
  499:         # In-memory откат $agent бессмысленен — объект не сохраняется.
  500:         Write-Error "Failed to save registry after acquire, rolled back from backup"
  501:         exit 1
  502:     }
  503: 
  504:     Write-Output "$agentName"
  505: }
  506: 
  507: # --------------------------------------------------
  508: # Main dispatch
  509: # --------------------------------------------------
  510: 
  511: if ($Init) {
  512:     Init-Registry
  513:     exit 0
  514: }
  515: 
  516: if ($List) {
  517:     List-Agents -FilterStatus $Status
  518:     exit 0
  519: }
  520: 
  521: if ($Reserve) {
  522:     if (-not $Agent -or -not $Project -or -not $Task) {
  523:         Write-Error "Reserve requires -Agent, -Project, and -Task parameters"
  524:         exit 1
  525:     }
  526:     Reserve-Agent -AgentName $Agent -ProjectName $Project -TaskId $Task
  527:     exit 0
  528: }
  529: 
  530: if ($Release) {
  531:     if (-not $Agent) {
  532:         Write-Error "Release requires -Agent parameter"
  533:         exit 1
  534:     }
  535:     Release-Agent -AgentName $Agent
  536:     exit 0
  537: }
  538: 
  539: if ($SetStatus) {
  540:     if (-not $Agent -or -not $Status) {
  541:         Write-Error "SetStatus requires -Agent and -Status parameters"
  542:         exit 1
  543:     }
  544:     Set-Status-Agent -AgentName $Agent -NewStatus $Status
  545:     exit 0
  546: }
  547: 
  548: if ($Acquire) {
  549:     if (-not $Specialization -or -not $Project) {
  550:         Write-Error "Acquire requires -Specialization and -Project parameters"
  551:         exit 1
  552:     }
  553:     Acquire-Agent -RequiredSpec $Specialization -ProjectName $Project
  554:     exit 0
  555: }
  556: 
  557: # Default: show usage
  558: Write-Output "Usage:"
  559: Write-Output "  agent-registry.ps1 -Init"
  560: Write-Output "  agent-registry.ps1 -List [-Status free|busy|error] [-Json]"
  561: Write-Output "  agent-registry.ps1 -Reserve -Agent <name> -Project <project> -Task <taskId>"
  562: Write-Output "  agent-registry.ps1 -Release -Agent <name>"
  563: Write-Output "  agent-registry.ps1 -SetStatus -Agent <name> -Status <free|busy|error>"
  564: Write-Output "  agent-registry.ps1 -Acquire -Specialization <sp1,sp2> -Project <name>"
  565: exit 1
```

### `.agents/scripts/project-queue.ps1` lines 1-215

```powershell
    1: # project-queue.ps1 - CLI task queue management for projects
    2: # US-013 Project Queue
    3: #
    4: # Parameters:
    5: #   -Add -Project <name> -Title "<task>" [-Priority critical|high|normal|low] [-Agent <name>]
    6: #   -List -Project <name> [-Status queued|assigned|in_progress|done|dead]
    7: #   -Next -Project <name>
    8: #   -Complete -Project <name> -Task <id>
    9: #   -Dead -Project <name> -Task <id> -Reason "<why>"
   10: #   -Stats -Project <name>
   11: #   -StaleCheck -Project <name>
   12: 
   13: param(
   14:     [switch]$Add,
   15:     [switch]$List,
   16:     [switch]$Next,
   17:     [switch]$Complete,
   18:     [switch]$Dead,
   19:     [switch]$Stats,
   20:     [switch]$StaleCheck,
   21:     [string]$Project,
   22:     [string]$Title,
   23:     [string]$Priority = "normal",
   24:     [string]$Agent,
   25:     [string]$Task,
   26:     [string]$Reason,
   27:     [string]$Status
   28: )
   29: 
   30: $ErrorActionPreference = "Stop"
   31: 
   32: # --------------------------------------------------
   33: # Path resolution: script is in .agents/scripts/
   34: # Project root is two levels up
   35: # --------------------------------------------------
   36: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   37: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   38: 
   39: $ProjectsRoot = Join-Path $projectRoot "projects"
   40: 
   41: # UTF-8 without BOM encoding
   42: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   43: 
   44: # Priority ordering: lower number = higher priority
   45: $PriorityOrder = @{
   46:     "critical" = 0
   47:     "high"     = 1
   48:     "normal"   = 2
   49:     "low"      = 3
   50: }
   51: 
   52: # --------------------------------------------------
   53: # Helper: Get queue.json path for project
   54: # --------------------------------------------------
   55: function Get-QueuePath {
   56:     param([string]$ProjectName)
   57:     # Security: whitelist project name + path traversal guard
   58:     if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
   59:         throw "Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-"
   60:     }
   61:     $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectsRoot "$ProjectName\queue.json"))
   62:     $rootFull = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\') + '\'
   63:     if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
   64:         throw "Path traversal detected: '$ProjectName' escapes projects root"
   65:     }
   66:     return $full
   67: }
   68: 
   69: # --------------------------------------------------
   70: # Helper: Get list of existing project names
   71: # --------------------------------------------------
   72: function Get-ExistingProjects {
   73:     $projects = @()
   74:     if (Test-Path $ProjectsRoot) {
   75:         $dirs = Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue
   76:         foreach ($d in $dirs) {
   77:             $projects += $d.Name
   78:         }
   79:     }
   80:     return $projects
   81: }
   82: 
   83: # --------------------------------------------------
   84: # Helper: Load queue JSON
   85: # Returns PSCustomObject with .tasks array
   86: # --------------------------------------------------
   87: function Load-Queue {
   88:     param([string]$ProjectName)
   89: 
   90:     $queuePath = Get-QueuePath -ProjectName $ProjectName
   91: 
   92:     if (-not (Test-Path $queuePath)) {
   93:         $existing = Get-ExistingProjects
   94:         if ($existing.Count -gt 0) {
   95:             Write-Error "Queue file not found: $queuePath`nExisting projects: $($existing -join ', ')"
   96:         } else {
   97:             Write-Error "Queue file not found: $queuePath`nNo projects found in $ProjectsRoot"
   98:         }
   99:         return $null
  100:     }
  101: 
  102:     try {
  103:         $content = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom)
  104:         $queue = $content | ConvertFrom-Json
  105:         # Ensure tasks array exists
  106:         if (-not $queue.tasks) {
  107:             $queue | Add-Member -MemberType NoteProperty -Name "tasks" -Value @() -Force
  108:         }
  109:         return $queue
  110:     } catch {
  111:         Write-Error "Failed to parse queue JSON for project '$ProjectName': $_"
  112:         return $null
  113:     }
  114: }
  115: 
  116: # --------------------------------------------------
  117: # Helper: Save queue JSON with backup and validation
  118: # Creates .bak before writing, writes UTF-8 no BOM,
  119: # validates after write, restores from .bak on failure.
  120: # --------------------------------------------------
  121: function Save-Queue {
  122:     param(
  123:         [string]$ProjectName,
  124:         [object]$data
  125:     )
  126: 
  127:     $queuePath = Get-QueuePath -ProjectName $ProjectName
  128: 
  129:     # 1. Create backup before writing
  130:     if (Test-Path $queuePath) {
  131:         $bakPath = $queuePath + ".bak"
  132:         try {
  133:             Copy-Item -Path $queuePath -Destination $bakPath -Force -ErrorAction Stop
  134:         } catch {
  135:             # Backup creation failure is not fatal; proceed to write
  136:         }
  137:     }
  138: 
  139:     # 2. Serialize to JSON
  140:     $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress
  141: 
  142:     # 3. Write with exclusive lock and UTF-8 no BOM
  143:     $handle = [System.IO.File]::Open($queuePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  144:     try {
  145:         $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
  146:         $writer.Write($jsonContent)
  147:         $writer.Flush()
  148:     } finally {
  149:         $handle.Close()
  150:     }
  151: 
  152:     # 4. Validate JSON after write
  153:     try {
  154:         $null = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom) | ConvertFrom-Json
  155:         return $true
  156:     } catch {
  157:         # 5. Restore from backup if JSON is invalid
  158:         # NOTE: Write-Warning (НЕ Write-Error) — при $ErrorActionPreference="Stop"
  159:         # Write-Error terminating-ошибка, которая прервёт скрипт раньше return $false
  160:         $bakPath = $queuePath + ".bak"
  161:         if (Test-Path $bakPath) {
  162:             try {
  163:                 Copy-Item -Path $bakPath -Destination $queuePath -Force -ErrorAction Stop
  164:             } catch {
  165:                 Write-Warning "Failed to restore queue from backup: $_"
  166:             }
  167:         }
  168:         Write-Warning "Queue JSON invalid after write, restored from backup"
  169:         return $false
  170:     }
  171: }
  172: 
  173: # --------------------------------------------------
  174: # Helper: Generate next task ID (tq-NNN)
  175: # --------------------------------------------------
  176: function Get-NextTaskId {
  177:     param([object]$Queue)
  178: 
  179:     $maxNum = 0
  180:     if ($Queue.tasks -and $Queue.tasks.Count -gt 0) {
  181:         foreach ($t in $Queue.tasks) {
  182:             if ($t.id -match "^tq-(\d+)$") {
  183:                 $num = [int]$Matches[1]
  184:                 if ($num -gt $maxNum) { $maxNum = $num }
  185:             }
  186:         }
  187:     }
  188:     $nextNum = $maxNum + 1
  189:     return "tq-{0:D3}" -f $nextNum
  190: }
  191: 
  192: # --------------------------------------------------
  193: # Helper: Get current ISO timestamp
  194: # --------------------------------------------------
  195: function Get-Now {
  196:     return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
  197: }
  198: 
  199: # --------------------------------------------------
  200: # Helper: Validate priority
  201: # --------------------------------------------------
  202: function Test-ValidPriority {
  203:     param([string]$P)
  204:     return ($P -eq "critical" -or $P -eq "high" -or $P -eq "normal" -or $P -eq "low")
  205: }
  206: 
  207: # --------------------------------------------------
  208: # Helper: Validate status
  209: # --------------------------------------------------
  210: function Test-ValidStatus {
  211:     param([string]$S)
  212:     return ($S -eq "queued" -or $S -eq "assigned" -or $S -eq "in_progress" -or $S -eq "done" -or $S -eq "dead")
  213: }
  214: 
  215: # --------------------------------------------------
```

### `.agents/scripts/project-queue.ps1` lines 216-424

```powershell
  216: # -Add: Add a task to the queue
  217: # --------------------------------------------------
  218: function Add-Task {
  219:     param(
  220:         [string]$ProjectName,
  221:         [string]$TaskTitle,
  222:         [string]$TaskPriority,
  223:         [string]$TaskAgent
  224:     )
  225: 
  226:     if (-not (Test-ValidPriority $TaskPriority)) {
  227:         Write-Error "Invalid priority '$TaskPriority'. Must be one of: critical, high, normal, low"
  228:         exit 1
  229:     }
  230: 
  231:     $queue = Load-Queue -ProjectName $ProjectName
  232:     if (-not $queue) { exit 1 }
  233: 
  234:     $taskId = Get-NextTaskId -Queue $queue
  235:     $now = Get-Now
  236: 
  237:     $taskObj = [PSCustomObject]@{
  238:         id              = $taskId
  239:         title           = $TaskTitle
  240:         priority        = $TaskPriority
  241:         status          = if ($TaskAgent) { "assigned" } else { "queued" }
  242:         assigned_agent  = $TaskAgent
  243:         created_at      = $now
  244:         started_at      = $null
  245:         completed_at    = $null
  246:         retries         = 0
  247:     }
  248: 
  249:     # Add to tasks array
  250:     $tasksList = @($queue.tasks)
  251:     $tasksList += $taskObj
  252:     $queue.tasks = $tasksList
  253: 
  254:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  255:         Write-Error "Failed to save queue after adding task"
  256:         exit 1
  257:     }
  258: 
  259:     Write-Output "Task '$taskId' added to project '$ProjectName' (priority: $TaskPriority, status: $($taskObj.status))"
  260: }
  261: 
  262: # --------------------------------------------------
  263: # -List: List tasks in the queue
  264: # --------------------------------------------------
  265: function List-Tasks {
  266:     param(
  267:         [string]$ProjectName,
  268:         [string]$FilterStatus
  269:     )
  270: 
  271:     if ($FilterStatus -and -not (Test-ValidStatus $FilterStatus)) {
  272:         Write-Error "Invalid status '$FilterStatus'. Must be one of: queued, assigned, in_progress, done, dead"
  273:         exit 1
  274:     }
  275: 
  276:     $queue = Load-Queue -ProjectName $ProjectName
  277:     if (-not $queue) { exit 1 }
  278: 
  279:     $tasks = @($queue.tasks)
  280: 
  281:     # Filter by status if specified
  282:     if ($FilterStatus) {
  283:         $tasks = $tasks | Where-Object { $_.status -eq $FilterStatus }
  284:     }
  285: 
  286:     if ($tasks.Count -eq 0) {
  287:         Write-Output "No tasks found$(if ($FilterStatus) { " with status '$FilterStatus'" }) in project '$ProjectName'"
  288:         return
  289:     }
  290: 
  291:     Write-Output "Id | Priority | Status | Agent | Title"
  292:     Write-Output "--- | --- | --- | --- | ---"
  293:     foreach ($t in $tasks) {
  294:         $agent = if ($t.assigned_agent) { $t.assigned_agent } else { "" }
  295:         Write-Output "$($t.id) | $($t.priority) | $($t.status) | $agent | $($t.title)"
  296:     }
  297: }
  298: 
  299: # --------------------------------------------------
  300: # -Next: Get next task by priority (critical > high > normal > low, FIFO within same priority)
  301: # Sets status to in_progress, sets started_at, outputs task JSON
  302: # --------------------------------------------------
  303: function Get-NextTask {
  304:     param([string]$ProjectName)
  305: 
  306:     $queue = Load-Queue -ProjectName $ProjectName
  307:     if (-not $queue) { exit 1 }
  308: 
  309:     # Filter to queued or assigned tasks only
  310:     $pending = @($queue.tasks | Where-Object { $_.status -eq "queued" -or $_.status -eq "assigned" })
  311: 
  312:     if ($pending.Count -eq 0) {
  313:         Write-Output "No pending tasks in project '$ProjectName'"
  314:         return
  315:     }
  316: 
  317:     # Sort by priority (lower number = higher priority), then by created_at (FIFO)
  318:     $sorted = $pending | Sort-Object {
  319:         $prio = $PriorityOrder[$_.priority]
  320:         if ($null -eq $prio) { 99 } else { $prio }
  321:     }, { $_.created_at }
  322: 
  323:     $nextTask = $sorted[0]
  324: 
  325:     # Update task in queue
  326:     $nextTask.status = "in_progress"
  327:     $nextTask.started_at = Get-Now
  328: 
  329:     # Save queue
  330:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  331:         Write-Error "Failed to save queue after taking next task"
  332:         exit 1
  333:     }
  334: 
  335:     # Output task as JSON


---
Ответь только: `Принято 7/15`. Жди следующую часть.
