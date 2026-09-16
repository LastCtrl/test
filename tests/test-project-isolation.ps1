# test-project-isolation.ps1 - P1-2 per-project isolation tests (worktree +
# CONTEXT-BUFFER + cross-project leak guard).
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT, so no real project/queue/worktree state of
# the repository is touched.
#
# Covered:
#   a) buffers      - each project gets its own CONTEXT-BUFFER.md (distinct files)
#   b) worktrees    - each project gets its own worktree (distinct dirs, branch
#                     project/<name> when git is available)
#   c) append       - a write to project A never shows up in project B
#   d) leak guard   - a cross-project write is blocked and a foreign path is
#                     detected as a boundary violation
#   e) queue link   - a queue task records its project and worktree
#   f) claim scope  - the same task id can be claimed independently per project
#
# Exit code: 0 when every check passes, 1 when at least one check fails.

$Here   = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Scripts  = Join-Path $RepoRoot '.agents\scripts'
$IsolationHelper = Join-Path $Scripts 'project-worktree.ps1'
$CreateProject   = Join-Path $Scripts 'create-project.ps1'
$ProjectQueue    = Join-Path $Scripts 'project-queue.ps1'
$TaskState       = Join-Path $Scripts 'task-state.ps1'

$TempBase = Join-Path $env:TEMP 'agent-hq-project-isolation-tests'
$Root     = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
        $script:Pass++
    } else {
        Write-Host ("    FAIL: " + $Label)
        $script:Fail++
    }
    return $Condition
}

function Invoke-Ps1 {
    param([string]$ScriptPath, [string[]]$ScriptArgs)
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ScriptArgs)
    $text = & powershell @argv 2>&1 | Out-String
    return [PSCustomObject]@{ Exit = $LASTEXITCODE; Out = $text }
}

function Get-GitBranch {
    param([string]$RepoPath)
    $out = & git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
    return (($out | Out-String).Trim())
}

function Test-ContainsText {
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.Contains($Needle)
}

