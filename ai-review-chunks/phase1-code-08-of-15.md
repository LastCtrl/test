# PHASE1 PART 8/15

  336:     $nextTask | ConvertTo-Json -Depth 10 -Compress
  337: }
  338: 
  339: # --------------------------------------------------
  340: # -Complete: Mark task as done, release agent if assigned
  341: # --------------------------------------------------
  342: function Complete-Task {
  343:     param(
  344:         [string]$ProjectName,
  345:         [string]$TaskId
  346:     )
  347: 
  348:     $queue = Load-Queue -ProjectName $ProjectName
  349:     if (-not $queue) { exit 1 }
  350: 
  351:     $found = $false
  352:     foreach ($t in $queue.tasks) {
  353:         if ($t.id -eq $TaskId) {
  354:             $t.status = "done"
  355:             $t.completed_at = Get-Now
  356: 
  357:             # Release agent if one was assigned
  358:             if ($t.assigned_agent) {
  359:                 $agentRegistryPath = Join-Path $scriptDir "agent-registry.ps1"
  360:                 if (Test-Path $agentRegistryPath) {
  361:                     try {
  362:                         & $agentRegistryPath -Release -Agent $t.assigned_agent
  363:                     } catch {
  364:                         Write-Warning "Failed to release agent '$($t.assigned_agent)': $_"
  365:                     }
  366:                 } else {
  367:                     Write-Warning "agent-registry.ps1 not found at $agentRegistryPath, skipping agent release"
  368:                 }
  369:             }
  370: 
  371:             $found = $true
  372:             break
  373:         }
  374:     }
  375: 
  376:     if (-not $found) {
  377:         Write-Error "Task '$TaskId' not found in project '$ProjectName'"
  378:         exit 1
  379:     }
  380: 
  381:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  382:         Write-Error "Failed to save queue after completing task"
  383:         exit 1
  384:     }
  385: 
  386:     Write-Output "Task '$TaskId' marked as done in project '$ProjectName'"
  387: }
  388: 
  389: # --------------------------------------------------
  390: # -Dead: Mark task as dead with reason
  391: # --------------------------------------------------
  392: function Dead-Task {
  393:     param(
  394:         [string]$ProjectName,
  395:         [string]$TaskId,
  396:         [string]$TaskReason
  397:     )
  398: 
  399:     $queue = Load-Queue -ProjectName $ProjectName
  400:     if (-not $queue) { exit 1 }
  401: 
  402:     $found = $false
  403:     foreach ($t in $queue.tasks) {
  404:         if ($t.id -eq $TaskId) {
  405:             $t.status = "dead"
  406:             $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value $TaskReason -Force
  407:             $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
  408:             $found = $true
  409:             break
  410:         }
  411:     }
  412: 
  413:     if (-not $found) {
  414:         Write-Error "Task '$TaskId' not found in project '$ProjectName'"
  415:         exit 1
  416:     }
  417: 
  418:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  419:         Write-Error "Failed to save queue after marking task dead"
  420:         exit 1
  421:     }
  422: 
  423:     Write-Output "Task '$TaskId' marked as dead in project '$ProjectName' (reason: $TaskReason)"
  424: }
