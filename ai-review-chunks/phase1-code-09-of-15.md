# PHASE1 PART 9/15

  215:         $targetAgent = $agentName
  216:     }
  217: 
  218:     $startedAt = Format-DateTime
  219: 
  220:     # Guard: empty payload → immediately dead-letter
  221:     if (Check-Payload $msg) {
  222:         Write-Log "💀 Empty payload — immediately dead-letter: $($messageId)"
  223:         Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
  224:             -priority $priority -payload $payload -startedAt $startedAt `
  225:             -response "Empty payload — no task to process" -filePath $filePath
  226:         return
  227:     }
  228: 
  229:     # Generate prompt (FIX: hardcoded path replaced with Join-Path)
  230:     $contextBufferPath = Join-Path $Base "CONTEXT-BUFFER.md"
  231:     $prompt = "You received a task from agent-hq bus. Read the last 30 lines of $contextBufferPath (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. TASK: $payload"
  232: 
  233:     if ($DryRun) {
  234:         Write-Log "🔍 Dry run: would process with agent '$targetAgent'"
  235:         Write-Log "🔍 Dry run prompt: $prompt"
  236:         return
  237:     }
  238: 
  239:     # Call opencode run --agent <name> "<prompt>" with 15-min hard timeout
  240:     # (prevents a hung agent from blocking the whole poller cycle forever)
  241:     Write-Log "🚀 Calling opencode run for agent: $targetAgent (timeout: 900s)"
  242:     $result = $null
  243:     $job = Start-Job -ScriptBlock {
  244:         param($agent, $taskPrompt)
  245:         & opencode run --agent $agent $taskPrompt 2>&1
  246:     } -ArgumentList $targetAgent, $prompt
  247:     $completed = Wait-Job -Job $job -Timeout 900
  248:     if ($completed) {
  249:         $result = Receive-Job -Job $job
  250:         $exitCode = 0
  251:         if (-not $result) { $exitCode = 1 }
  252:     } else {
  253:         Stop-Job -Job $job -Force
  254:         Write-Log "⏱️ TIMEOUT 900s: agent '$targetAgent' hung — job killed"
  255:         $result = "TIMEOUT: agent '$targetAgent' did not respond in 900 seconds"
  256:         $exitCode = 124
  257:     }
  258:     Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  259: 
  260:     $finishedAt = Format-DateTime
  261: 
  262:     if ($exitCode -eq 0 -and $result) {
  263:         # Success — write to outbox and archive
  264:         Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
  265:             -priority $priority -payload $payload -startedAt $startedAt `
  266:             -response $result -filePath $filePath -fullFileName $fullFileName
  267:     } else {
  268:         # Failed — 1 retry (also with timeout)
  269:         Write-Log "❌ First attempt failed (exit code: $exitCode), retrying..."
  270:         $result2 = $null
  271:         $job2 = Start-Job -ScriptBlock {
  272:             param($agent, $taskPrompt)
  273:             & opencode run --agent $agent $taskPrompt 2>&1
  274:         } -ArgumentList $targetAgent, $prompt
  275:         $completed2 = Wait-Job -Job $job2 -Timeout 900
  276:         if ($completed2) {
  277:             $result2 = Receive-Job -Job $job2
  278:             $exitCode2 = 0
  279:             if (-not $result2) { $exitCode2 = 1 }
  280:         } else {
  281:             Stop-Job -Job $job2 -Force
  282:             Write-Log "⏱️ TIMEOUT 900s on retry: agent '$targetAgent' hung — job killed"
  283:             $result2 = "TIMEOUT: retry of agent '$targetAgent' did not respond in 900 seconds"
  284:             $exitCode2 = 124
  285:         }
  286:         Remove-Job -Job $job2 -Force -ErrorAction SilentlyContinue
  287: 
  288:         if ($exitCode2 -eq 0 -and $result2) {
  289:             Complete-InboxFile -messageId $messageId -from $from -targetAgent $targetAgent `
  290:                 -priority $priority -payload $payload -startedAt $startedAt `
  291:                 -response $result2 -filePath $filePath -fullFileName $fullFileName
  292:         } else {
  293:             # Failed after retry → dead-letter
  294:             Write-Log "❌ Failed after 2 attempts — dead-letter: $messageId"
  295:             Send-DeadLetter -messageId $messageId -from $from -targetAgent $targetAgent `
  296:                 -priority $priority -payload $payload -startedAt $startedAt `
  297:                 -response "Opencode failed after 2 attempts" -filePath $filePath
  298:         }
  299:     }
  300: }
  301: 
  302: # Main processing: scan .memory\inbox\{agent}\*.json
  303: function Process-Inbox {
  304:     $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }
  305: 
  306:     foreach ($agentDir in $agentDirs) {
  307:         $agentName = $agentDir.Name
  308:         $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }
  309: 
  310:         foreach ($jsonFile in $jsonFiles) {
  311:             Process-InboxFile -filePath $jsonFile.FullName -agentName $agentName
  312:         }
  313:     }
  314: }
  315: 
  316: # Dry run mode — show plan, nothing executes
  317: if ($DryRun) {
  318:     Write-Log "🔍 Dry run mode — showing plan only"
  319: 
  320:     $agentDirs = Get-ChildItem $Inbox -Directory | Where-Object { $_.Name -ne ".gitkeep" }
  321:     $foundMessages = $false
  322: 
  323:     foreach ($agentDir in $agentDirs) {
  324:         $agentName = $agentDir.Name
  325:         $jsonFiles = Get-ChildItem (Join-Path $agentDir.FullName "*.json") -Force | Where-Object { $_.Name -ne ".gitkeep" }
  326: 
  327:         foreach ($jsonFile in $jsonFiles) {
  328:             $foundMessages = $true
  329:             Write-Log "📄 Inbox file: $($jsonFile.Name) for agent: $agentName"
  330:         }
  331:     }
  332: 
  333:     if (-not $foundMessages) {
  334:         Write-Log "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
  335:         Write-Host "ℹ️ No messages in inbox — 0 messages to process (normal for empty inbox)"
  336:     }
  337: 
  338:     exit 0
  339: }
  340: 
  341: # Main execution with Mutex try/finally for safe release
  342: try {
  343:     if ($Once) {
  344:         Process-Inbox
  345:     } else {
  346:         # Interval loop — process repeatedly
  347:         while ($true) {
  348:             Process-Inbox
  349:             Write-Log "⏳ Sleeping for $IntervalSeconds seconds before next poll"
  350:             $null = Start-Sleep -Seconds $IntervalSeconds
  351:         }
  352:     }
  353: } finally {
  354:     # Always release mutex
  355:     $mutex.ReleaseMutex()
  356:     $mutex.Dispose()
  357: }