# Antivirus/indexer can hold a freshly written file for a moment, and git
# object files are read-only; Remove-Item -Force handles the attributes and the
# retries absorb a transient lock so temp artifacts are never left behind.
function Remove-DirectoryWithRetry {
    param([string]$Path, [int]$Attempts = 5, [int]$DelayMs = 400)
    for ($i = 0; $i -lt $Attempts; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds $DelayMs
    }
    return (-not (Test-Path -LiteralPath $Path))
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
New-Item -ItemType Directory -Path $Root -Force | Out-Null

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$gitRepo = $false
if ($gitAvailable) {
    $null = & git -C $Root init 2>&1
    $null = & git -C $Root -c user.email=isolation-test@example.invalid -c user.name=isolation-test commit --allow-empty -m "init" 2>&1
    $null = & git -C $Root rev-parse --verify --quiet HEAD 2>&1
    $gitRepo = ($LASTEXITCODE -eq 0)
}

$env:AGENT_HQ_ROOT = $Root

Write-Host "=== agent-hq per-project isolation tests ==="
Write-Host ("Root     : " + $Root)
Write-Host ("Git repo : " + $gitRepo)

if (-not (Test-Path -LiteralPath $IsolationHelper -PathType Leaf)) {
    Write-Host ("FATAL: project-worktree.ps1 not found: " + $IsolationHelper)
    exit 1
}
if (-not (Test-Path -LiteralPath $CreateProject -PathType Leaf)) {
    Write-Host ("FATAL: create-project.ps1 not found: " + $CreateProject)
    exit 1
}

. $IsolationHelper

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$ProjectA = "isoA-$suffix"
$ProjectB = "isoB-$suffix"

# --- create two isolated projects -----------------------------------------

Write-Host ""
Write-Host "CASE: create two isolated projects"
$caseOk = $true

$createA = Invoke-Ps1 -ScriptPath $CreateProject -ScriptArgs @('-ProjectName', $ProjectA, '-TemplateType', 'full-stack')
$createB = Invoke-Ps1 -ScriptPath $CreateProject -ScriptArgs @('-ProjectName', $ProjectB, '-TemplateType', 'full-stack')
$caseOk = (Write-Check ("create project A exits 0") ($createA.Exit -eq 0)) -and $caseOk
$caseOk = (Write-Check ("create project B exits 0") ($createB.Exit -eq 0)) -and $caseOk
if ($createA.Exit -ne 0) { Write-Host ("    DIAG A: " + $createA.Out.Trim()) }
if ($createB.Exit -ne 0) { Write-Host ("    DIAG B: " + $createB.Out.Trim()) }

if ($caseOk) { Write-Host "PASS create two isolated projects" } else { Write-Host "FAIL create two isolated projects" }

# --- a) per-project CONTEXT-BUFFER ----------------------------------------

Write-Host ""
Write-Host "CASE: a) per-project CONTEXT-BUFFER"
$caseOk = $true

$bufferA = Join-Path $Root "projects\$ProjectA\CONTEXT-BUFFER.md"
$bufferB = Join-Path $Root "projects\$ProjectB\CONTEXT-BUFFER.md"

$caseOk = (Write-Check "buffer A exists" (Test-Path -LiteralPath $bufferA -PathType Leaf)) -and $caseOk
$caseOk = (Write-Check "buffer B exists" (Test-Path -LiteralPath $bufferB -PathType Leaf)) -and $caseOk
$caseOk = (Write-Check "buffer paths are distinct" ($bufferA -ne $bufferB)) -and $caseOk
$caseOk = (Write-Check "buffer resolver matches the created file" ((Get-ProjectContextBufferPath -Project $ProjectA -Root $Root) -eq $bufferA)) -and $caseOk

if ($caseOk) { Write-Host "PASS a) per-project CONTEXT-BUFFER" } else { Write-Host "FAIL a) per-project CONTEXT-BUFFER" }

# --- b) per-project worktree ----------------------------------------------

Write-Host ""
Write-Host "CASE: b) per-project worktree"
$caseOk = $true

$worktreeA = Join-Path $Root ".agents\worktrees\$ProjectA"
$worktreeB = Join-Path $Root ".agents\worktrees\$ProjectB"

$caseOk = (Write-Check "worktree A exists" (Test-Path -LiteralPath $worktreeA -PathType Container)) -and $caseOk
$caseOk = (Write-Check "worktree B exists" (Test-Path -LiteralPath $worktreeB -PathType Container)) -and $caseOk
$caseOk = (Write-Check "worktree paths are distinct" ($worktreeA -ne $worktreeB)) -and $caseOk

if ($gitRepo) {
    $branchA = Get-GitBranch -RepoPath $worktreeA
    $branchB = Get-GitBranch -RepoPath $worktreeB
    $caseOk = (Write-Check ("worktree A is on branch project/A (got '" + $branchA + "')") ($branchA -eq ("project/" + $ProjectA))) -and $caseOk
    $caseOk = (Write-Check ("worktree B is on branch project/B (got '" + $branchB + "')") ($branchB -eq ("project/" + $ProjectB))) -and $caseOk

    $infoA = Get-ProjectWorktree -Project $ProjectA -Root $Root
    $infoB = Get-ProjectWorktree -Project $ProjectB -Root $Root
    $caseOk = (Write-Check "worktree A is registered in the repo" ($infoA.registered -eq $true)) -and $caseOk
    $caseOk = (Write-Check "worktree B is registered in the repo" ($infoB.registered -eq $true)) -and $caseOk
    $caseOk = (Write-Check "worktree A registration branch matches" ([string]$infoA.registered_branch -eq ("project/" + $ProjectA))) -and $caseOk
    $caseOk = (Write-Check "worktree B registration branch matches" ([string]$infoB.registered_branch -eq ("project/" + $ProjectB))) -and $caseOk
} else {
    Write-Host "    WARN: git not available - branch assertions skipped"
}

# Idempotency: calling the creator again must not fail or create a second tree.
$again = New-ProjectWorktree -Project $ProjectA -Root $Root
$caseOk = (Write-Check "re-creating worktree A is idempotent" ($again.ok -eq $true)) -and $caseOk

if ($caseOk) { Write-Host "PASS b) per-project worktree" } else { Write-Host "FAIL b) per-project worktree" }

# --- c) append isolation ---------------------------------------------------

Write-Host ""
Write-Host "CASE: c) buffer append isolation"
$caseOk = $true

$noteA = "ISO-NOTE-A-" + [guid]::NewGuid().ToString('N')
$noteB = "ISO-NOTE-B-" + [guid]::NewGuid().ToString('N')

$writeA = Write-ProjectContextBuffer -Project $ProjectA -Content ("`r`n" + $noteA + "`r`n") -SourceProject $ProjectA -Root $Root
$writeB = Write-ProjectContextBuffer -Project $ProjectB -Content ("`r`n" + $noteB + "`r`n") -SourceProject $ProjectB -Root $Root

$caseOk = (Write-Check "write to buffer A succeeds" ($writeA.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "write to buffer B succeeds" ($writeB.ok -eq $true)) -and $caseOk

$textA = Read-ProjectContextBuffer -Project $ProjectA -Root $Root
$textB = Read-ProjectContextBuffer -Project $ProjectB -Root $Root

$caseOk = (Write-Check "buffer A contains its own note" (Test-ContainsText -Text $textA -Needle $noteA)) -and $caseOk
$caseOk = (Write-Check "buffer B does NOT contain the note from A" (-not (Test-ContainsText -Text $textB -Needle $noteA))) -and $caseOk
$caseOk = (Write-Check "buffer B contains its own note" (Test-ContainsText -Text $textB -Needle $noteB)) -and $caseOk
$caseOk = (Write-Check "buffer A does NOT contain the note from B" (-not (Test-ContainsText -Text $textA -Needle $noteB))) -and $caseOk

if ($caseOk) { Write-Host "PASS c) buffer append isolation" } else { Write-Host "FAIL c) buffer append isolation" }

# --- d) cross-project leak guard ------------------------------------------

Write-Host ""
Write-Host "CASE: d) cross-project leak guard"
$caseOk = $true

$leakNote = "ISO-LEAK-" + [guid]::NewGuid().ToString('N')
$cross = Write-ProjectContextBuffer -Project $ProjectB -Content ("`r`n" + $leakNote + "`r`n") -SourceProject $ProjectA -Root $Root

$caseOk = (Write-Check "cross-project write is refused (ok=false)" ($cross.ok -eq $false)) -and $caseOk
$caseOk = (Write-Check "refusal reason names the cross-project violation" ($cross.reason -match 'cross-project')) -and $caseOk

$textBAfter = Read-ProjectContextBuffer -Project $ProjectB -Root $Root
$caseOk = (Write-Check "leaked content never reached buffer B" (-not (Test-ContainsText -Text $textBAfter -Needle $leakNote))) -and $caseOk

$caseOk = (Write-Check "foreign path (A) is outside B boundary" ((Test-ProjectPathBoundary -Project $ProjectB -Path $bufferA -Root $Root) -eq $false)) -and $caseOk
$caseOk = (Write-Check "foreign path (A) is detected as a leak for B" ((Test-ProjectContextLeak -Project $ProjectB -Path $bufferA -Root $Root) -eq $true)) -and $caseOk
$caseOk = (Write-Check "own path (B) is inside B boundary" ((Test-ProjectPathBoundary -Project $ProjectB -Path $bufferB -Root $Root) -eq $true)) -and $caseOk
$caseOk = (Write-Check "own path (B) is not a leak" ((Test-ProjectContextLeak -Project $ProjectB -Path $bufferB -Root $Root) -eq $false)) -and $caseOk

if ($caseOk) { Write-Host "PASS d) cross-project leak guard" } else { Write-Host "FAIL d) cross-project leak guard" }

# --- e) queue task -> project + worktree ----------------------------------

Write-Host ""
Write-Host "CASE: e) queue task records project and worktree"
$caseOk = $true

$add = Invoke-Ps1 -ScriptPath $ProjectQueue -ScriptArgs @('-Add', '-Project', $ProjectA, '-Title', 'isolation task', '-Priority', 'normal')
$caseOk = (Write-Check "project-queue -Add exits 0" ($add.Exit -eq 0)) -and $caseOk
if ($add.Exit -ne 0) { Write-Host ("    DIAG: " + $add.Out.Trim()) }

$queuePath = Join-Path $Root "projects\$ProjectA\queue.json"
$queueObj = $null
if (Test-Path -LiteralPath $queuePath -PathType Leaf) {
    try { $queueObj = ConvertFrom-Json ([System.IO.File]::ReadAllText($queuePath, $Utf8NoBom)) } catch { $queueObj = $null }
}
$tasks = @()
if ($null -ne $queueObj -and $null -ne $queueObj.tasks) { $tasks = @($queueObj.tasks) }
$caseOk = (Write-Check "queue has a task" ($tasks.Count -ge 1)) -and $caseOk

if ($tasks.Count -ge 1) {
    $task = $tasks[$tasks.Count - 1]
    $caseOk = (Write-Check "task records its project" ([string]$task.project -eq $ProjectA)) -and $caseOk
    $caseOk = (Write-Check "task records the project worktree" (Test-ContainsText -Text ([string]$task.worktree) -Needle (".agents\worktrees\" + $ProjectA))) -and $caseOk
    $caseOk = (Write-Check "task worktree does not point at another project" (-not (Test-ContainsText -Text ([string]$task.worktree) -Needle $ProjectB))) -and $caseOk
}

if ($caseOk) { Write-Host "PASS e) queue records project + worktree" } else { Write-Host "FAIL e) queue records project + worktree" }

# --- f) per-project claim scope -------------------------------------------

Write-Host ""
Write-Host "CASE: f) same task id claimed independently per project"
$caseOk = $true

if (Test-Path -LiteralPath $TaskState -PathType Leaf) {
    . $TaskState

    $claimsA = Join-Path $Root "projects\$ProjectA\.memory\claims"
    $claimsB = Join-Path $Root "projects\$ProjectB\.memory\claims"

    $claimA = Claim-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsA
    $claimB = Claim-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsB
    $caseOk = (Write-Check "claim tq-001 in project A succeeds" ($claimA -eq $true)) -and $caseOk
    $caseOk = (Write-Check "claim tq-001 in project B succeeds independently" ($claimB -eq $true)) -and $caseOk

    $claimFileA = Join-Path $claimsA 'tq-001.claim.json'
    $claimFileB = Join-Path $claimsB 'tq-001.claim.json'
    $caseOk = (Write-Check "project A claim file exists" (Test-Path -LiteralPath $claimFileA -PathType Leaf)) -and $caseOk
    $caseOk = (Write-Check "project B claim file exists" (Test-Path -LiteralPath $claimFileB -PathType Leaf)) -and $caseOk
    $caseOk = (Write-Check "project A claim is inside A boundary" ((Test-ProjectPathBoundary -Project $ProjectA -Path $claimFileA -Root $Root) -eq $true)) -and $caseOk
    $caseOk = (Write-Check "project A claim is outside B boundary" ((Test-ProjectPathBoundary -Project $ProjectB -Path $claimFileA -Root $Root) -eq $false)) -and $caseOk

    $null = Release-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsA
    $null = Release-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsB
} else {
    $caseOk = (Write-Check "task-state.ps1 present" $false) -and $caseOk
}

if ($caseOk) { Write-Host "PASS f) per-project claim scope" } else { Write-Host "FAIL f) per-project claim scope" }

# --- isolation of the test itself -----------------------------------------

Write-Host ""
Write-Host "CASE: test did not touch the real repository"
$caseOk = $true
$caseOk = (Write-Check "no worktree leaked into the real repo" (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".agents\worktrees\$ProjectA")))) -and $caseOk
$caseOk = (Write-Check "no project leaked into the real repo" (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "projects\$ProjectA")))) -and $caseOk
if ($caseOk) { Write-Host "PASS test isolation" } else { Write-Host "FAIL test isolation" }

# --- summary + cleanup -----------------------------------------------------

$total = $script:Pass + $script:Fail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + $total)
Write-Host "=================================================="

foreach ($project in @($ProjectA, $ProjectB)) {
    try { $null = Remove-ProjectWorktree -Project $project -Root $Root } catch { }
}
if ($gitRepo) { $null = & git -C $Root worktree prune 2>&1 }

Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
$null = Remove-DirectoryWithRetry -Path $Root
$null = Remove-DirectoryWithRetry -Path $TempBase

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
