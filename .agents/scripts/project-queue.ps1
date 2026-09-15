# project-queue.ps1 - CLI task queue management for projects
# US-013 Project Queue
#
# Parameters:
#   -Add -Project <name> -Title "<task>" [-Priority critical|high|normal|low] [-Agent <name>]
#   -List -Project <name> [-Status queued|assigned|in_progress|done|dead]
#   -Next -Project <name>
#   -Complete -Project <name> -Task <id>
#   -Dead -Project <name> -Task <id> -Reason "<why>"
#   -Stats -Project <name>
#   -StaleCheck -Project <name>

param(
    [switch]$Add,
    [switch]$List,
    [switch]$Next,
    [switch]$Complete,
    [switch]$Dead,
    [switch]$Stats,
    [switch]$StaleCheck,
    [string]$Project,
    [string]$Title,
    [string]$Priority = "normal",
    [string]$Agent,
    [string]$Task,
    [string]$Reason,
    [string]$Status
)

$ErrorActionPreference = "Stop"

# --------------------------------------------------
# Path resolution: script is in .agents/scripts/
# Project root is two levels up
# --------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent

$ProjectsRoot = Join-Path $projectRoot "projects"

# UTF-8 without BOM encoding
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Priority ordering: lower number = higher priority
$PriorityOrder = @{
    "critical" = 0
    "high"     = 1
    "normal"   = 2
    "low"      = 3
}

# --------------------------------------------------
# Helper: Get queue.json path for project
# --------------------------------------------------
function Get-QueuePath {
    param([string]$ProjectName)
    # Security: whitelist project name + path traversal guard
    if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
        throw "Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $ProjectsRoot "$ProjectName\queue.json"))
    $rootFull = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path traversal detected: '$ProjectName' escapes projects root"
    }
    return $full
}

# --------------------------------------------------
# Helper: Get list of existing project names
# --------------------------------------------------
function Get-ExistingProjects {
    $projects = @()
    if (Test-Path $ProjectsRoot) {
        $dirs = Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $projects += $d.Name
        }
    }
    return $projects
}

# --------------------------------------------------
# Helper: Load queue JSON
# Returns PSCustomObject with .tasks array
# --------------------------------------------------
function Load-Queue {
    param([string]$ProjectName)

    $queuePath = Get-QueuePath -ProjectName $ProjectName

    if (-not (Test-Path $queuePath)) {
        $existing = Get-ExistingProjects
        if ($existing.Count -gt 0) {
            Write-Error "Queue file not found: $queuePath`nExisting projects: $($existing -join ', ')"
        } else {
            Write-Error "Queue file not found: $queuePath`nNo projects found in $ProjectsRoot"
        }
        return $null
    }

    try {
        $content = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom)
        $queue = $content | ConvertFrom-Json
        # Ensure tasks array exists
        if (-not $queue.tasks) {
            $queue | Add-Member -MemberType NoteProperty -Name "tasks" -Value @() -Force
        }
        return $queue
    } catch {
        Write-Error "Failed to parse queue JSON for project '$ProjectName': $_"
        return $null
    }
}

# --------------------------------------------------
# Helper: Save queue JSON with backup and validation
# Creates .bak before writing, writes UTF-8 no BOM,
# validates after write, restores from .bak on failure.
# --------------------------------------------------
function Save-Queue {
    param(
        [string]$ProjectName,
        [object]$data
    )

    $queuePath = Get-QueuePath -ProjectName $ProjectName

    # 1. Create backup before writing
    if (Test-Path $queuePath) {
        $bakPath = $queuePath + ".bak"
        try {
            Copy-Item -Path $queuePath -Destination $bakPath -Force -ErrorAction Stop
        } catch {
            # Backup creation failure is not fatal; proceed to write
        }
    }

    # 2. Serialize to JSON
    $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress

    # 3. Write with exclusive lock and UTF-8 no BOM
    $handle = [System.IO.File]::Open($queuePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
        $writer.Write($jsonContent)
        $writer.Flush()
    } finally {
        $handle.Close()
    }

    # 4. Validate JSON after write
    try {
        $null = [System.IO.File]::ReadAllText($queuePath, $utf8NoBom) | ConvertFrom-Json
        return $true
    } catch {
        # 5. Restore from backup if JSON is invalid
        # NOTE: Write-Warning (НЕ Write-Error) — при $ErrorActionPreference="Stop"
        # Write-Error terminating-ошибка, которая прервёт скрипт раньше return $false
        $bakPath = $queuePath + ".bak"
        if (Test-Path $bakPath) {
            try {
                Copy-Item -Path $bakPath -Destination $queuePath -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to restore queue from backup: $_"
            }
        }
        Write-Warning "Queue JSON invalid after write, restored from backup"
        return $false
    }
}

