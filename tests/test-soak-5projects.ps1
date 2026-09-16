# test-soak-5projects.ps1 - P2 soak: five project scopes at once, no collisions.
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT, so no real project, queue, worktree or bus
# state of the repository is touched. The agent CLI is tests\fake-opencode.ps1.
#
# Covered:
#   a) whitelist   - Test-ProjectName accepts 5 names (2 Cyrillic, 1 with a space)
#                    and rejects traversal / Windows-invalid / reserved names
#   b) create      - create-project.ps1 creates all 5 projects (incl. Cyrillic)
#   c) worktrees   - every project has its own registered git worktree, the path
#                    keeps the original name, the branch is a valid git ref
#   d) buffers     - per-project CONTEXT-BUFFER with a leak guard (5 x 5 matrix)
#   e) queue       - every project keeps its own queue/task/worktree binding
#   f) claims      - the same task id is claimed independently in all 5 scopes
#                    and completing it in one scope does not touch the others
#   g) pipeline    - daemon -Drain processes 5 agents (5 projects) to 5 outbox
#                    records without duplicates, dead letters or leftovers
#   h) collisions  - paths/branches/claims are pairwise distinct and the real
#                    repository keeps its own worktree list
#
# Exit code: 0 when every check passes, 1 when at least one check fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Scripts  = Join-Path $RepoRoot '.agents\scripts'

$IsolationHelper = Join-Path $Scripts 'project-worktree.ps1'
$CreateProject   = Join-Path $Scripts 'create-project.ps1'
$ProjectQueue    = Join-Path $Scripts 'project-queue.ps1'
$TaskState       = Join-Path $Scripts 'task-state.ps1'
$Daemon          = Join-Path $Scripts 'agent-hq-daemon.ps1'
$FakeCli         = Join-Path $Here 'fake-opencode.ps1'

$TempBase   = Join-Path $env:TEMP 'agent-hq-soak-5projects'
$Root       = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ('    ok  : ' + $Label)
        $script:Pass++
    } else {
        Write-Host ('    FAIL: ' + $Label)
        $script:Fail++
    }
    return $Condition
}

function Write-CaseResult {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ('PASS ' + $Name) } else { Write-Host ('FAIL ' + $Name) }
}

function Test-PathLeaf {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Test-PathDir {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function Invoke-Ps1 {
    param([string]$ScriptPath, [string[]]$ScriptArgs)
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ScriptArgs)
    $text = & powershell @argv 2>&1 | Out-String
    return [PSCustomObject]@{ Exit = $LASTEXITCODE; Out = $text }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-PathLeaf $Path)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) | ConvertFrom-Json) } catch { return $null }
}

