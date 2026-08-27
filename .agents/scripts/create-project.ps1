param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,

    [Parameter(Mandatory=$false)]
    [string]$TemplateType = "full-stack",

    [Parameter(Mandatory=$false)]
    [string[]]$Agents,

    [Parameter(Mandatory=$false)]
    [switch]$CreateWorktrees
)

$ErrorActionPreference = "Stop"

# Agents will be normalized later when building the agent list
# Handle comma-separated strings from -File invocation (PS 5.1 does not auto-split [string[]] with -File)
if ($null -ne $Agents) {
    $splitAgents = @()
    foreach ($a in $Agents) {
        $splitAgents += ($a -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    $Agents = $splitAgents
}

$baseDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$projectsDir = Join-Path $baseDir "projects"
$projectDir = Join-Path $projectsDir $ProjectName

Write-Host "=== Creating project: $ProjectName ===" -ForegroundColor Cyan
Write-Host "Template: $TemplateType" -ForegroundColor Yellow

if (Test-Path $projectDir) {
    Write-Host "ERROR: Project directory already exists: $projectDir" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
Write-Host "Created project: $projectDir" -ForegroundColor Green

# ============================================================
# NEW: Create agent worktrees if requested
# ============================================================
function New-AgentWorktree {
    param(
        [string[]]$AgentNames,
        [string]$ProjectName
    )

    # .agents directory is the parent of the script's parent directory
$baseAgentsDir = (Split-Path $PSScriptRoot -Parent)
    $worktreesDir = Join-Path $baseAgentsDir "worktrees"
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    $gitAvailable = $null -ne $gitExe

    # Determine which agents to process
    if ($AgentNames.Count -eq 0) {
        Write-Host "No agents specified for worktree creation." -ForegroundColor Yellow
        return
    }

    Write-Host "Creating worktrees for $($AgentNames.Count) agent(s)" -ForegroundColor Yellow

    foreach ($agent in $AgentNames) {
        $agentWorktreeDir = Join-Path $worktreesDir $agent

        # Check if worktree already exists (idempotency)
        if (Test-Path $agentWorktreeDir) {
            Write-Host "WARNING: Worktree already exists for agent '$agent', skipping (idempotent): $agentWorktreeDir" -ForegroundColor Yellow
            continue
        }

        # Ensure worktrees directory exists
        if (-not (Test-Path $worktreesDir)) {
            New-Item -ItemType Directory -Path $worktreesDir -Force | Out-Null
        }

        if ($gitAvailable -and (Test-Path (Join-Path $baseAgentsDir ".git"))) {
            # Git variant: create git worktree
            $branchName = "worktree\$agent\$ProjectName"
            Write-Host "Creating git worktree for agent '$agent' on branch '$branchName'" -ForegroundColor Cyan
            $gitWorktreeOk = $false
            try {
                & git worktree add "$agentWorktreeDir" -b "$branchName" 2>$null
                if ($LASTEXITCODE -ne 0) {
                    throw "git worktree add exited with code $LASTEXITCODE"
                }
                $gitWorktreeOk = $true
            } catch {
                Write-Host "WARNING: git worktree failed for '$agent' ($($_.Exception.Message)), falling back to folder copy" -ForegroundColor Yellow
                $gitAvailable = $false
            }
            if ($gitWorktreeOk) {
                # Copy .agents/skills and .opencode/agents into the worktree
                $skillsSrc = Join-Path $baseAgentsDir "skills"
                $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"

                if (Test-Path $skillsSrc) {
                    $skillsDst = Join-Path $agentWorktreeDir "skills"
                    Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
                    $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
                    if ($null -ne $skillItems) {
                        foreach ($item in $skillItems) {
                            $dst = Join-Path $skillsDst $item.Name
                            Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                    Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
                }

                if (Test-Path $opencodeAgentsSrc) {
                    $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
                    Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
                    $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
                    if ($null -ne $opencodeItems) {
                        foreach ($item in $opencodeItems) {
                            $dst = Join-Path $opencodeAgentsDst $item.Name
                            Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                    Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
                }
                continue
            }
        }

        # Fallback: create folder stub and copy base structure
        Write-Host "Creating folder stub for agent '$agent'" -ForegroundColor Cyan

        # Copy .agents/skills if it exists
        $skillsSrc = Join-Path $baseAgentsDir "skills"
        if (Test-Path $skillsSrc) {
            $skillsDst = Join-Path $agentWorktreeDir "skills"
            Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
            $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
            if ($null -ne $skillItems) {
                foreach ($item in $skillItems) {
                    $dst = Join-Path $skillsDst $item.Name
                    Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
        }

        # Copy .opencode/agents if it exists
        $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"
        if (Test-Path $opencodeAgentsSrc) {
            $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
            Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
            $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
            if ($null -ne $opencodeItems) {
                foreach ($item in $opencodeItems) {
                    $dst = Join-Path $opencodeAgentsDst $item.Name
                    Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
        }
    }
}

# Build the agent list to process
$agentList = @()

if ($CreateWorktrees -and -not $Agents) {
    # -CreateWorktrees without -Agents: create for all from .opencode/agents/*.json (except registry.json)
    $configDir = Join-Path (Join-Path $baseDir ".opencode") "agents"
    if (Test-Path $configDir) {
        $allConfigs = Get-ChildItem -Path $configDir -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($config in $allConfigs) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($config.Name)
            if ($name -ne "registry") {
                $agentList += $name
            }
        }
    }
} elseif ($Agents -and $Agents.Count -gt 0) {
    $agentList = $Agents
}

if ($agentList.Count -gt 0) {
    New-AgentWorktree -AgentNames $agentList -ProjectName $ProjectName
}

# ============================================================
# Existing: Create project from template
# ============================================================

Write-Host "Template: $TemplateType" -ForegroundColor Yellow

# Project dir already created earlier in the script
Write-Host "Created: $projectDir" -ForegroundColor Green

switch ($TemplateType) {
    "full-stack" {
        $dirs = @("src\frontend", "src\backend", "src\shared", "tests", "docs", "scripts")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
        $readme = @"
# $ProjectName

## Stack
- Frontend: TBD
- Backend: TBD
- Database: TBD

## Quick Start
``````bash
# Frontend
cd src/frontend
npm install
npm run dev

# Backend
cd src/backend
pip install -r requirements.txt
python main.py
``````

## Structure
``````
src/
├── frontend/
├── backend/
├── shared/
tests/
docs/
scripts/
``````

## Commands
- `/status` - Check project status
- `/sync` - Sync context from Memory Bank

---
Generated by agent-hq
"@
        Set-Content -Path (Join-Path $projectDir "README.md") -Value $readme
    }
    "api-only" {
        $dirs = @("src\api", "src\models", "tests", "docs")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
        $readme = @"
# $ProjectName

## Stack
- API: TBD
- Database: TBD

## Quick Start
``````bash
cd src/api
pip install -r requirements.txt
python main.py
``````

## API Endpoints
- `GET /health` - Health check
- `POST /api/v1/` - TBD

---
Generated by agent-hq
"@
        Set-Content -Path (Join-Path $projectDir "README.md") -Value $readme
    }
    "mobile" {
        $dirs = @("src\app", "src\components", "src\screens", "tests")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
        $readme = @"
# $ProjectName

## Stack
- Framework: React Native / Flutter
- State: TBD

## Quick Start
``````bash
npm install
npx expo start
``````

---
Generated by agent-hq
"@
        Set-Content -Path (Join-Path $projectDir "README.md") -Value $readme
    }
    "data-pipeline" {
        $dirs = @("src\etl", "src\transforms", "src\models", "tests", "configs")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
        $readme = @"
# $ProjectName

## Stack
- Orchestration: Airflow / Prefect
- Processing: Spark / Pandas
- Storage: TBD

## Quick Start
``````bash
cd src/etl
python pipeline.py
``````

---
Generated by agent-hq
"@
        Set-Content -Path (Join-Path $projectDir "README.md") -Value $readme
    }
    default {
        Write-Host "Unknown template: $TemplateType. Using full-stack." -ForegroundColor Yellow
    }
}

$gitignore = @"
node_modules/
__pycache__/
*.pyc
.venv/
venv/
dist/
build/
.env
.env.local
*.log
.DS_Store
Thumbs.db
"@
Set-Content -Path (Join-Path $projectDir ".gitignore") -Value $gitignore

Write-Host ""
Write-Host "=== Project created: $projectDir ===" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. cd $projectDir" -ForegroundColor White
Write-Host "  2. git init ; git add -A ; git commit -m 'init'" -ForegroundColor White
Write-Host "  3. Start coding!" -ForegroundColor White