```

### `.agents/scripts/compliance-gate.ps1` lines 1-105

```powershell
    1: # compliance-gate.ps1 — Валидация enforcement Skills+MCP
    2: # Проверяет: self-report в CONTEXT-BUFFER.md содержит SKILLS_LOADED и MCP_USED
    3: 
    4: param(
    5:     [string]$ReportPath = "CONTEXT-BUFFER.md",
    6:     [int]$LookbackHours = 24,
    7:     [switch]$Strict
    8: )
    9: 
   10: $ErrorActionPreference = "Stop"
   11: 
   12: function Test-Compliance {
   13:     param($reportPath, $lookbackHours, $strict)
   14: 
   15:     if (-not (Test-Path $reportPath)) {
   16:         Write-Error "CONTEXT-BUFFER.md not found: $reportPath"
   17:         exit 1
   18:     }
   19: 
   20:     $content = Get-Content $reportPath -Raw
   21:     $cutoff = (Get-Date).AddHours(-$lookbackHours)
   22: 
   23:     # Найти все записи TYPE: update|resolved за последние N часов
   24:     # Формат: [YYYY-MM-DD] agent >> team-lead: ... SKILLS_LOADED: [...] MCP_USED: [...] COMPLIANCE: true
   25:     $pattern = '\[(?<date>\d{4}-\d{2}-\d{2})\]?\s*(?<time>\d{2}:\d{2}:\d{2})?\s*\]\s+(?<agent>\S+)\s+>>\s+team-lead:\s*TYPE:\s+(?<type>update|resolved).*?SKILLS_LOADED:\s*(?<skills>\[.*?\]).*?MCP_USED:\s*(?<mcp>\[.*?\]).*?COMPLIANCE:\s*(?<compliance>true|false)'
   26:     $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
   27: 
   28:     $pass = 0
   29:     $fail = 0
   30:     $violations = @()
   31: 
   32:     foreach ($match in $matches) {
   33:         # Parse date - use date part only since time might not be present
   34:         $dateStr = $match.Groups['date'].Value
   35:         $timeStr = $match.Groups['time'].Value
   36:         if ($timeStr) {
   37:             $time = [DateTime]::ParseExact("$dateStr $timeStr", "yyyy-MM-dd HH:mm:ss", $null)
   38:         } else {
   39:             $time = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
   40:         }
   41:         if ($time -lt $cutoff) { continue }
   42: 
   43:         $agent = $match.Groups['agent'].Value
   44:         $skills = $match.Groups['skills'].Value
   45:         $mcp = $match.Groups['mcp'].Value
   46:         $compliance = $match.Groups['compliance'].Value
   47: 
   48:         $skillsEmpty = $skills -eq '[]' -or [string]::IsNullOrWhiteSpace($skills)
   49:         $mcpEmpty = $mcp -eq '[]' -or [string]::IsNullOrWhiteSpace($mcp)
   50:         $compOk = $compliance -eq 'true'
   51: 
   52:         $ok = (-not $skillsEmpty) -and (-not $mcpEmpty) -and $compOk
   53: 
   54:         if ($ok) {
   55:             Write-Host "  [PASS] $agent -- skills: $skills, mcp: $mcp" -ForegroundColor Green
   56:             $pass++
   57:         } else {
   58:             $reason = @()
   59:             if ($skillsEmpty) { $reason += "SKILLS_LOADED empty" }
   60:             if ($mcpEmpty) { $reason += "MCP_USED empty" }
   61:             if (-not $compOk) { $reason += "COMPLIANCE != true" }
   62:             Write-Host "  [FAIL] $agent -- $($reason -join ', ')" -ForegroundColor Red
   63:             $fail++
   64:             $violations += @{
   65:                 agent = $agent
   66:                 time = $time
   67:                 reason = $reason -join '; '
   68:             }
   69:         }
   70:     }
   71: 
   72:     if ($pass -eq 0 -and $fail -eq 0) {
   73:         Write-Host "  [INFO] No records in last $lookbackHours hours" -ForegroundColor Yellow
   74:     }
   75: 
   76:     # Логирование нарушений
   77:     if ($violations.Count -gt 0) {
   78:         $logPath = Join-Path (Split-Path $reportPath -Parent) ".memory\tool-usage-violations.jsonl"
   79:         if (-not (Test-Path (Split-Path $logPath -Parent))) {
   80:             New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null
   81:         }
   82:         foreach ($v in $violations) {
   83:             $entry = @{
   84:                 date = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
   85:                 agent = $v.agent
   86:                 missing = $v.reason
   87:                 severity = "warning"
   88:             } | ConvertTo-Json -Depth 3
   89:             Add-Content -Path $logPath -Value $entry -Encoding UTF8
   90:         }
   91:     }
   92: 
   93:     Write-Host "`n=== Compliance Summary ===" -ForegroundColor Cyan
   94:     Write-Host "Passed: $pass"
   95:     Write-Host "Failed: $fail"
   96:     Write-Host "Total:  $($pass + $fail)"
   97: 
   98:     if ($fail -gt 0) {
   99:         if ($strict) { exit 1 }
  100:         return $false
  101:     }
  102:     return $true
  103: }
  104: 
  105: Test-Compliance -reportPath $ReportPath -lookbackHours $LookbackHours -strict $Strict
