# agent-registry.ps1 - CLI management for agent-registry.json
# US-012 Dynamic Agent Pool
#
# Parameters:
#   -Init                              Regenerate registry from .opencode/agents/registry.json
#   -List [-Status free|busy|error] [-Json]  List agents
#   -Reserve -Agent <name> -Project <project> -Task <taskId>  Reserve an agent
#   -Release -Agent <name>             Release an agent
#   -SetStatus -Agent <name> -Status <free|busy|error>  Set status manually
#   -Acquire -Specialization <sp1,sp2> -Project <name>  Auto-acquire best agent

param(
    [switch]$Init,
    [switch]$List,
    [string]$Status,
    [switch]$Json,
    [switch]$Reserve,
    [string]$Agent,
    [string]$Project,
    [string]$Task,
    [switch]$Release,
    [switch]$SetStatus,
    [switch]$Acquire,
    [string]$Specialization
)

$ErrorActionPreference = "Stop"

# --------------------------------------------------
# Path resolution: script is in .agents/scripts/
# Project root is two levels up
# --------------------------------------------------
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent

$RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
$BackupPath = $RegistryPath + ".bak"
$RatingsPath = Join-Path $projectRoot ".memory\ratings.jsonl"
$SourceRegistryPath = Join-Path $projectRoot ".opencode\agents\registry.json"

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
# Helper: Save registry JSON with backup and validation
# Creates .bak before writing, writes UTF-8 no BOM,
# validates after write, restores from .bak on failure.
# Uses exclusive file handle during write.
# --------------------------------------------------
function Save-Registry {
    param([object]$data)

    # 1. Create backup before writing
    if (Test-Path $RegistryPath) {
        try {
            Copy-Item -Path $RegistryPath -Path $BackupPath -Force -ErrorAction Stop
        } catch {
            # Backup creation failure is not fatal; proceed to write
        }
    }

    # 2. Serialize to JSON
    $jsonContent = $data | ConvertTo-Json -Depth 10 -Compress

    # 3. Write with exclusive lock (FileShare None) and UTF-8 no BOM
    $handle = [System.IO.File]::Open($RegistryPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($handle, $utf8NoBom)
        $writer.Write($jsonContent)
        $writer.Flush()
    } finally {
        $handle.Close()
    }

    # 4. Validate JSON after write
    try {
        $null = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom) | ConvertFrom-Json
        return $true
    } catch {
        # 5. Restore from backup if JSON is invalid
        if (Test-Path $BackupPath) {
            try {
                Copy-Item -Path $BackupPath -Path $RegistryPath -Force -ErrorAction Stop
            } catch {
                Write-Error "Failed to restore registry from backup"
            }
        }
        Write-Error "Registry JSON invalid after write, restored from backup"
        return $false
    }
}

# --------------------------------------------------
# Helper: Read ratings from .memory/ratings.jsonl
# Returns hashtable: agent_name -> average grade (double)
# Each line is a JSON object with "agent" and "grade" fields
# --------------------------------------------------
function Get-AgentRatings {
    $ratings = @{}

    if (-not (Test-Path $RatingsPath)) {
        return $ratings
    }

    try {
        $content = [System.IO.File]::ReadAllText($RatingsPath, $utf8NoBom)
        $lines = $content -split "`n" | Where-Object { $_.Trim() -ne "" }

        $agentGrades = @{}

        foreach ($line in $lines) {
            try {
                $obj = $line | ConvertFrom-Json
                $agentName = $obj.agent
                $grade = [double]$obj.grade

                if ($agentName) {
                    if (-not $agentGrades.ContainsKey($agentName)) {
                        $agentGrades[$agentName] = @()
                    }
                    $agentGrades[$agentName] += $grade
                }
            } catch {
                # Skip malformed lines
            }
        }

        # Compute averages
        foreach ($agentName in $agentGrades.Keys) {
            $grades = $agentGrades[$agentName]
            $sum = 0.0
            foreach ($g in $grades) { $sum += $g }
            $ratings[$agentName] = $sum / $grades.Count
        }
    } catch {
        # File read error; return empty ratings
    }

    return $ratings
}