```

### `.agents/scripts/project-queue.ps1` lines 458-600

```powershell
  458: # -StaleCheck: Find in_progress tasks older than 15 min
  459: # retries < 2 -> retries++, status = queued, started_at = null
  460: # retries >= 2 -> status = dead
  461: # --------------------------------------------------
  462: function Invoke-StaleCheck {
  463:     param([string]$ProjectName)
  464: 
  465:     $queue = Load-Queue -ProjectName $ProjectName
  466:     if (-not $queue) { exit 1 }
  467: 
  468:     $now = Get-Date
  469:     $staleThreshold = New-TimeSpan -Minutes 15
  470:     $changed = 0
  471: 
  472:     foreach ($t in $queue.tasks) {
  473:         if ($t.status -ne "in_progress") { continue }
  474:         if (-not $t.started_at) { continue }
  475: 
  476:         try {
  477:             $startedAt = [DateTime]::Parse($t.started_at)
  478:         } catch {
  479:             continue
  480:         }
  481: 
  482:         $elapsed = $now - $startedAt
  483:         if ($elapsed -gt $staleThreshold) {
  484:             $retries = [int]$t.retries
  485: 
  486:             if ($retries -ge 2) {
  487:                 # Max retries reached -> dead
  488:                 $t.status = "dead"
  489:                 $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value "Stale: exceeded max retries (2) after 15min timeout" -Force
  490:                 $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
  491:                 Write-Output "Task '$($t.id)' marked dead (max retries reached)"
  492:             } else {
  493:                 # Retry: back to queued
  494:                 $t.retries = $retries + 1
  495:                 $t.status = "queued"
  496:                 $t.started_at = $null
  497:                 Write-Output "Task '$($t.id)' stale (>15min), retries=$($t.retries), moved back to queue"
  498:             }
  499:             $changed++
  500:         }
  501:     }
  502: 
  503:     if ($changed -eq 0) {
  504:         Write-Output "No stale tasks found in project '$ProjectName'"
  505:         return
  506:     }
  507: 
  508:     if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
  509:         Write-Error "Failed to save queue after stale check"
  510:         exit 1
  511:     }
  512: 
  513:     Write-Output "Stale check complete: $changed task(s) processed in project '$ProjectName'"
  514: }
  515: 
  516: # --------------------------------------------------
  517: # Main dispatch
  518: # --------------------------------------------------
  519: 
  520: if ($Add) {
  521:     if (-not $Project -or -not $Title) {
  522:         Write-Error "Add requires -Project and -Title parameters"
  523:         exit 1
  524:     }
  525:     if (-not (Test-ValidPriority $Priority)) {
  526:         Write-Error "Invalid priority '$Priority'. Must be one of: critical, high, normal, low"
  527:         exit 1
  528:     }
  529:     Add-Task -ProjectName $Project -TaskTitle $Title -TaskPriority $Priority -TaskAgent $Agent
  530:     exit 0
  531: }
  532: 
  533: if ($List) {
  534:     if (-not $Project) {
  535:         Write-Error "List requires -Project parameter"
  536:         exit 1
  537:     }
  538:     List-Tasks -ProjectName $Project -FilterStatus $Status
  539:     exit 0
  540: }
  541: 
  542: if ($Next) {
  543:     if (-not $Project) {
  544:         Write-Error "Next requires -Project parameter"
  545:         exit 1
  546:     }
  547:     Get-NextTask -ProjectName $Project
  548:     exit 0
  549: }
  550: 
  551: if ($Complete) {
  552:     if (-not $Project -or -not $Task) {
  553:         Write-Error "Complete requires -Project and -Task parameters"
  554:         exit 1
  555:     }
  556:     Complete-Task -ProjectName $Project -TaskId $Task
  557:     exit 0
  558: }
  559: 
  560: if ($Dead) {
  561:     if (-not $Project -or -not $Task) {
  562:         Write-Error "Dead requires -Project and -Task parameters"
  563:         exit 1
  564:     }
  565:     if (-not $Reason) {
  566:         Write-Error "Dead requires -Reason parameter"
  567:         exit 1
  568:     }
  569:     Dead-Task -ProjectName $Project -TaskId $Task -TaskReason $Reason
  570:     exit 0
  571: }
  572: 
  573: if ($Stats) {
  574:     if (-not $Project) {
  575:         Write-Error "Stats requires -Project parameter"
  576:         exit 1
  577:     }
  578:     Show-Stats -ProjectName $Project
  579:     exit 0
  580: }
  581: 
  582: if ($StaleCheck) {
  583:     if (-not $Project) {
  584:         Write-Error "StaleCheck requires -Project parameter"
  585:         exit 1
  586:     }
  587:     Invoke-StaleCheck -ProjectName $Project
  588:     exit 0
  589: }
  590: 
  591: # Default: show usage
  592: Write-Output "Usage:"
  593: Write-Output "  project-queue.ps1 -Add -Project <name> -Title ""<task>"" [-Priority critical|high|normal|low] [-Agent <name>]"
  594: Write-Output "  project-queue.ps1 -List -Project <name> [-Status queued|assigned|in_progress|done|dead]"
  595: Write-Output "  project-queue.ps1 -Next -Project <name>"
  596: Write-Output "  project-queue.ps1 -Complete -Project <name> -Task <id>"
  597: Write-Output "  project-queue.ps1 -Dead -Project <name> -Task <id> -Reason ""<why>"""
  598: Write-Output "  project-queue.ps1 -Stats -Project <name>"
  599: Write-Output "  project-queue.ps1 -StaleCheck -Project <name>"
  600: exit 1
