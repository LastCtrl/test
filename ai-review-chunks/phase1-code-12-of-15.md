# PHASE1 PART 12/15

  243:     $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -List -Status free 2>&1
  244:     $exitCode = $LASTEXITCODE
  245:     $f5Pass = ($exitCode -eq 0) -and ($result -match "free")
  246: }
  247: Test-Check "F5: agent-registry.ps1 -List -Status free exits 0, shows 'free'" $f5Pass
  248: 
  249: # F6: agent-registry.ps1 -Acquire -Specialization "nonexistent-xyz" -> exit 2
  250: $f6Pass = $false
  251: if (Test-Path $regScript) {
  252:     $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -Acquire -Specialization "nonexistent-xyz" -Project "test" 2>&1
  253:     $exitCode = $LASTEXITCODE
  254:     $f6Pass = ($exitCode -eq 2)
  255: }
  256: Test-Check "F6: agent-registry.ps1 -Acquire nonexistent spec exits 2" $f6Pass
  257: 
  258: # F7: project-queue.ps1 test on 1c-buh: -Add (critical) -> -Next (returns critical) -> -Complete (done) -> -List confirms -> cleanup to empty
  259: # Local-only: full cycle mutates projects/<name>/queue.json (gitignored runtime data), absent on CI.
  260: $queueScript = ".agents\scripts\project-queue.ps1"
  261: $f7Pass = $false
  262: $testProject = "1c-buh"
  263: if (-not $isCI -and (Test-Path $queueScript)) {
  264:     # Add a critical task
  265:     $addResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Add -Project $testProject -Title "Test critical task" -Priority critical 2>&1
  266:     $addExit = $LASTEXITCODE
  267:     if ($addExit -eq 0 -and $addResult -match "tq-(\d{3})") {
  268:         $taskId = $Matches[0]
  269:         # Get next task (should return our critical task)
  270:         $nextResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Next -Project $testProject 2>&1
  271:         $nextExit = $LASTEXITCODE
  272:         if ($nextExit -eq 0 -and $nextResult -match $taskId) {
  273:             # Complete the task
  274:             $completeResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Complete -Project $testProject -Task $taskId 2>&1
  275:             $completeExit = $LASTEXITCODE
  276:             if ($completeExit -eq 0) {
  277:                 # List to confirm done
  278:                 $listResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
  279:                 $listExit = $LASTEXITCODE
  280:                 if ($listExit -eq 0 -and $listResult -match "done") {
  281:                     # CLEANUP: Remove the test task by marking dead and removing, or just verify queue is clean
  282:                     # Actually, let's just verify the queue ends up with the task in done status
  283:                     # For idempotency, we'll mark it dead to remove from active queue
  284:                     $deadResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Dead -Project $testProject -Task $taskId -Reason "Test cleanup" 2>&1
  285:                     $deadExit = $LASTEXITCODE
  286:                     # Final list should show empty or only done/dead tasks
  287:                     $finalList = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
  288:                     $finalExit = $LASTEXITCODE
  289:                     # Check that queue is effectively clean (no queued/assigned/in_progress)
  290:                     $queueContent = Get-Content (Join-Path "projects" "$testProject\queue.json") -Raw -ErrorAction SilentlyContinue
  291:                     $queueObj = $queueContent | ConvertFrom-Json -ErrorAction SilentlyContinue
  292:                     $activeTasks = 0
  293:                     if ($queueObj -and $queueObj.tasks) {
  294:                         $activeTasks = ($queueObj.tasks | Where-Object { $_.status -in @("queued", "assigned", "in_progress") }).Count
  295:                     }
  296:                     $f7Pass = ($activeTasks -eq 0)
  297:                 }
  298:             }
  299:         }
  300:     }
  301: }
  302: Test-LocalCheck "F7: project-queue.ps1 full cycle (Add->Next->Complete->cleanup) on 1c-buh" $f7Pass
  303: 
  304: # F7-cleanup: убрать тестовый мусор из queue.json (задачи с тестовым title),
  305: # чтобы прогоны F7 не накапливали done/dead задачи. Идемпотентно: повторные
  306: # прогоны дают стабильный tasks count.
  307: if ($f7Pass -or (Test-Path (Join-Path "projects" "$testProject\queue.json"))) {
  308:     $cleanupQueuePath = Join-Path "projects" "$testProject\queue.json"
  309:     $cleanupRaw = [System.IO.File]::ReadAllText($cleanupQueuePath, [System.Text.UTF8Encoding]::new($false))
  310:     $cleanupObj = $null
  311:     try { $cleanupObj = $cleanupRaw | ConvertFrom-Json -ErrorAction Stop } catch { $cleanupObj = $null }
  312:     if ($cleanupObj -and $cleanupObj.tasks) {
  313:         $keepTasks = @($cleanupObj.tasks | Where-Object { $_.title -ne "Test critical task" })
  314:         $removedCount = $cleanupObj.tasks.Count - $keepTasks.Count
  315:         if ($removedCount -gt 0) {
  316:             $cleanupObj.tasks = $keepTasks
  317:             $newJson = $cleanupObj | ConvertTo-Json -Depth 10 -Compress
  318:             [System.IO.File]::WriteAllText($cleanupQueuePath, $newJson, [System.Text.UTF8Encoding]::new($false))
  319:             Write-Host "  F7-cleanup: removed $removedCount test task(s) from $testProject/queue.json" -ForegroundColor Gray
  320:         }
  321:     }
  322: }
  323: 
  324: # F8: agent-utilization.ps1 output contains "Utilization"; -Json outputs valid JSON
  325: $utilScript = ".agents\scripts\agent-utilization.ps1"
  326: $f8TextPass = $false
  327: $f8JsonPass = $false
  328: if (Test-Path $utilScript) {
  329:     $textResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript 2>&1
  330:     $textExit = $LASTEXITCODE
  331:     $f8TextPass = ($textExit -eq 0) -and ($textResult -match "Utilization")
  332:     
  333:     $jsonResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript -Json 2>&1
  334:     $jsonExit = $LASTEXITCODE
  335:     if ($jsonExit -eq 0) {
  336:         try {
  337:             $null = $jsonResult | ConvertFrom-Json -ErrorAction Stop
  338:             $f8JsonPass = $true
  339:         } catch {
  340:             $f8JsonPass = $false
  341:         }
  342:     }
  343: }
  344: Test-Check "F8: agent-utilization.ps1 shows 'Utilization' and -Json valid" ($f8TextPass -and $f8JsonPass)
  345: 
  346: # F9: opencode.json command.status.template mentions agent-utilization or "Agents & Utilization"
  347: $f9Pass = $false
  348: if (Test-Path "opencode.json") {
  349:     $ocContent = Get-Content "opencode.json" -Raw
  350:     $oc = $ocContent | ConvertFrom-Json
  351:     if ($oc.command.status.template) {
  352:         $template = $oc.command.status.template
  353:         $f9Pass = ($template -match "agent-utilization") -or ($template -match "Agents & Utilization")
  354:     }
  355: }
  356: Test-Check "F9: opencode.json status command mentions agent-utilization or 'Agents & Utilization'" $f9Pass
  357: 
  358: # F10: knowledge-index.md in root, "### PAT-" appears >= 6 times
  359: $kiPath = "knowledge-index.md"
  360: $f10Pass = $false
  361: if (Test-Path $kiPath) {
  362:     $kiContent = Get-Content $kiPath -Raw
  363:     $patCount = ($kiContent -split "### PAT-" | Measure-Object).Count - 1
  364:     $f10Pass = ($patCount -ge 6)
  365: }
  366: Test-Check "F10: knowledge-index.md has >= 6 '### PAT-' entries ($patCount found)" $f10Pass
  367: 
  368: # F11: .opencode/agents/prompts/team-lead.txt contains "DUAL-AGENT DELEGATION"
  369: $tlPromptPath = ".opencode\agents\prompts\team-lead.txt"
  370: $f11Pass = $false
  371: if (Test-Path $tlPromptPath) {
  372:     $tlContent = Get-Content $tlPromptPath -Raw
  373:     $f11Pass = $tlContent -match "DUAL-AGENT DELEGATION"
  374: }
  375: Test-Check "F11: team-lead.txt contains 'DUAL-AGENT DELEGATION'" $f11Pass
  376: 
  377: # Summary
  378: Write-Host ""
  379: Write-Host "=== Results ===" -ForegroundColor Cyan
  380: $summaryLine = "Passed: $pass / $total"
  381: if ($ciSkipped -gt 0) {
  382:     $summaryLine += " ($ciSkipped skipped: CI-only artifacts)"
  383: }
  384: Write-Host $summaryLine -ForegroundColor Green
  385: if ($fail -gt 0) {
  386:     Write-Host "Failed: $fail / $total" -ForegroundColor Red
  387: } else {
  388:     Write-Host "Failed: 0 / $total" -ForegroundColor Green
  389: }
  390: Write-Host ""
  391: if ($fail -eq 0) {
  392:     Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
  393: } else {
  394:     Write-Host "SOME CHECKS FAILED - review above" -ForegroundColor Yellow
  395: }
  396: if ($fail -gt 0) { exit 1 }
