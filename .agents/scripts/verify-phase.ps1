param()

Write-Host "=== Agent-HQ Phase Verification ===" -ForegroundColor Cyan
Write-Host ""

$pass = 0
$fail = 0
$total = 0

function Test-Check {
    param([string]$Name, [bool]$Condition)
    $script:total++
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:fail++
    }
}

# Phase 0: ACP
Write-Host "Phase 0: Agent Communication Protocol" -ForegroundColor Yellow
Test-Check ".memory/inbox/ exists" (Test-Path ".memory\inbox")
Test-Check ".memory/outbox/ exists" (Test-Path ".memory\outbox")
Test-Check ".memory/dead-letter/ exists" (Test-Path ".memory\dead-letter")

$inboxAgents = Get-ChildItem ".memory\inbox" -Directory -ErrorAction SilentlyContinue | Measure-Object
Test-Check "At least 1 agent inbox" ($inboxAgents.Count -ge 1)

# Phase 0.5: Sandbox
Write-Host ""
Write-Host "Phase 0.5: Sandbox via git worktree" -ForegroundColor Yellow
Test-Check ".agents/worktrees/ exists" (Test-Path ".agents\worktrees")

$worktrees = Get-ChildItem ".agents\worktrees" -Directory -ErrorAction SilentlyContinue | Measure-Object
Test-Check "At least 1 worktree" ($worktrees.Count -ge 1)

# Phase 1: Memory Bank
Write-Host ""
Write-Host "Phase 1: Memory Bank" -ForegroundColor Yellow
$mbFiles = @("activeContext.md", "decisionLog.md", "productContext.md", "progress.md", "systemPatterns.md")
foreach ($f in $mbFiles) {
    $path = ".memory\$f"
    $exists = Test-Path $path
    if ($exists) {
        $size = (Get-Item $path).Length
        Test-Check "$f exists and not empty" ($size -gt 0)
    } else {
        Test-Check "$f exists and not empty" $false
    }
}

# Phase 2: Agent Configs
Write-Host ""
Write-Host "Phase 2: Agent Configurations" -ForegroundColor Yellow
Test-Check ".opencode/agents/ exists" (Test-Path ".opencode\agents")

$jsonFiles = Get-ChildItem ".opencode\agents\*.json" -ErrorAction SilentlyContinue | Measure-Object
Test-Check "At least 5 JSON configs" ($jsonFiles.Count -ge 5)

# Phase 2.5: Git
Write-Host ""
Write-Host "Phase 2.5: Git Versioning" -ForegroundColor Yellow
Test-Check ".git/ exists" (Test-Path ".git")
Test-Check ".gitignore exists" (Test-Path ".gitignore")

# Phase 3: Skills
Write-Host ""
Write-Host "Phase 3: Skills" -ForegroundColor Yellow
Test-Check ".agents/skills/ exists" (Test-Path ".agents\skills")

$skills = Get-ChildItem ".agents\skills" -Directory -ErrorAction SilentlyContinue | Measure-Object
Test-Check "At least 1 skill folder" ($skills.Count -ge 1)

# Phase 11: Commands
Write-Host ""
Write-Host "Phase 11: Commands" -ForegroundColor Yellow
$config = Get-Content "opencode.json" -Raw | ConvertFrom-Json
$hasSync = $null -ne $config.command.sync
$hasStatus = $null -ne $config.command.status
Test-Check "/sync command defined" $hasSync
Test-Check "/status command defined" $hasStatus

# Phase B2: Agent Registration
Write-Host ""
Write-Host "Phase B2: Agent Registration" -ForegroundColor Yellow
$ocRaw = Get-Content "opencode.json" -Raw -ErrorAction SilentlyContinue
if ($ocRaw) {
    $oc = $ocRaw | ConvertFrom-Json
    Test-Check "opencode.json has agents section" ($null -ne $oc.agents)
    if ($null -ne $oc.agents) {
        $agentCount = ($oc.agents | Get-Member -MemberType NoteProperty).Count
        Test-Check "agents section has >= 30 entries ($agentCount found)" ($agentCount -ge 30)
    } else {
        Test-Check "agents section has >= 30 entries" $false
    }
} else {
    Test-Check "opencode.json has agents section" $false
    Test-Check "agents section has >= 30 entries" $false
}
$promptsDir = ".opencode\agents\prompts"
$promptsExist = Test-Path $promptsDir
Test-Check ".opencode/agents/prompts/ exists" $promptsExist
if ($promptsExist) {
    $promptFiles = Get-ChildItem "$promptsDir\*.txt" -ErrorAction SilentlyContinue | Measure-Object
    Test-Check "prompts has >= 19 .txt files ($($promptFiles.Count) found)" ($promptFiles.Count -ge 19)
} else {
    Test-Check "prompts has >= 19 .txt files" $false
}