# --------------------------------------------------
# Helper: Generate next task ID (tq-NNN)
# --------------------------------------------------
function Get-NextTaskId {
    param([object]$Queue)

    $maxNum = 0
    if ($Queue.tasks -and $Queue.tasks.Count -gt 0) {
        foreach ($t in $Queue.tasks) {
            if ($t.id -match "^tq-(\d+)$") {
                $num = [int]$Matches[1]
                if ($num -gt $maxNum) { $maxNum = $num }
            }
        }
    }
    $nextNum = $maxNum + 1
    return "tq-{0:D3}" -f $nextNum
}

# --------------------------------------------------
# Helper: Get current ISO timestamp
# --------------------------------------------------
function Get-Now {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
}

# --------------------------------------------------
# Helper: Validate priority
# --------------------------------------------------
function Test-ValidPriority {
    param([string]$P)
    return ($P -eq "critical" -or $P -eq "high" -or $P -eq "normal" -or $P -eq "low")
}

# --------------------------------------------------
# Helper: Validate status
# --------------------------------------------------
function Test-ValidStatus {
    param([string]$S)
    return ($S -eq "queued" -or $S -eq "assigned" -or $S -eq "in_progress" -or $S -eq "done" -or $S -eq "dead")
}

# --------------------------------------------------
# -Add: Add a task to the queue
# --------------------------------------------------
function Add-Task {
    param(
        [string]$ProjectName,
        [string]$TaskTitle,
        [string]$TaskPriority,
        [string]$TaskAgent
    )

    if (-not (Test-ValidPriority $TaskPriority)) {
        Write-Error "Invalid priority '$TaskPriority'. Must be one of: critical, high, normal, low"
        exit 1
    }

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $taskId = Get-NextTaskId -Queue $queue
    $now = Get-Now

    $taskObj = [PSCustomObject]@{
        id              = $taskId
        title           = $TaskTitle
        priority        = $TaskPriority
        status          = if ($TaskAgent) { "assigned" } else { "queued" }
        assigned_agent  = $TaskAgent
        created_at      = $now
        started_at      = $null
        completed_at    = $null
        retries         = 0
    }

    # Add to tasks array
    $tasksList = @($queue.tasks)
    $tasksList += $taskObj
    $queue.tasks = $tasksList

    if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
        Write-Error "Failed to save queue after adding task"
        exit 1
    }

    Write-Output "Task '$taskId' added to project '$ProjectName' (priority: $TaskPriority, status: $($taskObj.status))"
}

# --------------------------------------------------
# -List: List tasks in the queue
# --------------------------------------------------
function List-Tasks {
    param(
        [string]$ProjectName,
        [string]$FilterStatus
    )

    if ($FilterStatus -and -not (Test-ValidStatus $FilterStatus)) {
        Write-Error "Invalid status '$FilterStatus'. Must be one of: queued, assigned, in_progress, done, dead"
        exit 1
    }

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $tasks = @($queue.tasks)

    # Filter by status if specified
    if ($FilterStatus) {
        $tasks = $tasks | Where-Object { $_.status -eq $FilterStatus }
    }

    if ($tasks.Count -eq 0) {
        Write-Output "No tasks found$(if ($FilterStatus) { " with status '$FilterStatus'" }) in project '$ProjectName'"
        return
    }

    Write-Output "Id | Priority | Status | Agent | Title"
    Write-Output "--- | --- | --- | --- | ---"
    foreach ($t in $tasks) {
        $agent = if ($t.assigned_agent) { $t.assigned_agent } else { "" }
        Write-Output "$($t.id) | $($t.priority) | $($t.status) | $agent | $($t.title)"
    }
}