# --------------------------------------------------
# List agents
# --------------------------------------------------
function List-Agents {
    param([string]$FilterStatus)

    $registry = Load-Registry
    if (-not $registry) {
        return
    }

    $agents = @()
    foreach ($name in $registry.agents.PSObject.Properties.Name) {
        $agent = $registry.agents.$name
        $agents += $agent
    }

    # Filter by status if specified
    if ($FilterStatus) {
        $agents = $agents | Where-Object { $_.status -eq $FilterStatus }
    }

    if ($Json) {
        $output = @{agents = $agents}
        $output | ConvertTo-Json -Depth 10 -Compress
    } else {
        Write-Output "Name | Status | Project | Task"
        Write-Output "---- | ---- | ---- | ----"
        foreach ($agent in $agents) {
            $project = if ($agent.current_project) { $agent.current_project } else { "" }
            $task = if ($agent.current_task) { $agent.current_task } else { "" }
            Write-Output "$($agent.name) | $($agent.status) | $project | $task"
        }
    }
}

# --------------------------------------------------
# Reserve agent: free -> busy + project + task + last_assignment + daily_load++
# --------------------------------------------------
function Reserve-Agent {
    param([string]$AgentName, [string]$ProjectName, [string]$TaskId)

    $registry = Load-Registry
    if (-not $registry) {
        Write-Error "Could not load registry"
        exit 1
    }

    if (-not $registry.agents.PSObject.Properties[$AgentName]) {
        Write-Error "Agent '$AgentName' not found in registry"
        exit 1
    }

    $agent = $registry.agents.$AgentName

    if ($agent.status -ne "free") {
        Write-Error "Agent '$AgentName' is not free (status: $($agent.status))"
        exit 1
    }

    $agent.status = "busy"
    $agent.current_project = $ProjectName
    $agent.current_task = $TaskId
    $agent.last_assignment = "$ProjectName-$TaskId"
    $agent.daily_load++

    if (-not (Save-Registry $registry)) {
        $agent.status = "free"
        $agent.current_project = $null
        $agent.current_task = $null
        $agent.last_assignment = $null
        $agent.daily_load--
        Write-Error "Failed to save registry, rolled back"
        exit 1
    }

    Write-Output "Agent '$AgentName' reserved for project '$ProjectName', task '$TaskId'"
}

# --------------------------------------------------
# Release agent: sets free, cleans project/task
# --------------------------------------------------
function Release-Agent {
    param([string]$AgentName)

    $registry = Load-Registry
    if (-not $registry) {
        exit 1
    }

    if (-not $registry.agents.PSObject.Properties[$AgentName]) {
        Write-Error "Agent '$AgentName' not found in registry"
        exit 1
    }

    $agent = $registry.agents.$AgentName

    $agent.status = "free"
    $agent.current_project = $null
    $agent.current_task = $null
    $agent.last_assignment = $null
    # daily_load not decremented (daily counter)

    if (-not (Save-Registry $registry)) {
        Write-Error "Failed to save registry after release"
        exit 1
    }

    Write-Output "Agent '$AgentName' released, status set to free"
}

# --------------------------------------------------
# Set status for agent
# --------------------------------------------------
function Set-Status-Agent {
    param([string]$AgentName, [string]$NewStatus)

    if ($NewStatus -ne "free" -and $NewStatus -ne "busy" -and $NewStatus -ne "error") {
        Write-Error "Invalid status '$NewStatus'. Must be one of: free, busy, error"
        exit 1
    }

    $registry = Load-Registry
    if (-not $registry) {
        exit 1
    }

    if (-not $registry.agents.PSObject.Properties[$AgentName]) {
        Write-Error "Agent '$AgentName' not found in registry"
        exit 1
    }

    $agent = $registry.agents.$AgentName
    $agent.status = $NewStatus

    if (-not (Save-Registry $registry)) {
        Write-Error "Failed to save registry"
        exit 1
    }

    Write-Output "Agent '$AgentName' status set to '$NewStatus'"
}

