# agent-utilization.ps1 - Agent utilization metrics and audit log
# US-014 Resource Awareness
#
# Parameters:
#   -Json                    Output metrics as JSON (machine-readable)
#   -Watch [-IntervalSec N]  Live dashboard mode (default 30s interval)
#   -LogAssignment           Log an assignment to agent-assignments.jsonl
#     -Agent <name>          Agent name
#     -Project <name>        Project name
#     -Task <id>             Task ID
#
# Reads: .memory/agent-registry.json
# Writes: .memory/agent-assignments.jsonl (append, UTF-8 no BOM)

param(
    [switch]$Json,
    [switch]$Watch,
    [int]$IntervalSec = 30,
    [switch]$LogAssignment,
    [string]$Agent,
    [string]$Project,
    [string]$Task
)

$ErrorActionPreference = "Stop"

# --------------------------------------------------
# Path resolution: script is in .agents/scripts/
# Project root is two levels up
# --------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent

$RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
$AssignmentsPath = Join-Path $projectRoot ".memory\agent-assignments.jsonl"
$ProjectsDir = Join-Path $projectRoot "projects"

# UTF-8 without BOM encoding
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --------------------------------------------------
# Helper: Load registry JSON
# --------------------------------------------------
function Load-Registry {
    if (-not (Test-Path $RegistryPath)) {
        Write-Error "Registry file not found: $RegistryPath"
        return $null
    }
    try {
        $content = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom)
        $registry = $content | ConvertFrom-Json
        return $registry
    } catch {
        Write-Error "Failed to parse registry JSON: $_"
        return $null
    }
}

# --------------------------------------------------
# Helper: Enumerate projects dynamically from projects/ dir
# --------------------------------------------------
function Get-ProjectNames {
    $names = @()
    if (Test-Path $ProjectsDir) {
        $dirs = Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $names += $d.Name
        }
    }
    return $names
}

# --------------------------------------------------
# Compute utilization metrics
# Returns PSCustomObject with all metrics
# --------------------------------------------------
function Get-UtilizationMetrics {
    $registry = Load-Registry
    if (-not $registry) {
        return $null
    }

    $allAgents = @()
    foreach ($name in $registry.agents.PSObject.Properties.Name) {
        $allAgents += $registry.agents.$name
    }

    $total = $allAgents.Count
    $busy = ($allAgents | Where-Object { $_.status -eq "busy" }).Count
    $free = ($allAgents | Where-Object { $_.status -eq "free" }).Count
    $errorCount = ($allAgents | Where-Object { $_.status -eq "error" }).Count

    if ($total -gt 0) {
        $utilizationPct = [math]::Round(($busy / $total) * 100, 1)
    } else {
        $utilizationPct = 0
    }

    # By project: count busy agents per current_project
    $byProject = @{}
    foreach ($a in $allAgents) {
        if ($a.status -eq "busy" -and $a.current_project) {
            $proj = $a.current_project
            if (-not $byProject.ContainsKey($proj)) {
                $byProject[$proj] = 0
            }
            $byProject[$proj]++
        }
    }

    # Free agents by specialization/role
    $freeBySpec = @{}
    foreach ($a in $allAgents) {
        if ($a.status -eq "free") {
            $role = $a.role
            if (-not $freeBySpec.ContainsKey($role)) {
                $freeBySpec[$role] = 0
            }
            $freeBySpec[$role]++
        }
    }

    # Alerts
    $alerts = @()
    if ($utilizationPct -lt 50) {
        $alerts += "UNDERUTILIZED: utilization ${utilizationPct}% < 50% threshold"
    }
    if ($utilizationPct -gt 90) {
        $alerts += "OVERLOADED: utilization ${utilizationPct}% > 90% threshold"
    }

    $metrics = [PSCustomObject]@{
        total               = $total
        busy                = $busy
        free                = $free
        error               = $errorCount
        utilization_pct     = $utilizationPct
        by_project          = $byProject
        free_by_specialization = $freeBySpec
        alerts              = $alerts
    }

    return $metrics
}