# --------------------------------------------------
# -Next: Get next task by priority (critical > high > normal > low, FIFO within same priority)
# Sets status to in_progress, sets started_at, outputs task JSON
# --------------------------------------------------
function Get-NextTask {
    param([string]$ProjectName)

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    # Filter to queued or assigned tasks only
    $pending = @($queue.tasks | Where-Object { $_.status -eq "queued" -or $_.status -eq "assigned" })

    if ($pending.Count -eq 0) {
        Write-Output "No pending tasks in project '$ProjectName'"
        return
    }

    # Sort by priority (lower number = higher priority), then by created_at (FIFO)
    $sorted = $pending | Sort-Object {
        $prio = $PriorityOrder[$_.priority]
        if ($null -eq $prio) { 99 } else { $prio }
    }, { $_.created_at }

    $nextTask = $sorted[0]

    # Update task in queue
    $nextTask.status = "in_progress"
    $nextTask.started_at = Get-Now

    # Save queue
    if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
        Write-Error "Failed to save queue after taking next task"
        exit 1
    }

    # Output task as JSON
    $nextTask | ConvertTo-Json -Depth 10 -Compress
}

# --------------------------------------------------
# -Complete: Mark task as done, release agent if assigned
# --------------------------------------------------
function Complete-Task {
    param(
        [string]$ProjectName,
        [string]$TaskId
    )

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $found = $false
    foreach ($t in $queue.tasks) {
        if ($t.id -eq $TaskId) {
            $t.status = "done"
            $t.completed_at = Get-Now

            # Release agent if one was assigned
            if ($t.assigned_agent) {
                $agentRegistryPath = Join-Path $scriptDir "agent-registry.ps1"
                if (Test-Path $agentRegistryPath) {
                    try {
                        & $agentRegistryPath -Release -Agent $t.assigned_agent
                    } catch {
                        Write-Warning "Failed to release agent '$($t.assigned_agent)': $_"
                    }
                } else {
                    Write-Warning "agent-registry.ps1 not found at $agentRegistryPath, skipping agent release"
                }
            }

            $found = $true
            break
        }
    }

    if (-not $found) {
        Write-Error "Task '$TaskId' not found in project '$ProjectName'"
        exit 1
    }

    if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
        Write-Error "Failed to save queue after completing task"
        exit 1
    }

    Write-Output "Task '$TaskId' marked as done in project '$ProjectName'"
}

# --------------------------------------------------
# -Dead: Mark task as dead with reason
# --------------------------------------------------
function Dead-Task {
    param(
        [string]$ProjectName,
        [string]$TaskId,
        [string]$TaskReason
    )

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $found = $false
    foreach ($t in $queue.tasks) {
        if ($t.id -eq $TaskId) {
            $t.status = "dead"
            $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value $TaskReason -Force
            $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
            $found = $true
            break
        }
    }

    if (-not $found) {
        Write-Error "Task '$TaskId' not found in project '$ProjectName'"
        exit 1
    }

    if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
        Write-Error "Failed to save queue after marking task dead"
        exit 1
    }

    Write-Output "Task '$TaskId' marked as dead in project '$ProjectName' (reason: $TaskReason)"
}

# --------------------------------------------------
# -Stats: Show task counts by status
# --------------------------------------------------
function Show-Stats {
    param([string]$ProjectName)

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $counts = @{
        "queued"      = 0
        "assigned"    = 0
        "in_progress" = 0
        "done"        = 0
        "dead"        = 0
    }

    foreach ($t in $queue.tasks) {
        if ($counts.ContainsKey($t.status)) {
            $counts[$t.status]++
        }
    }

    Write-Output "Status | Count"
    Write-Output "--- | ---"
    foreach ($key in @("queued", "assigned", "in_progress", "done", "dead")) {
        Write-Output "$key | $($counts[$key])"
    }
    Write-Output "total | $($queue.tasks.Count)"
}