# Phase D2: Context Bus
Write-Host ""
Write-Host "Phase D2: Context Bus" -ForegroundColor Yellow
$ctxExists = Test-Path "CONTEXT-BUFFER.md"
if ($ctxExists) {
    $ctxSize = (Get-Item "CONTEXT-BUFFER.md").Length
    Test-Check "CONTEXT-BUFFER.md exists and not empty" ($ctxSize -gt 0)
} else {
    Test-Check "CONTEXT-BUFFER.md exists and not empty" $false
}
$agentsExists = Test-Path "AGENTS.md"
if ($agentsExists) {
    $agentsSize = (Get-Item "AGENTS.md").Length
    Test-Check "AGENTS.md exists and not empty" ($agentsSize -gt 0)
} else {
    Test-Check "AGENTS.md exists and not empty" $false
}

# Phase E2: Real Code Features
Write-Host ""
Write-Host "Phase E2: Real Code Features" -ForegroundColor Yellow
Test-Check ".opencode/plugins/tracer.js exists" (Test-Path ".opencode\plugins\tracer.js")
Test-Check ".opencode/plugins/scoring.js exists" (Test-Path ".opencode\plugins\scoring.js")
Test-Check ".agents/scripts/health-check.ps1 exists" (Test-Path ".agents\scripts\health-check.ps1")
$tracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
$tracesPath = Join-Path $tracesDir "traces.jsonl"
$tracesExists = Test-Path $tracesPath
if ($tracesExists) {
    $tracesSize = (Get-Item $tracesPath).Length
    Test-Check "traces.jsonl exists and not empty (in LOCALAPPDATA)" ($tracesSize -gt 0)
} else {
    Test-Check "traces.jsonl exists and not empty (in LOCALAPPDATA)" $false
}

# Phase F: US-011..015 Multi-Project
Write-Host ""
Write-Host "Phase F: US-011..015 Multi-Project" -ForegroundColor Yellow

# F1: .agents/templates/project/ exists with required files
$templateDir = ".agents\templates\project"
$templateFiles = @("CONTEXT-BUFFER.md", "KNOWLEDGE-BASE.md", "project.json", "queue.json", "README.md")
$templateDirExists = Test-Path $templateDir
$allTemplateFilesExist = $true
if ($templateDirExists) {
    foreach ($f in $templateFiles) {
        if (-not (Test-Path (Join-Path $templateDir $f))) {
            $allTemplateFilesExist = $false
            break
        }
    }
} else {
    $allTemplateFilesExist = $false
}
Test-Check "F1: .agents/templates/project/ exists with 5 required files" ($templateDirExists -and $allTemplateFilesExist)

# F1b: memory/ subdirectory exists in template
$templateMemoryDir = Join-Path $templateDir "memory"
Test-Check "F1b: .agents/templates/project/memory/ exists" (Test-Path $templateMemoryDir)

# F2: projects/ - at least 2 directories, each with CONTEXT-BUFFER.md + project.json + queue.json
$projectsDir = "projects"
$projectsExist = Test-Path $projectsDir
$validProjects = 0
if ($projectsExist) {
    $projectDirs = Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue
    foreach ($pd in $projectDirs) {
        $hasCtx = Test-Path (Join-Path $pd.FullName "CONTEXT-BUFFER.md")
        $hasProj = Test-Path (Join-Path $pd.FullName "project.json")
        $hasQueue = Test-Path (Join-Path $pd.FullName "queue.json")
        if ($hasCtx -and $hasProj -and $hasQueue) {
            $validProjects++
        }
    }
}
Test-Check "F2: projects/ has >= 2 valid projects ($validProjects found)" ($validProjects -ge 2)