# --------------------------------------------------
# Init: regenerate registry from .opencode/agents/registry.json
# Preserves daily_load and last_assignment from existing registry
# --------------------------------------------------
function Init-Registry {
    if (-not (Test-Path $SourceRegistryPath)) {
        Write-Error "Source registry not found: $SourceRegistryPath"
        exit 1
    }

    $sourceContent = [System.IO.File]::ReadAllText($SourceRegistryPath, $utf8NoBom)
    $sourceData = $sourceContent | ConvertFrom-Json

    # Load existing registry to preserve daily_load and last_assignment
    $existingAgents = @{}
    if (Test-Path $RegistryPath) {
        $existingRegistry = Load-Registry
        if ($existingRegistry -and $existingRegistry.agents) {
            foreach ($name in $existingRegistry.agents.PSObject.Properties.Name) {
                $existingAgents[$name] = $existingRegistry.agents.$name
            }
        }
    }

    $newAgents = @{}

    foreach ($name in $sourceData.agents.PSObject.Properties.Name) {
        $sourceAgent = $sourceData.agents.$name

        # Build specialization: primary + secondary from source
        $spec = @()
        if ($sourceAgent.specialization) {
            $primary = @()
            $secondary = @()
            if ($sourceAgent.specialization.primary) {
                $primary = @($sourceAgent.specialization.primary)
            }
            if ($sourceAgent.specialization.secondary) {
                $secondary = @($sourceAgent.specialization.secondary)
            }
            $spec = @($primary + $secondary)
        }

        # Preserve daily_load and last_assignment from existing registry
        $dailyLoad = 0
        $lastAssgn = $null
        if ($existingAgents.ContainsKey($name)) {
            $existing = $existingAgents[$name]
            if ($existing.daily_load -ne $null) {
                $dailyLoad = [int]$existing.daily_load
            }
            $lastAssgn = $existing.last_assignment
        }

        $agentObj = [PSCustomObject]@{
            name             = $name
            role             = $sourceAgent.role
            specialization   = $spec
            status           = "free"
            current_project  = $null
            current_task     = $null
            last_assignment  = $lastAssgn
            daily_load       = $dailyLoad
        }

        $newAgents[$name] = $agentObj
    }

    $newRegistry = [PSCustomObject]@{ agents = $newAgents }

    if (-not (Save-Registry $newRegistry)) {
        Write-Error "Failed to save initialized registry"
        exit 1
    }

    $count = $newAgents.Count
    Write-Output "Registry initialized from source ($count agents), preserving daily_load and last_assignment"
}