# --------------------------------------------------
# -StaleCheck: Find in_progress tasks older than 15 min
# retries < 2 -> retries++, status = queued, started_at = null
# retries >= 2 -> status = dead
# --------------------------------------------------
function Invoke-StaleCheck {
    param([string]$ProjectName)

    $queue = Load-Queue -ProjectName $ProjectName
    if (-not $queue) { exit 1 }

    $now = Get-Date
    $staleThreshold = New-TimeSpan -Minutes 15
    $changed = 0

    foreach ($t in $queue.tasks) {
        if ($t.status -ne "in_progress") { continue }
        if (-not $t.started_at) { continue }

        try {
            $startedAt = [DateTime]::Parse($t.started_at)
        } catch {
            continue
        }

        $elapsed = $now - $startedAt
        if ($elapsed -gt $staleThreshold) {
            $retries = [int]$t.retries

            if ($retries -ge 2) {
                # Max retries reached -> dead
                $t.status = "dead"
                $t | Add-Member -MemberType NoteProperty -Name "dead_reason" -Value "Stale: exceeded max retries (2) after 15min timeout" -Force
                $t | Add-Member -MemberType NoteProperty -Name "dead_at" -Value (Get-Now) -Force
                Write-Output "Task '$($t.id)' marked dead (max retries reached)"
            } else {
                # Retry: back to queued
                $t.retries = $retries + 1
                $t.status = "queued"
                $t.started_at = $null
                Write-Output "Task '$($t.id)' stale (>15min), retries=$($t.retries), moved back to queue"
            }
            $changed++
        }
    }

    if ($changed -eq 0) {
        Write-Output "No stale tasks found in project '$ProjectName'"
        return
    }

    if (-not (Save-Queue -ProjectName $ProjectName -Data $queue)) {
        Write-Error "Failed to save queue after stale check"
        exit 1
    }

    Write-Output "Stale check complete: $changed task(s) processed in project '$ProjectName'"
}

# --------------------------------------------------
# Main dispatch
# --------------------------------------------------

if ($Add) {
    if (-not $Project -or -not $Title) {
        Write-Error "Add requires -Project and -Title parameters"
        exit 1
    }
    if (-not (Test-ValidPriority $Priority)) {
        Write-Error "Invalid priority '$Priority'. Must be one of: critical, high, normal, low"
        exit 1
    }
    Add-Task -ProjectName $Project -TaskTitle $Title -TaskPriority $Priority -TaskAgent $Agent
    exit 0
}

if ($List) {
    if (-not $Project) {
        Write-Error "List requires -Project parameter"
        exit 1
    }
    List-Tasks -ProjectName $Project -FilterStatus $Status
    exit 0
}

if ($Next) {
    if (-not $Project) {
        Write-Error "Next requires -Project parameter"
        exit 1
    }
    Get-NextTask -ProjectName $Project
    exit 0
}

if ($Complete) {
    if (-not $Project -or -not $Task) {
        Write-Error "Complete requires -Project and -Task parameters"
        exit 1
    }
    Complete-Task -ProjectName $Project -TaskId $Task
    exit 0
}

if ($Dead) {
    if (-not $Project -or -not $Task) {
        Write-Error "Dead requires -Project and -Task parameters"
        exit 1
    }
    if (-not $Reason) {
        Write-Error "Dead requires -Reason parameter"
        exit 1
    }
    Dead-Task -ProjectName $Project -TaskId $Task -TaskReason $Reason
    exit 0
}

if ($Stats) {
    if (-not $Project) {
        Write-Error "Stats requires -Project parameter"
        exit 1
    }
    Show-Stats -ProjectName $Project
    exit 0
}

if ($StaleCheck) {
    if (-not $Project) {
        Write-Error "StaleCheck requires -Project parameter"
        exit 1
    }
    Invoke-StaleCheck -ProjectName $Project
    exit 0
}

# Default: show usage
Write-Output "Usage:"
Write-Output "  project-queue.ps1 -Add -Project <name> -Title ""<task>"" [-Priority critical|high|normal|low] [-Agent <name>]"
Write-Output "  project-queue.ps1 -List -Project <name> [-Status queued|assigned|in_progress|done|dead]"
Write-Output "  project-queue.ps1 -Next -Project <name>"
Write-Output "  project-queue.ps1 -Complete -Project <name> -Task <id>"
Write-Output "  project-queue.ps1 -Dead -Project <name> -Task <id> -Reason ""<why>"""
Write-Output "  project-queue.ps1 -Stats -Project <name>"
Write-Output "  project-queue.ps1 -StaleCheck -Project <name>"
exit 1