# F3: create-project.ps1 contains "templates"
$createProjectPath = ".agents\scripts\create-project.ps1"
$hasTemplatesKeyword = $false
if (Test-Path $createProjectPath) {
    $content = Get-Content $createProjectPath -Raw -ErrorAction SilentlyContinue
    $hasTemplatesKeyword = $content -match "templates"
}
Test-Check "F3: create-project.ps1 contains 'templates' keyword" $hasTemplatesKeyword

# F4: .memory/agent-registry.json valid JSON, 30 agents, has status/daily_load fields
$registryPath = ".memory\agent-registry.json"
$registryValid = $false
$registryAgentCount = 0
$hasStatusField = $false
$hasDailyLoadField = $false
if (Test-Path $registryPath) {
    try {
        $content = [System.IO.File]::ReadAllText($registryPath, [System.Text.UTF8Encoding]::new($false))
        $registry = $content | ConvertFrom-Json -ErrorAction Stop
        $registryValid = $true
        if ($registry.agents) {
            $registryAgentCount = ($registry.agents | Get-Member -MemberType NoteProperty).Count
            # Check first agent for status and daily_load fields
            $firstAgentName = ($registry.agents | Get-Member -MemberType NoteProperty)[0].Name
            $firstAgent = $registry.agents.$firstAgentName
            $hasStatusField = $null -ne $firstAgent.status
            $hasDailyLoadField = $null -ne $firstAgent.daily_load
        }
    } catch {
        $registryValid = $false
    }
}
Test-Check "F4: agent-registry.json valid, 30 agents, has status/daily_load ($registryAgentCount agents)" ($registryValid -and $registryAgentCount -ge 30 -and $hasStatusField -and $hasDailyLoadField)

# F5: agent-registry.ps1 -List -Status free -> exit 0, output contains "free"
$regScript = ".agents\scripts\agent-registry.ps1"
$f5Pass = $false
if (Test-Path $regScript) {
    $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -List -Status free 2>&1
    $exitCode = $LASTEXITCODE
    $f5Pass = ($exitCode -eq 0) -and ($result -match "free")
}
Test-Check "F5: agent-registry.ps1 -List -Status free exits 0, shows 'free'" $f5Pass

# F6: agent-registry.ps1 -Acquire -Specialization "nonexistent-xyz" -> exit 2
$f6Pass = $false
if (Test-Path $regScript) {
    $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $regScript -Acquire -Specialization "nonexistent-xyz" -Project "test" 2>&1
    $exitCode = $LASTEXITCODE
    $f6Pass = ($exitCode -eq 2)
}
Test-Check "F6: agent-registry.ps1 -Acquire nonexistent spec exits 2" $f6Pass

# F7: project-queue.ps1 test on 1c-buh: -Add (critical) -> -Next (returns critical) -> -Complete (done) -> -List confirms -> cleanup to empty
$queueScript = ".agents\scripts\project-queue.ps1"
$f7Pass = $false
$testProject = "1c-buh"
if (Test-Path $queueScript) {
    # Add a critical task
    $addResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Add -Project $testProject -Title "Test critical task" -Priority critical 2>&1
    $addExit = $LASTEXITCODE
    if ($addExit -eq 0 -and $addResult -match "tq-(\d{3})") {
        $taskId = $Matches[0]
        # Get next task (should return our critical task)
        $nextResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Next -Project $testProject 2>&1
        $nextExit = $LASTEXITCODE
        if ($nextExit -eq 0 -and $nextResult -match $taskId) {
            # Complete the task
            $completeResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Complete -Project $testProject -Task $taskId 2>&1
            $completeExit = $LASTEXITCODE
            if ($completeExit -eq 0) {
                # List to confirm done
                $listResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
                $listExit = $LASTEXITCODE
                if ($listExit -eq 0 -and $listResult -match "done") {
                    # CLEANUP: Remove the test task by marking dead and removing, or just verify queue is clean
                    # Actually, let's just verify the queue ends up with the task in done status
                    # For idempotency, we'll mark it dead to remove from active queue
                    $deadResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -Dead -Project $testProject -Task $taskId -Reason "Test cleanup" 2>&1
                    $deadExit = $LASTEXITCODE
                    # Final list should show empty or only done/dead tasks
                    $finalList = & powershell -NoProfile -ExecutionPolicy Bypass -File $queueScript -List -Project $testProject 2>&1
                    $finalExit = $LASTEXITCODE
                    # Check that queue is effectively clean (no queued/assigned/in_progress)
                    $queueContent = Get-Content (Join-Path "projects\$testProject\queue.json") -Raw -ErrorAction SilentlyContinue
                    $queueObj = $queueContent | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $activeTasks = 0
                    if ($queueObj -and $queueObj.tasks) {
                        $activeTasks = ($queueObj.tasks | Where-Object { $_.status -in @("queued", "assigned", "in_progress") }).Count
                    }
                    $f7Pass = ($activeTasks -eq 0)
                }
            }
        }
    }
}
Test-Check "F7: project-queue.ps1 full cycle (Add->Next->Complete->cleanup) on 1c-buh" $f7Pass