```

### `.agents/scripts/inbox-poller.ps1` lines 1-357

```powershell
    1: ﻿# Inbox Poller for agent-hq — auto-launches inbox workers
    2: # Monitors .memory\inbox\{agent}\*.json and processes messages via opencode
    3: 
    4: param(
    5:     [switch]$Once,
    6:     [int]$IntervalSeconds = 30,
    7:     [switch]$DryRun
    8: )
    9: 
   10: $Base = "D:\Тест\agent-hq"
   11: $Memory = Join-Path $Base ".memory"
   12: $Inbox = Join-Path $Memory "inbox"
   13: $Outbox = Join-Path $Memory "outbox"
   14: $Archive = Join-Path $Memory "archive"
   15: $DeadLetter = Join-Path $Memory "dead-letter"
   16: $Traces = Join-Path $Memory "traces"
   17: $TasksDir = Join-Path $Base ".agents\tasks"
   18: 
   19: # --- Global constants (DRY: magic numbers & encoding) ---
   20: $script:Utf8NoBom = [System.Text.Encoding]::GetEncoding(65001)
   21: $maxResponseLength = 4000
   22: 
   23: # Ensure required directories exist
   24: @($Inbox, $Outbox, $Archive, $DeadLetter, $Traces, $TasksDir) | ForEach-Object {
   25:     if (-not (Test-Path $_)) {
   26:         New-Item -ItemType Directory -Path $_ -Force | Out-Null
   27:     }
   28: }
   29: 
   30: # Logging function: Write-Host with timestamp + append to .memory\traces\poller.log
   31: function Write-Log {
   32:     param($msg)
   33:     try {
   34:         $date = Get-Date -Format "HH:mm:ss"
   35:         $logLine = "$date $msg"
   36:         Write-Host $logLine
   37:         $logPath = Join-Path $Traces "poller.log"
   38:         [System.IO.File]::AppendAllText($logPath, ($logLine + "`n"), $script:Utf8NoBom)
   39:     } catch {
   40:         # Fallback: if file logging fails, at least Write-Host already worked above
   41:         Write-Host "$(Get-Date -Format 'HH:mm:ss') [LOG-ERROR] Failed to write log: $($_.Exception.Message)"
   42:     }
   43: }
   44: 
   45: # Global mutex to prevent concurrent execution
   46: $mutexName = "agent-hq-poller-mutex"
   47: $mutex = New-Object System.Threading.Mutex($false, $mutexName)
   48: $bCreated = $mutex.WaitOne(0)
   49: if (-not $bCreated) {
   50:     Write-Log "❌ Another instance is already running. Exit 1."
   51:     exit 1
   52: }
   53: 
   54: # Guard: check opencode in PATH
   55: if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
   56:     Write-Log "❌ opencode not found in PATH. Install opencode or add to PATH. Exit 1."
   57:     exit 1
   58: }
   59: 
   60: # Syntax check using PSParser
   61: $scriptPath = $MyInvocation.MyCommand.Definition
   62: try {
   63:     $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $scriptPath), [ref]$null) | Out-Null
   64:     Write-Log "✅ Syntax check passed (PSParser)"
   65: } catch {
   66:     Write-Log "❌ Syntax check failed (PSParser). Exit 1."
   67:     exit 1
   68: }
   69: 
   70: # --- DRY: Save TZ copy BEFORE the main loop (was dead code after infinite loop) ---
   71: $tzCopyPath = (Join-Path $TasksDir "task-inbox-poller.txt")
   72: if (-not (Test-Path $tzCopyPath)) {
   73:     Write-Log "📄 Saving TZ copy to: $tzCopyPath"
   74:     try {
   75:         $scriptContent = Get-Content -Path $scriptPath -ErrorAction Stop
   76:         [System.IO.File]::WriteAllText($tzCopyPath, ($scriptContent -join "`n"), $script:Utf8NoBom)
   77:         Write-Log "✅ TZ copy saved successfully"
   78:     } catch {
   79:         Write-Log "⚠️ Failed to save TZ copy: $($_.Exception.Message)"
   80:     }
   81: }
   82: 
   83: # Guard: empty payload → immediately dead-letter
   84: function Check-Payload {
   85:     param($msg)
   86:     if (-not $msg.payload -or $msg.payload -eq "" -or $msg.payload -eq $null) {
   87:         return $true
   88:     }
   89:     return $false
   90: }
   91: 
   92: # Format date helper: yyyy-MM-ddTHH:mm:ss
   93: function Format-DateTime {
   94:     return ("{0:yyyy-MM-ddTHH:mm:ss}" -f (Get-Date))
   95: }
   96: 
   97: # --- DRY: Dead-letter creation extracted from two copy-pasted blocks ---
   98: function Send-DeadLetter {
   99:     param(
  100:         [string]$messageId,
  101:         [string]$from,
  102:         [string]$targetAgent,
  103:         [string]$priority,
  104:         [string]$payload,
  105:         [string]$startedAt,
  106:         [string]$response,
  107:         [string]$filePath
  108:     )
  109:     $dlFinishedAt = Format-DateTime
  110:     $dlMsg = @{
  111:         id = $messageId
  112:         from = $from
  113:         to = $targetAgent
  114:         type = "failed"
  115:         priority = $priority
  116:         payload = $payload
  117:         status = "failed"
  118:         startedAt = $startedAt
  119:         finishedAt = $dlFinishedAt
  120:         response = $response
  121:     }
  122:     $jsonDL = $dlMsg | ConvertTo-Json -Depth 4
  123:     [System.IO.File]::WriteAllText((Join-Path $DeadLetter "$($messageId).json"), $jsonDL, $script:Utf8NoBom)
  124: 
  125:     # Remove original inbox file
  126:     try {
  127:         Remove-Item $filePath -Force
  128:     } catch {
  129:         Write-Log "⚠️ Failed to remove inbox file during dead-letter: $($_.Exception.Message)"
  130:     }
  131:     Write-Log "📂 Moved to dead-letter: $messageId"
  132: }
  133: 
  134: # --- DRY: Success handler extracted from two copy-pasted blocks ---
  135: function Complete-InboxFile {
  136:     param(
  137:         [string]$messageId,
  138:         [string]$from,
  139:         [string]$targetAgent,
  140:         [string]$priority,
  141:         [string]$payload,
  142:         [string]$startedAt,
  143:         [string]$response,
  144:         [string]$filePath,
  145:         [string]$fullFileName
  146:     )
  147:     # Truncate overly long responses
  148:     if ($response.Length -gt $maxResponseLength) {
  149:         $response = $response.Substring(0, $maxResponseLength)
  150:     }
  151: 
  152:     $outboxMsg = @{
  153:         id = $messageId
  154:         from = $from
  155:         to = $targetAgent
  156:         type = "result"
  157:         priority = $priority
  158:         payload = $payload
  159:         status = "done"
  160:         startedAt = $startedAt
  161:         finishedAt = Format-DateTime
  162:         response = $response
  163:     }
  164: 
  165:     $jsonOut = $outboxMsg | ConvertTo-Json -Depth 4
  166:     [System.IO.File]::WriteAllText((Join-Path $Outbox "$($messageId).json"), $jsonOut, $script:Utf8NoBom)
  167: 
  168:     # Move original inbox file to archive: {agent}-{original_name}
  169:     $archiveName = "$($targetAgent)-$($fullFileName)"
  170:     $archivePath = Join-Path $Archive $archiveName
  171:     try {
  172:         Move-Item $filePath $archivePath -Force
  173:     } catch {
  174:         Write-Log "⚠️ Failed to move to archive: $archiveName — $($_.Exception.Message)"
  175:     }
  176:     Write-Log "✅ Done: $messageId -> archived by $targetAgent"
  177: }
  178: 
  179: # Process a single inbox file
  180: function Process-InboxFile {
  181:     param($filePath, $agentName)
  182: 
  183:     $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
  184:     $fullFileName = [System.IO.Path]::GetFileName($filePath)
  185: 
  186:     try {
  187:         $content = Get-Content $filePath -Encoding UTF8
  188:         $msg = $content | ConvertFrom-Json -ErrorAction Stop
  189:     } catch {
  190:         Write-Log "❌ Failed to parse JSON: $($fileName)"
  191:         # Move to dead-letter
  192:         $dest = Join-Path $DeadLetter "$($fileName).json"
  193:         try {
  194:             Move-Item $filePath $dest -Force
  195:         } catch {
  196:             Write-Log "⚠️ Failed to move parse-error file to dead-letter: $($_.Exception.Message)"
  197:         }
  198:         Write-Log "⚠️ Moved to dead-letter due to parse error: $fileName"
  199:         return
  200:     }
  201: 
  202:     # Extract message fields with safe defaults (BUG-001: -or returns Boolean, not value)
  203:     if ($msg.id) { $messageId = $msg.id } else { $messageId = $fileName }
  204:     if ($msg.from) { $from = $msg.from } else { $from = "" }
  205:     if ($msg.to) { $to = $msg.to } else { $to = "" }
  206:     if ($msg.type) { $type = $msg.type } else { $type = "" }
  207:     if ($msg.priority) { $priority = $msg.priority } else { $priority = "normal" }
  208:     if ($msg.payload) { $payload = $msg.payload } else { $payload = "" }
  209:     if ($msg.created) { $created = $msg.created } else { $created = Format-DateTime }
  210: 
  211:     # Determine target agent: field `to`, otherwise folder name
  212:     if ($to -and $to -ne "") {
  213:         $targetAgent = $to
  214:     } else {


---
Ответь только: `Принято 8/15`. Жди следующую часть.