```

### `.agents/scripts/session-recovery.ps1` lines 1-185

```powershell
    1: # session-recovery.ps1 — Автовосстановление сессий при lock conflict
    2: # Запускается в фоне, мониторит .local/share/opencode/snapshot/ на ошибки
    3: 
    4: param(
    5:     [int]$CheckIntervalSec = 10,
    6:     [int]$MaxRetries = 3,
    7:     [switch]$Daemon
    8: )
    9: 
   10: $ErrorActionPreference = "Continue"
   11: 
   12: $SnapshotsDir = Join-Path $env:LOCALAPPDATA "opencode\snapshot"
   13: $LockFile = Join-Path $SnapshotsDir "recovery.lock"
   14: $LogFile = Join-Path $SnapshotsDir "recovery.log"
   15: 
   16: # Ensure directories exist
   17: if (-not (Test-Path $SnapshotsDir)) {
   18:     New-Item -ItemType Directory -Path $SnapshotsDir -Force | Out-Null
   19: }
   20: 
   21: function Write-Log {
   22:     param($msg)
   23:     $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
   24:     "$timestamp $msg" | Add-Content -Path $LogFile -Encoding UTF8
   25:     Write-Host "$timestamp $msg" -ForegroundColor Cyan
   26: }
   27: 
   28: function Test-LockConflict {
   29:     # Проверяем недавние ошибки в трейсах
   30:     $TracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
   31:     $TracesPath = Join-Path $TracesDir "traces.jsonl"
   32:     if (-not (Test-Path $TracesPath)) { return $false }
   33: 
   34:     $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-2)
   35:     $lines = Get-Content $TracesPath -Tail 20 -ErrorAction SilentlyContinue
   36:     foreach ($line in $lines) {
   37:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   38:         try {
   39:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   40:             if ($null -eq $obj) { continue }
   41:             if ($obj.type -eq "error" -and $obj.ts) {
   42:                 $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
   43:                 if ($ts -ge $cutoff -and $obj.message -match "Busy|FileSystem\.writeFile|exclude") {
   44:                     return $true
   45:                 }
   46:             }
   47:         } catch { continue }
   48:     }
   49:     return $false
   50: }
   51: 
   52: function Get-FreeTeamLeadCopy {
   53:     # Проверяем какие team-lead копии свободны (нет активной задачи в inbox)
   54:     $Root = "D:\Тест\agent-hq"
   55:     $InboxDir = Join-Path $Root ".memory\inbox"
   56:     $copies = @("team-lead", "team-lead-1", "team-lead-2", "team-lead-3")
   57:     foreach ($copy in $copies) {
   58:         $agentInbox = Join-Path $InboxDir $copy
   59:         if (Test-Path $agentInbox) {
   60:             $files = Get-ChildItem -Path $agentInbox -Filter "*.json" -File -ErrorAction SilentlyContinue
   61:             if ($files.Count -eq 0) {
   62:                 return $copy
   63:             }
   64:         } else {
   65:             return $copy
   66:         }
   67:     }
   68:     return $null
   69: }
   70: 
   71: function Delegate-To-Copy {
   72:     param($copyName, $originalTask)
   73: 
   74:     Write-Log "DELEGATE: Переделегирование на $copyName"
   75: 
   76:     # Создаём задачу в inbox копии
   77:     $InboxDir = Join-Path "D:\Тест\agent-hq\.memory\inbox" $copyName
   78:     if (-not (Test-Path $InboxDir)) {
   79:         New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null
   80:     }
   81: 
   82:     $taskId = "recovery-$(Get-Random -Minimum 10000 -Maximum 99999)"
   83:     $task = @{
   84:         id = $taskId
   85:         from = "session-recovery"
   86:         to = $copyName
   87:         type = "task"
   88:         priority = "high"
   89:         payload = $originalTask
   90:         created = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
   91:         recovery = $true
   92:         retry_count = 0
   93:     } | ConvertTo-Json -Depth 4
   94: 
   95:     $taskPath = Join-Path $InboxDir "$taskId.json"
   96:     [System.IO.File]::WriteAllText($taskPath, $task, (New-Object System.Text.UTF8Encoding($false)))
   97: 
   98:     Write-Log "DELEGATE: Задача $taskId создана в $copyName inbox"
   99: 
  100:     # Записываем в CONTEXT-BUFFER.md
  101:     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  102:     $tsNow = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
  103:     $entry = "[$tsNow] session-recovery -> ${copyName}:`nTYPE: update | PRIORITY: high`nCONTENT: Auto-recovery delegation from crashed session. Original task: $originalTask. Delegated to ${copyName}.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: [""context7: offline"", ""sequential-thinking: offline""]`nCOMPLIANCE: true`nSTATUS: resolved`n"
  104:     Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
  105: }
  106: 
  107: function Main-Loop {
  108:     Write-Log "START: session-recovery daemon started (interval: ${CheckIntervalSec}s)"
  109: 
  110:     while ($true) {
  111:         try {
  112:             if (Test-LockConflict) {
  113:                 Write-Log "DETECTED: Lock conflict detected"
  114: 
  115:                 $freeCopy = Get-FreeTeamLeadCopy
  116:                 if ($freeCopy) {
  117:                     Write-Log "FREE COPY: $freeCopy available"
  118: 
  119:                     # Читаем последнюю задачу из CONTEXT-BUFFER
  120:                     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  121:                     if (Test-Path $bufferPath) {
  122:                         $content = Get-Content $bufferPath -Raw
  123:                         # Ищем последнюю задачу пользователя
  124:                         $pattern = '\[(?<time>[\d\-T:]+)\]\s+(?<agent>\S+)\s+>>\s+team-lead:.*?CONTENT:\s*(?<content>.*?)(?=\[|\Z)'
  125:                         $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  126:                         if ($match.Success) {
  127:                             $taskContent = $match.Groups['content'].Value.Trim()
  128:                             Delegate-To-Copy -copyName $freeCopy -originalTask $taskContent


---
Ответь только: `Принято 9/15`. Жди следующую часть.