# F8: agent-utilization.ps1 output contains "Utilization"; -Json outputs valid JSON
$utilScript = ".agents\scripts\agent-utilization.ps1"
$f8TextPass = $false
$f8JsonPass = $false
if (Test-Path $utilScript) {
    $textResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript 2>&1
    $textExit = $LASTEXITCODE
    $f8TextPass = ($textExit -eq 0) -and ($textResult -match "Utilization")
    
    $jsonResult = & powershell -NoProfile -ExecutionPolicy Bypass -File $utilScript -Json 2>&1
    $jsonExit = $LASTEXITCODE
    if ($jsonExit -eq 0) {
        try {
            $null = $jsonResult | ConvertFrom-Json -ErrorAction Stop
            $f8JsonPass = $true
        } catch {
            $f8JsonPass = $false
        }
    }
}
Test-Check "F8: agent-utilization.ps1 shows 'Utilization' and -Json valid" ($f8TextPass -and $f8JsonPass)

# F9: opencode.json command.status.template mentions agent-utilization or "Agents & Utilization"
$f9Pass = $false
if (Test-Path "opencode.json") {
    $ocContent = Get-Content "opencode.json" -Raw
    $oc = $ocContent | ConvertFrom-Json
    if ($oc.command.status.template) {
        $template = $oc.command.status.template
        $f9Pass = ($template -match "agent-utilization") -or ($template -match "Agents & Utilization")
    }
}
Test-Check "F9: opencode.json status command mentions agent-utilization or 'Agents & Utilization'" $f9Pass

# F10: knowledge-index.md in root, "### PAT-" appears >= 6 times
$kiPath = "knowledge-index.md"
$f10Pass = $false
if (Test-Path $kiPath) {
    $kiContent = Get-Content $kiPath -Raw
    $patCount = ($kiContent -split "### PAT-" | Measure-Object).Count - 1
    $f10Pass = ($patCount -ge 6)
}
Test-Check "F10: knowledge-index.md has >= 6 '### PAT-' entries ($patCount found)" $f10Pass

# F11: .opencode/agents/prompts/team-lead.txt contains "DUAL-AGENT DELEGATION"
$tlPromptPath = ".opencode\agents\prompts\team-lead.txt"
$f11Pass = $false
if (Test-Path $tlPromptPath) {
    $tlContent = Get-Content $tlPromptPath -Raw
    $f11Pass = $tlContent -match "DUAL-AGENT DELEGATION"
}
Test-Check "F11: team-lead.txt contains 'DUAL-AGENT DELEGATION'" $f11Pass

# Summary
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $pass / $total" -ForegroundColor Green
if ($fail -gt 0) {
    Write-Host "Failed: $fail / $total" -ForegroundColor Red
} else {
    Write-Host "Failed: 0 / $total" -ForegroundColor Green
}
Write-Host ""
if ($fail -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
} else {
    Write-Host "SOME CHECKS FAILED - review above" -ForegroundColor Yellow
}
if ($fail -gt 0) { exit 1 }