```

### `.agents/scripts/health-check.ps1` lines 1-148

```powershell
    1: param()
    2: 
    3: $ErrorActionPreference = "Continue"
    4: $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    5: $hasFail = $false
    6: 
    7: Write-Host "=== agent-hq Health Check ===" -ForegroundColor Cyan
    8: Write-Host "Root: $root" -ForegroundColor Gray
    9: Write-Host ""
   10: 
   11: # --- 1. Traces: type:error за последние 60 минут ---
   12: $tracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
   13: $tracesPath = Join-Path $tracesDir "traces.jsonl"
   14: if (Test-Path $tracesPath) {
   15:     $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
   16:     $errorCount = 0
   17:     $lines = Get-Content $tracesPath -ErrorAction SilentlyContinue
   18:     foreach ($line in $lines) {
   19:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   20:         try {
   21:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   22:             if ($null -eq $obj) { continue }
   23:             if ($obj.type -eq "error" -and $obj.ts) {
   24:                 $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
   25:                 if ($ts -ge $cutoff) { $errorCount++ }
   26:             }
   27:         } catch { continue }
   28:     }
   29:     if ($errorCount -gt 5) {
   30:         Write-Host "[FAIL] Traces: $errorCount errors in last 60 min" -ForegroundColor Red
   31:         $hasFail = $true
   32:     } elseif ($errorCount -gt 0) {
   33:         Write-Host "[WARN] Traces: $errorCount errors in last 60 min" -ForegroundColor Yellow
   34:     } else {
   35:         Write-Host "[OK] Traces: 0 errors in last 60 min" -ForegroundColor Green
   36:     }
   37: } else {
   38:     Write-Host "[OK] Traces: traces.jsonl not found (no errors)" -ForegroundColor Green
   39: }
   40: 
   41: # --- 2. Inbox backlog ---
   42: $inboxDir = Join-Path $root ".memory\inbox"
   43: $inboxCount = 0
   44: if (Test-Path $inboxDir) {
   45:     $inboxCount = (Get-ChildItem -Path $inboxDir -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
   46:     if ($inboxCount -gt 50) {
   47:         Write-Host "[FAIL] Inbox backlog: $inboxCount files" -ForegroundColor Red
   48:         $hasFail = $true
   49:     } elseif ($inboxCount -gt 20) {
   50:         Write-Host "[WARN] Inbox backlog: $inboxCount files" -ForegroundColor Yellow
   51:     } else {
   52:         Write-Host "[OK] Inbox backlog: $inboxCount files" -ForegroundColor Green
   53:     }
   54: } else {
   55:     Write-Host "[OK] Inbox: directory not found" -ForegroundColor Green
   56: }
   57: 
   58: # --- 3. Outbox (информативно) ---
   59: $outboxDir = Join-Path $root ".memory\outbox"
   60: $outboxCount = 0
   61: if (Test-Path $outboxDir) {
   62:     $outboxCount = (Get-ChildItem -Path $outboxDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
   63:     Write-Host "[OK] Outbox: $outboxCount files" -ForegroundColor Green
   64: } else {
   65:     Write-Host "[OK] Outbox: directory not found" -ForegroundColor Green
   66: }
   67: 
   68: # --- 4. Worktrees ---
   69: Write-Host "" -ForegroundColor Gray
   70: Write-Host "--- Git Worktrees ---" -ForegroundColor Cyan
   71: try {
   72:     $wtOutput = & git -C $root worktree list 2>&1
   73:     if ($LASTEXITCODE -eq 0) {
   74:         foreach ($line in $wtOutput) { Write-Host "  $line" -ForegroundColor Gray }
   75:         Write-Host "[OK] Worktrees: listed" -ForegroundColor Green
   76:     } else {
   77:         Write-Host "[WARN] Worktrees: git command failed" -ForegroundColor Yellow
   78:     }
   79: } catch {
   80:     Write-Host "[WARN] Worktrees: $($_.Exception.Message)" -ForegroundColor Yellow
   81: }
   82: 
   83: # --- 5. Performance: средняя duration_ms ---
   84: $perfPath = Join-Path $tracesDir "performance.jsonl"
   85: if (Test-Path $perfPath) {
   86:     $durations = @()
   87:     $perfLines = Get-Content $perfPath -ErrorAction SilentlyContinue
   88:     foreach ($line in $perfLines) {
   89:         if ([string]::IsNullOrWhiteSpace($line)) { continue }
   90:         try {
   91:             $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
   92:             if ($null -ne $obj -and $obj.duration_ms) {
   93:                 $durations += [double]$obj.duration_ms
   94:             }
   95:         } catch { continue }
   96:     }
   97:     if ($durations.Count -gt 0) {
   98:         $avgMs = ($durations | Measure-Object -Average).Average
   99:         $avgSec = [math]::Round($avgMs / 1000, 2)
  100:         Write-Host "[OK] Performance: avg session duration = ${avgSec}s ($($durations.Count) sessions)" -ForegroundColor Green
  101:     } else {
  102:         Write-Host "[OK] Performance: no duration data" -ForegroundColor Green
  103:     }
  104: } else {
  105:     Write-Host "[OK] Performance: performance.jsonl not found" -ForegroundColor Green
  106: }
  107: 
  108: # --- 6. Disk space ---
  109: $drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
  110: if ($drive) {
  111:     $freeGB = [math]::Round($drive.Free / 1GB, 2)
  112:     if ($freeGB -lt 5) {
  113:         Write-Host "[WARN] Disk: ${freeGB}GB free" -ForegroundColor Yellow
  114:     } else {
  115:         Write-Host "[OK] Disk: ${freeGB}GB free" -ForegroundColor Green
  116:     }
  117: } else {
  118:     Write-Host "[WARN] Disk: cannot determine free space" -ForegroundColor Yellow
  119: }
  120: 
  121: # --- 7. Skills+MCP Compliance Check (NEW) ---
  122: Write-Host "" -ForegroundColor Gray
  123: Write-Host "--- Skills+MCP Compliance ---" -ForegroundColor Cyan
  124: $complianceScript = Join-Path $PSScriptRoot "compliance-gate.ps1"
  125: if (Test-Path $complianceScript) {
  126:     try {
  127:         $compResult = & $complianceScript -ReportPath (Join-Path $root "CONTEXT-BUFFER.md") -LookbackHours 24 -Strict:$false
  128:         if ($LASTEXITCODE -eq 0) {
  129:             Write-Host "[OK] Compliance: PASS" -ForegroundColor Green
  130:         } else {
  131:             Write-Host "[WARN] Compliance: violations found (check .memory/tool-usage-violations.jsonl)" -ForegroundColor Yellow
  132:         }
  133:     } catch {
  134:         Write-Host "[WARN] Compliance: script error - $($_.Exception.Message)" -ForegroundColor Yellow
  135:     }
  136: } else {
  137:     Write-Host "[WARN] Compliance: compliance-gate.ps1 not found" -ForegroundColor Yellow
  138: }
  139: 
  140: # --- Итог ---
  141: Write-Host "" -ForegroundColor Gray
  142: if ($hasFail) {
  143:     Write-Host "HEALTH: FAIL" -ForegroundColor Red
  144:     exit 1
  145: } else {
  146:     Write-Host "HEALTH: PASS" -ForegroundColor Green
  147:     exit 0
  148: }
```

### `.agents/scripts/sync-agents.ps1` lines 304-534

```powershell
  304: $agentsDir = Join-Path $root ".opencode\agents"
  305: $promptsDir = Join-Path $agentsDir "prompts"
  306: $configPath = Join-Path $root "opencode.json"
  307: 
  308: if (-not (Test-Path $promptsDir)) {
  309:     New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
  310: }
  311: 
  312: $allowKeys = @("read", "edit", "bash", "glob", "grep", "skill", "question", "webfetch", "websearch", "task", "list")
  313: $denyIfMissing = @("edit", "bash", "task")
  314: 
  315: $jsonFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }
  316: 
  317: Write-Host "=== Sync Agents: $($jsonFiles.Count) files found ===" -ForegroundColor Cyan
  318: 
  319: $agentEntries = [System.Collections.ArrayList]::new()
  320: $count = 0
  321: 
  322: foreach ($file in $jsonFiles) {
  323:     # Защита от аномально большого входного файла (>50 КБ)
  324:     if ($file.Length -gt 51200) {
  325:         Write-Warning "SKIP $($file.Name): file size $([math]::Round($file.Length / 1024, 1)) KB exceeds 50 KB limit — suspicious"
  326:         continue
  327:     }
  328: 
  329:     $raw = $null
  330:     $data = $null
  331: 
  332:     # Валидация JSON после чтения — try/catch, пропуск при ошибке
  333:     try {
  334:         $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
  335:         $data = $raw | ConvertFrom-Json
  336:     }
  337:     catch {
  338:         Write-Warning "SKIP $($file.Name): invalid JSON — $($_.Exception.Message)"
  339:         continue
  340:     }
  341: 
  342:     # Валидация обязательных полей
  343:     $hasDescription = $data.description -and ($data.description -is [string]) -and ($data.description.Trim().Length -gt 0)


---
Ответь только: `Принято 12/15`. Жди следующую часть.