function Get-JsonFileCount {
    param([string]$Dir)
    if (-not (Test-PathDir $Dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

# The inbox keeps one directory per agent, so its messages are counted recursively.
function Get-JsonFileCountRecursive {
    param([string]$Dir)
    if (-not (Test-PathDir $Dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue).Count
}

function Test-ContainsText {
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.Contains($Needle)
}

function Get-DistinctCount {
    param([string[]]$Values)
    if ($Values.Count -eq 0) { return 0 }
    return @($Values | Select-Object -Unique).Count
}

function New-Directory {
    param([string]$Path)
    if (-not (Test-PathDir $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# Antivirus/indexer can hold a freshly written file for a moment, and git object
# files are read-only; retries absorb a transient lock so temp is never left.
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

# --- project names under soak ------------------------------------------------
# Two real Cyrillic names plus one name with a space (the only character legal in
# a project name but illegal inside a git ref). The literals below need this file
# to be read as UTF-8; the guard in case a) fails loudly if that ever breaks.
$Cyr1 = "1с-centr1507"
$Cyr2 = "1с-SlyckBuh1509"
$ExpectedCyr1 = "1" + [char]0x0441 + '-centr1507'
$ExpectedCyr2 = "1" + [char]0x0441 + '-SlyckBuh1509'
$ProjectNames = @($Cyr1, $Cyr2, 'soak-alpha', 'soak beta', 'soak-gamma')

# --- setup -------------------------------------------------------------------
New-Directory $TempBase
New-Directory $Root

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$gitRepo = $false
if ($gitAvailable) {
    $null = & git -C $Root init -q 2>&1
    $null = & git -C $Root -c user.email=soak@example.invalid -c user.name=soak commit --allow-empty -m 'init' 2>&1
    $null = & git -C $Root rev-parse --verify --quiet HEAD 2>&1
    $gitRepo = ($LASTEXITCODE -eq 0)
}

$env:AGENT_HQ_ROOT = $Root
$env:AGENT_HQ_OPENCODE = $FakeCli
$env:FAKE_OPENCODE_MODE = 'success'

$projectWtListBefore = ''
if ($gitAvailable) { $projectWtListBefore = (@(& git -C $RepoRoot worktree list --porcelain 2>$null) -join "`n") }

Write-Host '=== agent-hq 5-project soak test ==='
Write-Host ('Root     : ' + $Root)
Write-Host ('Git repo : ' + $gitRepo)
Write-Host ('Projects : ' + ($ProjectNames -join ', '))

foreach ($required in @($IsolationHelper, $CreateProject, $ProjectQueue, $TaskState, $Daemon, $FakeCli)) {
    if (-not (Test-PathLeaf $required)) {
        Write-Host ('FATAL: required file not found: ' + $required)
        exit 1
    }
}

. $IsolationHelper
. $TaskState

# --- a) project-name whitelist ----------------------------------------------

Write-Host ''
Write-Host 'CASE: a) project-name whitelist (Unicode-safe)'
$caseOk = $true

$caseOk = (Write-Check 'Cyrillic literals survive the source encoding (BOM)' (($Cyr1 -eq $ExpectedCyr1) -and ($Cyr2 -eq $ExpectedCyr2))) -and $caseOk
foreach ($name in $ProjectNames) {
    $caseOk = (Write-Check ('accepts project name: ' + $name) ((Test-ProjectName -ProjectName $name) -eq $true)) -and $caseOk
}

$invalidNames = @('..', '../evil', '..\..\evil', 'a/b', 'a\b', 'a.b', 'a:b', 'a*b', 'a?b', 'a"b', 'a<b', 'a>b', 'a|b',
    ' a', 'a ', 'a.', '.a', 'a..b', 'CON', 'con', 'PRN', 'AUX', 'NUL', 'Com1', 'COM9', 'LPT1', 'lpt9', '', ' ', ($('x' * 64)))
$allRejected = $true
foreach ($bad in $invalidNames) {
    if (Test-ProjectName -ProjectName $bad) { $allRejected = $false; Write-Host ('    DIAG: wrongly accepted: [' + $bad + ']') }
}
$caseOk = (Write-Check ('rejects all ' + $invalidNames.Count + ' unsafe names (traversal/invalid/reserved/too long)') $allRejected) -and $caseOk

$reason = ''
$caseOk = (Write-Check 'Test-ProjectName reports a reason for a bad name' (((Test-ProjectName -ProjectName '..\evil' -Reason ([ref]$reason)) -eq $false) -and ($reason.Length -gt 0))) -and $caseOk

$assertThrew = $false
try { $null = Assert-ProjectName -ProjectName '..\evil' } catch { $assertThrew = $true }
$caseOk = (Write-Check 'Assert-ProjectName throws on traversal' $assertThrew) -and $caseOk

Write-CaseResult 'a) project-name whitelist' $caseOk

# --- b) create five projects -------------------------------------------------

Write-Host ''
Write-Host 'CASE: b) create 5 projects (2 Cyrillic, 1 with a space)'
$caseOk = $true

foreach ($name in $ProjectNames) {
    $create = Invoke-Ps1 -ScriptPath $CreateProject -ScriptArgs @('-ProjectName', $name, '-TemplateType', 'full-stack')
    $ok = ($create.Exit -eq 0 -and (Test-PathDir (Join-Path $Root ('projects\' + $name))))
    if (-not $ok) { Write-Host ('    DIAG create ' + $name + ': exit=' + $create.Exit + ' out=' + $create.Out.Trim()) }
    $caseOk = (Write-Check ('create-project.ps1 created: ' + $name) $ok) -and $caseOk
}

$bufferPaths = @()
foreach ($name in $ProjectNames) { $bufferPaths += (Join-Path $Root ('projects\' + $name + '\CONTEXT-BUFFER.md')) }
$buffersExist = $true
foreach ($path in $bufferPaths) { if (-not (Test-PathLeaf $path)) { $buffersExist = $false } }
$caseOk = (Write-Check 'every project has its own CONTEXT-BUFFER.md' $buffersExist) -and $caseOk

Write-CaseResult 'b) create 5 projects' $caseOk

# --- c) per-project worktrees -------------------------------------------------

Write-Host ''
Write-Host 'CASE: c) per-project worktree (path keeps the name, branch is a valid ref)'
$caseOk = $true

$worktreePaths = @()
foreach ($name in $ProjectNames) { $worktreePaths += (Join-Path $Root ('.agents\worktrees\' + $name)) }

$wtExist = $true
foreach ($name in $ProjectNames) {
    if (-not (Test-PathDir (Join-Path $Root ('.agents\worktrees\' + $name)))) { $wtExist = $false; Write-Host ('    DIAG missing worktree for ' + $name) }
}
$caseOk = (Write-Check 'every project got its own worktree directory' $wtExist) -and $caseOk
$caseOk = (Write-Check 'worktree paths are pairwise distinct' ((Get-DistinctCount $worktreePaths) -eq 5)) -and $caseOk

$nameKept = $true
for ($i = 0; $i -lt 5; $i++) {
    if (-not $worktreePaths[$i].EndsWith($ProjectNames[$i])) { $nameKept = $false; Write-Host ('    DIAG worktree path lost the original name: ' + $worktreePaths[$i]) }
}
$caseOk = (Write-Check 'worktree path preserves the original (Cyrillic/space) name' $nameKept) -and $caseOk

$branches = @()
foreach ($name in $ProjectNames) { $branches += (Get-ProjectWorktreeBranch -Project $name) }
$caseOk = (Write-Check 'branches are pairwise distinct' ((Get-DistinctCount $branches) -eq 5)) -and $caseOk

$noWhitespace = $true
foreach ($branch in $branches) { if ($branch -match '\s') { $noWhitespace = $false } }
$caseOk = (Write-Check 'no branch contains whitespace (git refs forbid it)' $noWhitespace) -and $caseOk

$caseOk = (Write-Check ('Cyrillic project keeps its name in the branch: ' + $branches[0]) ($branches[0] -eq ('project/' + $Cyr1))) -and $caseOk
$caseOk = (Write-Check ('space project is encoded in the branch: ' + $branches[3]) ($branches[3] -eq 'project/soak%20beta')) -and $caseOk

$formatsOk = $true
if ($gitAvailable) {
    foreach ($branch in $branches) {
        $null = & git check-ref-format --branch $branch 2>&1
        if ($LASTEXITCODE -ne 0) { $formatsOk = $false; Write-Host ('    DIAG git rejected the branch name: ' + $branch) }
    }
}
$caseOk = (Write-Check 'git accepts every generated branch name' $formatsOk) -and $caseOk

if ($gitRepo) {
    $registeredOk = $true
    $branchOk = $true
    for ($i = 0; $i -lt 5; $i++) {
        $info = Get-ProjectWorktree -Project $ProjectNames[$i] -Root $Root
        if ($info.registered -ne $true) { $registeredOk = $false; Write-Host ('    DIAG not registered: ' + $ProjectNames[$i]) }
        if ([string]$info.registered_branch -ne $branches[$i]) { $branchOk = $false; Write-Host ('    DIAG branch mismatch for ' + $ProjectNames[$i] + ': got [' + $info.registered_branch + '] want [' + $branches[$i] + ']') }
    }
    $caseOk = (Write-Check 'every worktree is registered in the temporary repository' $registeredOk) -and $caseOk
    $caseOk = (Write-Check 'registration reports the exact branch (Cyrillic included)' $branchOk) -and $caseOk

    $again = New-ProjectWorktree -Project $Cyr1 -Root $Root
    $caseOk = (Write-Check 're-creating a Cyrillic worktree is idempotent' ($again.ok -eq $true)) -and $caseOk
} else {
    Write-Host '    WARN: git not available - registration assertions skipped'
}

Write-CaseResult 'c) per-project worktree' $caseOk

# --- d) CONTEXT-BUFFER isolation ---------------------------------------------

Write-Host ''
Write-Host 'CASE: d) per-project CONTEXT-BUFFER (leak guard, 5 x 5 matrix)'
$caseOk = $true

$caseOk = (Write-Check 'buffer paths are pairwise distinct' ((Get-DistinctCount $bufferPaths) -eq 5)) -and $caseOk
for ($i = 0; $i -lt 5; $i++) {
    $resolved = Get-ProjectContextBufferPath -Project $ProjectNames[$i] -Root $Root
    $caseOk = (Write-Check ('buffer resolver matches project ' + $ProjectNames[$i]) ($resolved -eq $bufferPaths[$i])) -and $caseOk
}

$notes = @()
$writeOk = $true
for ($i = 0; $i -lt 5; $i++) {
    $note = 'SOAK-NOTE-' + $i + '-' + [guid]::NewGuid().ToString('N')
    $notes += $note
    $res = Write-ProjectContextBuffer -Project $ProjectNames[$i] -Content ("`r`n" + $note + "`r`n") -SourceProject $ProjectNames[$i] -Root $Root
    if ($res.ok -ne $true) { $writeOk = $false; Write-Host ('    DIAG write failed for ' + $ProjectNames[$i] + ': ' + $res.reason) }
}
$caseOk = (Write-Check 'a unique note was appended to each of the 5 buffers' $writeOk) -and $caseOk

$leakFree = $true
for ($i = 0; $i -lt 5; $i++) {
    $text = [System.IO.File]::ReadAllText($bufferPaths[$i], $Utf8NoBom)
    if (-not (Test-ContainsText -Text $text -Needle $notes[$i])) { $leakFree = $false; Write-Host ('    DIAG buffer ' + $i + ' lost its own note') }
    for ($j = 0; $j -lt 5; $j++) {
        if ($j -eq $i) { continue }
        if (Test-ContainsText -Text $text -Needle $notes[$j]) { $leakFree = $false; Write-Host ('    DIAG LEAK: note of project ' + $j + ' found in buffer ' + $i) }
    }
}
$caseOk = (Write-Check 'each buffer holds exactly its own note (no leak in 20 cross checks)' $leakFree) -and $caseOk

$cross = Write-ProjectContextBuffer -Project $ProjectNames[1] -Content 'SOAK-CROSS-PROJECT' -SourceProject $ProjectNames[0] -Root $Root
$caseOk = (Write-Check 'cross-project write is refused' ($cross.ok -eq $false)) -and $caseOk
$caseOk = (Write-Check 'refusal names the cross-project violation' ($cross.reason -match 'cross-project')) -and $caseOk

$caseOk = (Write-Check 'foreign buffer is outside the project boundary' ((Test-ProjectPathBoundary -Project $ProjectNames[1] -Path $bufferPaths[0] -Root $Root) -eq $false)) -and $caseOk
$caseOk = (Write-Check 'foreign buffer is reported as a leak' ((Test-ProjectContextLeak -Project $ProjectNames[1] -Path $bufferPaths[0] -Root $Root) -eq $true)) -and $caseOk
$caseOk = (Write-Check 'own buffer is inside the boundary' ((Test-ProjectPathBoundary -Project $ProjectNames[1] -Path $bufferPaths[1] -Root $Root) -eq $true)) -and $caseOk

Write-CaseResult 'd) per-project CONTEXT-BUFFER' $caseOk

# --- e) queue per project ----------------------------------------------------

Write-Host ''
Write-Host 'CASE: e) queue binding per project'
$caseOk = $true

$queuePaths = @()
foreach ($name in $ProjectNames) { $queuePaths += (Join-Path $Root ('projects\' + $name + '\queue.json')) }
$caseOk = (Write-Check 'queue paths are pairwise distinct' ((Get-DistinctCount $queuePaths) -eq 5)) -and $caseOk

$addOk = $true
for ($i = 0; $i -lt 5; $i++) {
    $add = Invoke-Ps1 -ScriptPath $ProjectQueue -ScriptArgs @('-Add', '-Project', $ProjectNames[$i], '-Title', ('soak task for ' + $ProjectNames[$i]), '-Priority', 'normal')
    if ($add.Exit -ne 0) { $addOk = $false; Write-Host ('    DIAG add failed for ' + $ProjectNames[$i] + ': ' + $add.Out.Trim()) }
}
$caseOk = (Write-Check 'a task was added to each of the 5 queues (CLI exit 0)' $addOk) -and $caseOk

$bindingOk = $true
for ($i = 0; $i -lt 5; $i++) {
    $queue = Read-JsonFile $queuePaths[$i]
    $tasks = @()
    if ($null -ne $queue -and $null -ne $queue.tasks) { $tasks = @($queue.tasks) }
    if ($tasks.Count -ne 1) { $bindingOk = $false; Write-Host ('    DIAG queue ' + $i + ' has ' + $tasks.Count + ' task(s)'); continue }
    $task = $tasks[0]
    if ([string]$task.project -ne $ProjectNames[$i]) { $bindingOk = $false; Write-Host ('    DIAG task project mismatch in queue ' + $i + ': ' + $task.project) }
    if (-not (Test-ContainsText -Text ([string]$task.worktree) -Needle ('.agents\worktrees\' + $ProjectNames[$i]))) { $bindingOk = $false; Write-Host ('    DIAG task worktree does not match its project: ' + $task.worktree) }
    for ($j = 0; $j -lt 5; $j++) {
        if ($j -eq $i) { continue }
        if (Test-ContainsText -Text ([string]$task.worktree) -Needle $ProjectNames[$j]) { $bindingOk = $false; Write-Host ('    DIAG task of project ' + $i + ' points at project ' + $j) }
    }
}
$caseOk = (Write-Check 'each queue holds its own task bound to its own project/worktree' $bindingOk) -and $caseOk

Write-CaseResult 'e) queue binding per project' $caseOk

# --- f) claim independence across 5 scopes -----------------------------------

Write-Host ''
Write-Host 'CASE: f) claim independence (same task id in 5 project scopes)'
$caseOk = $true

$claimsDirs = @()
foreach ($name in $ProjectNames) { $claimsDirs += (Join-Path $Root ('projects\' + $name + '\.memory\claims')) }
$caseOk = (Write-Check 'claim directories are pairwise distinct' ((Get-DistinctCount $claimsDirs) -eq 5)) -and $caseOk

$claimOk = $true
for ($i = 0; $i -lt 5; $i++) {
    if (-not (Claim-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsDirs[$i])) { $claimOk = $false; Write-Host ('    DIAG claim tq-001 failed in scope ' + $i) }
}
$caseOk = (Write-Check 'the same task id is claimed independently in all 5 scopes' $claimOk) -and $caseOk

$filesOk = $true
$claimFiles = @()
for ($i = 0; $i -lt 5; $i++) {
    $file = Join-Path $claimsDirs[$i] 'tq-001.claim.json'
    $claimFiles += $file
    if (-not (Test-PathLeaf $file)) { $filesOk = $false; Write-Host ('    DIAG missing claim file ' + $i) }
}
$caseOk = (Write-Check '5 separate lease files exist' $filesOk) -and $caseOk
$caseOk = (Write-Check 'lease files are pairwise distinct' ((Get-DistinctCount $claimFiles) -eq 5)) -and $caseOk

$boundaryOk = $true
for ($i = 0; $i -lt 5; $i++) {
    if ((Test-ProjectPathBoundary -Project $ProjectNames[$i] -Path $claimFiles[$i] -Root $Root) -ne $true) { $boundaryOk = $false; Write-Host ('    DIAG own claim outside boundary: ' + $i) }
    for ($j = 0; $j -lt 5; $j++) {
        if ($j -eq $i) { continue }
        if ((Test-ProjectPathBoundary -Project $ProjectNames[$j] -Path $claimFiles[$i] -Root $Root) -ne $false) { $boundaryOk = $false; Write-Host ('    DIAG claim ' + $i + ' is inside the boundary of project ' + $j) }
    }
}
$caseOk = (Write-Check 'each lease is inside exactly one project boundary (20 cross checks)' $boundaryOk) -and $caseOk

# Completing the task in ONE project must release only that lease.
$complete = Invoke-Ps1 -ScriptPath $ProjectQueue -ScriptArgs @('-Complete', '-Project', $ProjectNames[0], '-Task', 'tq-001')
$caseOk = (Write-Check 'completing tq-001 in project 1 exits 0' ($complete.Exit -eq 0)) -and $caseOk
if ($complete.Exit -ne 0) { Write-Host ('    DIAG: ' + $complete.Out.Trim()) }
$caseOk = (Write-Check 'the lease of project 1 was released' (-not (Test-PathLeaf $claimFiles[0]))) -and $caseOk

$othersAlive = $true
for ($i = 1; $i -lt 5; $i++) { if (-not (Test-PathLeaf $claimFiles[$i])) { $othersAlive = $false; Write-Host ('    DIAG lease of project ' + $i + ' was released too') } }
$caseOk = (Write-Check 'the other 4 leases are untouched' $othersAlive) -and $caseOk

$reclaim = Claim-Task -TaskId 'tq-001' -Agent 'dev-1' -StateDir $claimsDirs[0]
$caseOk = (Write-Check 'project 1 can claim tq-001 again (no cross-project lock)' ($reclaim -eq $true)) -and $caseOk

Write-CaseResult 'f) claim independence' $caseOk

# --- g) pipeline: daemon -Drain across 5 agents -------------------------------

Write-Host ''
Write-Host 'CASE: g) daemon -Drain over 5 agents (no duplicates, correct outbox)'
$caseOk = $true

$inboxRoot = Join-Path $Root '.memory\inbox'
$outboxRoot = Join-Path $Root '.memory\outbox'
$archiveRoot = Join-Path $Root '.memory\archive'
$deadLetterRoot = Join-Path $Root '.memory\dead-letter'
$messageIds = @()

for ($i = 0; $i -lt 5; $i++) {
    $agentDir = Join-Path $inboxRoot $ProjectNames[$i]
    New-Directory $agentDir
    $messageId = 'soak-' + $i + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $messageIds += $messageId
    $message = [ordered]@{
        id       = $messageId
        from     = 'team-lead'
        to       = $ProjectNames[$i]
        type     = 'task'
        priority = 'normal'
        payload  = ('soak payload ' + $i)
    }
    $json = $message | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $agentDir ($messageId + '.json')), $json, $Utf8NoBom)
}
$caseOk = (Write-Check 'one queued message per agent (5 agents)' ((Get-JsonFileCountRecursive $inboxRoot) -eq 5)) -and $caseOk

$daemonRun = Invoke-Ps1 -ScriptPath $Daemon -ScriptArgs @('-Drain', '-ThrottleLimit', '5', '-MaxDurationSeconds', '120')
$caseOk = (Write-Check 'daemon -Drain exits 0' ($daemonRun.Exit -eq 0)) -and $caseOk
if ($daemonRun.Exit -ne 0) { Write-Host ('    DIAG daemon: ' + $daemonRun.Out.Trim()) }

$caseOk = (Write-Check 'outbox holds exactly 5 results (no duplicates)' ((Get-JsonFileCount $outboxRoot) -eq 5)) -and $caseOk

$outboxOk = $true
for ($i = 0; $i -lt 5; $i++) {
    $outboxFile = Join-Path $outboxRoot ($messageIds[$i] + '.json')
    $msg = Read-JsonFile $outboxFile
    if ($null -eq $msg) { $outboxOk = $false; Write-Host ('    DIAG missing outbox for ' + $messageIds[$i]); continue }
    if ([string]$msg.status -ne 'done') { $outboxOk = $false; Write-Host ('    DIAG status for ' + $messageIds[$i] + ': ' + $msg.status) }
    if ([string]$msg.id -ne $messageIds[$i]) { $outboxOk = $false; Write-Host ('    DIAG id mismatch in outbox ' + $messageIds[$i]) }
    if ([string]$msg.to -ne $ProjectNames[$i]) { $outboxOk = $false; Write-Host ('    DIAG wrong agent in outbox ' + $messageIds[$i] + ': ' + $msg.to) }
}
$caseOk = (Write-Check 'every message produced exactly one outbox result for its own agent' $outboxOk) -and $caseOk

$caseOk = (Write-Check 'dead-letter is empty' ((Get-JsonFileCount $deadLetterRoot) -eq 0)) -and $caseOk
$caseOk = (Write-Check 'the 5 consumed messages were archived' ((Get-JsonFileCount $archiveRoot) -eq 5)) -and $caseOk
$caseOk = (Write-Check 'inbox is empty afterwards' ((Get-JsonFileCountRecursive $inboxRoot) -eq 0)) -and $caseOk

$report = Read-JsonFile (Join-Path $Root '.memory\traces\daemon-last-run.json')
$reportOk = $false
if ($null -ne $report) {
    $reportOk = ([int]$report.processed -eq 5 -and [int]$report.deadLettered -eq 0 -and [int]$report.skipped -eq 0 -and [int]$report.remaining -eq 0)
}
$caseOk = (Write-Check 'daemon report: processed=5, deadLetter=0, skipped=0, remaining=0' $reportOk) -and $caseOk

$leftoverJobs = @(Get-Job -ErrorAction SilentlyContinue).Count
$caseOk = (Write-Check 'no background job left in this session' ($leftoverJobs -eq 0)) -and $caseOk

Write-CaseResult 'g) pipeline -Drain over 5 agents' $caseOk

# --- h) collision sweep + repository isolation -------------------------------

Write-Host ''
Write-Host 'CASE: h) no collisions at 5 scopes, real repository untouched'
$caseOk = $true

$projectDirs = @()
foreach ($name in $ProjectNames) { $projectDirs += (Join-Path $Root ('projects\' + $name)) }
$caseOk = (Write-Check '5 distinct project directories' ((Get-DistinctCount $projectDirs) -eq 5)) -and $caseOk
$caseOk = (Write-Check '5 distinct worktree directories' ((Get-DistinctCount $worktreePaths) -eq 5)) -and $caseOk
$caseOk = (Write-Check '5 distinct queue files' ((Get-DistinctCount $queuePaths) -eq 5)) -and $caseOk
$caseOk = (Write-Check '5 distinct claim directories' ((Get-DistinctCount $claimsDirs) -eq 5)) -and $caseOk
$caseOk = (Write-Check '5 distinct branches' ((Get-DistinctCount $branches) -eq 5)) -and $caseOk

$outsideRoot = $false
foreach ($path in @($projectDirs + $worktreePaths + $bufferPaths + $queuePaths + $claimsDirs)) {
    if (-not $path.StartsWith(($Root.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) { $outsideRoot = $true; Write-Host ('    DIAG path escaped the temp root: ' + $path) }
}
$caseOk = (Write-Check 'every path lives inside the isolated temp root' (-not $outsideRoot)) -and $caseOk

$syntheticOnly = $true
foreach ($name in @('soak-alpha', 'soak beta', 'soak-gamma')) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot ('projects\' + $name))) { $syntheticOnly = $false; Write-Host ('    DIAG synthetic project leaked into the repository: ' + $name) }
    if (Test-Path -LiteralPath (Join-Path $RepoRoot ('.agents\worktrees\' + $name))) { $syntheticOnly = $false; Write-Host ('    DIAG synthetic worktree leaked into the repository: ' + $name) }
}
$caseOk = (Write-Check 'no synthetic project/worktree leaked into the repository' $syntheticOnly) -and $caseOk

if ($gitAvailable) {
    $projectWtListAfter = (@(& git -C $RepoRoot worktree list --porcelain 2>$null) -join "`n")
    $caseOk = (Write-Check 'the real repository worktree list is unchanged' ($projectWtListAfter -eq $projectWtListBefore)) -and $caseOk
}

Write-CaseResult 'h) collision sweep + isolation' $caseOk

# --- summary + cleanup --------------------------------------------------------

$total = $script:Pass + $script:Fail
Write-Host ''
Write-Host '=================================================='
Write-Host ('SUMMARY: passed=' + $script:Pass + ' failed=' + $script:Fail + ' total=' + $total)
Write-Host '=================================================='

foreach ($name in $ProjectNames) {
    try { $null = Remove-ProjectWorktree -Project $name -Root $Root } catch { }
}
if ($gitAvailable) { $null = & git -C $Root worktree prune 2>&1 }

foreach ($varName in @('AGENT_HQ_ROOT', 'AGENT_HQ_OPENCODE', 'FAKE_OPENCODE_MODE')) {
    Remove-Item -Path ('Env:\' + $varName) -ErrorAction SilentlyContinue
}
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

$rootRemoved = Remove-DirectoryWithRetry -Path $Root
$baseRemoved = Remove-DirectoryWithRetry -Path $TempBase
Write-Host ('cleanup: root removed=' + $rootRemoved + ', temp base removed=' + $baseRemoved)

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
