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
    Test-Check "opencode.json has agent section" ($null -ne $oc.agent)
    if ($null -ne $oc.agent) {
        $agentCount = ($oc.agent | Get-Member -MemberType NoteProperty).Count
        Test-Check "agent section has >= 19 entries ($agentCount found)" ($agentCount -ge 19)
    } else {
        Test-Check "agent section has >= 19 entries" $false
    }
} else {
    Test-Check "opencode.json has agent section" $false
    Test-Check "agent section has >= 19 entries" $false
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
$tracesExists = Test-Path ".memory\traces\traces.jsonl"
if ($tracesExists) {
    $tracesSize = (Get-Item ".memory\traces\traces.jsonl").Length
    Test-Check ".memory/traces/traces.jsonl exists and not empty" ($tracesSize -gt 0)
} else {
    Test-Check ".memory/traces/traces.jsonl exists and not empty" $false
}

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