# --------------------------------------------------
# Acquire agent: select best based on specialization algorithm
# - Filters: free + specialization IN required
# - Sorts: same_project first, daily_load asc, rating desc (higher is better)
# - Reads rating from .memory/ratings.jsonl (average grade, default 5.0)
# - Reserves best agent, outputs its name
# - Exit 2 if no free agent matches
# --------------------------------------------------
function Acquire-Agent {
    param([string]$RequiredSpec, [string]$ProjectName)

    $requiredSps = $RequiredSpec -split ',' | ForEach-Object { $_.Trim() }
    $requiredSps = $requiredSps | Where-Object { $_ -ne "" }

    $registry = Load-Registry
    if (-not $registry) {
        Write-Error "Could not load registry"
        exit 1
    }

    # Load agent ratings
    $ratings = Get-AgentRatings

    # Filter: free agents with at least one matching specialization
    $candidates = @()

    foreach ($name in $registry.agents.PSObject.Properties.Name) {
        $agent = $registry.agents.$name

        if ($agent.status -ne "free") { continue }

        # Check specialization match
        $agentSps = @()
        if ($agent.specialization) {
            $agentSps = @($agent.specialization)
        }
        $hasMatch = $false
        foreach ($req in $requiredSps) {
            foreach ($sp in $agentSps) {
                if ($sp -eq $req) {
                    $hasMatch = $true
                    break
                }
            }
            if ($hasMatch) { break }
        }
        if (-not $hasMatch) { continue }

        # Count matching specializations (more matches = better fit)
        $matchCount = 0
        foreach ($req in $requiredSps) {
            foreach ($sp in $agentSps) {
                if ($sp -eq $req) { $matchCount++; break }
            }
        }

        # same_project: 0 if agent has no current project or same project, 1 otherwise
        $sameProjNum = 0
        if ($agent.current_project -and $agent.current_project -ne $ProjectName) {
            $sameProjNum = 1
        }

        # Get rating (default 5.0)
        $rating = 5.0
        if ($ratings.ContainsKey($name)) {
            $rating = $ratings[$name]
        }

        $candidates += [PSCustomObject]@{
            Name        = $name
            SameProj    = $sameProjNum
            MatchCount  = $matchCount
            DailyLoad   = [int]$agent.daily_load
            Rating      = $rating
        }
    }

    if ($candidates.Count -eq 0) {
        [Console]::Error.WriteLine("NO_FREE_AGENT: No free agent with specializations: $($requiredSps -join ', ') for project '$ProjectName'")
        exit 2
    }

    # Sort by composite score:
    # same_project=0 better; matchCount higher better; daily_load lower better; rating higher better
    # Composite formula (lower = better):
    #   sameProj*1000000 - matchCount*10000 + dailyLoad*100 - rating*10
    $scored = $candidates | ForEach-Object {
        $score = [double]$_.SameProj * 1000000 - [double]$_.MatchCount * 10000 + [double]$_.DailyLoad * 100 - [double]$_.Rating * 10
        [PSCustomObject]@{
            Name      = $_.Name
            Score     = $score
            SameProj  = $_.SameProj
            MatchCount = $_.MatchCount
            DailyLoad = $_.DailyLoad
            Rating    = $_.Rating
        }
    }
    $sorted = $scored | Sort-Object Score

    $best = $sorted[0]
    $agentName = $best.Name

    # Double-check agent is still free
    $agent = $registry.agents.$agentName
    if ($agent.status -ne "free") {
        Write-Error "Agent '$agentName' is no longer free (race condition)"
        exit 2
    }

    # Reserve
    $agent.status = "busy"
    $agent.current_project = $ProjectName
    $agent.current_task = "$ProjectName-acquire"
    $agent.last_assignment = "$ProjectName-acquire"
    $agent.daily_load++

    if (-not (Save-Registry $registry)) {
        $agent.status = "free"
        $agent.current_project = $null
        $agent.current_task = $null
        $agent.last_assignment = $null
        $agent.daily_load--
        Write-Error "Failed to save registry after acquire, rolled back"
        exit 1
    }

    Write-Output "$agentName"
}

# --------------------------------------------------
# Main dispatch
# --------------------------------------------------

if ($Init) {
    Init-Registry
    exit 0
}

if ($List) {
    List-Agents -FilterStatus $Status
    exit 0
}

if ($Reserve) {
    if (-not $Agent -or -not $Project -or -not $Task) {
        Write-Error "Reserve requires -Agent, -Project, and -Task parameters"
        exit 1
    }
    Reserve-Agent -AgentName $Agent -ProjectName $Project -TaskId $Task
    exit 0
}

if ($Release) {
    if (-not $Agent) {
        Write-Error "Release requires -Agent parameter"
        exit 1
    }
    Release-Agent -AgentName $Agent
    exit 0
}

if ($SetStatus) {
    if (-not $Agent -or -not $Status) {
        Write-Error "SetStatus requires -Agent and -Status parameters"
        exit 1
    }
    Set-Status-Agent -AgentName $Agent -NewStatus $Status
    exit 0
}

if ($Acquire) {
    if (-not $Specialization -or -not $Project) {
        Write-Error "Acquire requires -Specialization and -Project parameters"
        exit 1
    }
    Acquire-Agent -RequiredSpec $Specialization -ProjectName $Project
    exit 0
}

# Default: show usage
Write-Output "Usage:"
Write-Output "  agent-registry.ps1 -Init"
Write-Output "  agent-registry.ps1 -List [-Status free|busy|error] [-Json]"
Write-Output "  agent-registry.ps1 -Reserve -Agent <name> -Project <project> -Task <taskId>"
Write-Output "  agent-registry.ps1 -Release -Agent <name>"
Write-Output "  agent-registry.ps1 -SetStatus -Agent <name> -Status <free|busy|error>"
Write-Output "  agent-registry.ps1 -Acquire -Specialization <sp1,sp2> -Project <name>"
exit 1