# --------------------------------------------------
# Render text dashboard
# --------------------------------------------------
function Show-TextDashboard {
    $metrics = Get-UtilizationMetrics
    if (-not $metrics) {
        Write-Output "ERROR: Could not load agent registry"
        return
    }

    Write-Output ""
    Write-Output "=== AGENT UTILIZATION DASHBOARD ==="
    Write-Output ""

    # Summary
    Write-Output "Total: $($metrics.total) | Busy: $($metrics.busy) | Free: $($metrics.free) | Error: $($metrics.error)"
    Write-Output "Utilization: $($metrics.utilization_pct)%"
    Write-Output ""

    # By project
    Write-Output "--- Busy Agents by Project ---"
    if ($metrics.by_project.Count -eq 0) {
        Write-Output "  (no busy agents)"
    } else {
        foreach ($proj in ($metrics.by_project.Keys | Sort-Object)) {
            $count = $metrics.by_project[$proj]
            Write-Output "  $proj : $count agent(s)"
        }
    }
    Write-Output ""

    # Free by specialization
    Write-Output "--- Free Agents by Role ---"
    if ($metrics.free_by_specialization.Count -eq 0) {
        Write-Output "  (no free agents)"
    } else {
        foreach ($role in ($metrics.free_by_specialization.Keys | Sort-Object)) {
            $count = $metrics.free_by_specialization[$role]
            Write-Output "  $role : $count"
        }
    }
    Write-Output ""

    # Alerts
    if ($metrics.alerts.Count -gt 0) {
        Write-Output "--- ALERTS ---"
        foreach ($alert in $metrics.alerts) {
            Write-Output "  [!] $alert"
        }
        Write-Output ""
    }

    # Recent assignments (last 5)
    Show-RecentAssignments -Count 5
}

# --------------------------------------------------
# Show last N assignment log entries
# --------------------------------------------------
function Show-RecentAssignments {
    param([int]$Count = 5)

    if (-not (Test-Path $AssignmentsPath)) {
        return
    }

    try {
        $content = [System.IO.File]::ReadAllText($AssignmentsPath, $utf8NoBom)
        $lines = $content -split "`n" | Where-Object { $_.Trim() -ne "" }

        if ($lines.Count -eq 0) {
            return
        }

        $recent = $lines | Select-Object -Last $Count

        Write-Output "--- Recent Assignments (last $($recent.Count)) ---"
        Write-Output "  Time | Agent | Project | Task"
        Write-Output "  ---- | ---- | ---- | ----"

        foreach ($line in $recent) {
            try {
                $entry = $line | ConvertFrom-Json
                $ts = if ($entry.ts) { $entry.ts } else { "?" }
                $agentName = if ($entry.agent) { $entry.agent } else { "?" }
                $proj = if ($entry.project) { $entry.project } else { "?" }
                $taskId = if ($entry.task) { $entry.task } else { "?" }
                Write-Output "  $ts | $agentName | $proj | $taskId"
            } catch {
                # Skip malformed lines
            }
        }
        Write-Output ""
    } catch {
        # File read error; skip
    }
}

# --------------------------------------------------
# Log an assignment to agent-assignments.jsonl
# --------------------------------------------------
function Write-AssignmentLog {
    param([string]$AgentName, [string]$ProjectName, [string]$TaskId)

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    $entry = [PSCustomObject]@{
        ts      = $timestamp
        agent   = $AgentName
        project = $ProjectName
        task    = $TaskId
    }

    $jsonLine = $entry | ConvertTo-Json -Compress

    # Ensure parent directory exists
    $parentDir = Split-Path $AssignmentsPath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Append with UTF-8 no BOM
    $appendText = $jsonLine + "`n"
    $bytes = $utf8NoBom.GetBytes($appendText)

    if (Test-Path $AssignmentsPath) {
        $fs = [System.IO.File]::Open($AssignmentsPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    } else {
        $fs = [System.IO.File]::Open($AssignmentsPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }

    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally {
        $fs.Close()
    }

    Write-Output "Assignment logged: $AgentName -> $ProjectName / $TaskId at $timestamp"
}

# --------------------------------------------------
# Main dispatch
# --------------------------------------------------

if ($LogAssignment) {
    if (-not $Agent -or -not $Project -or -not $Task) {
        Write-Error "LogAssignment requires -Agent, -Project, and -Task parameters"
        exit 1
    }
    Write-AssignmentLog -AgentName $Agent -ProjectName $Project -TaskId $Task
    exit 0
}

if ($Watch) {
    # Live dashboard mode
    try {
        while ($true) {
            Clear-Host
            $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Output "Agent Utilization Dashboard | Refreshing every ${IntervalSec}s | $now"
            Show-TextDashboard
            Start-Sleep -Seconds $IntervalSec
        }
    } catch {
        # Ctrl+C exits gracefully
        Write-Output ""
        Write-Output "Dashboard stopped."
    }
    exit 0
}

if ($Json) {
    $metrics = Get-UtilizationMetrics
    if (-not $metrics) {
        Write-Output '{"error":"Could not load registry"}'
        exit 1
    }
    $metrics | ConvertTo-Json -Depth 10 -Compress
    exit 0
}

# Default: text dashboard
Show-TextDashboard
exit 0
