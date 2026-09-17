param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,

    [Parameter(Mandatory=$false)]
    [string]$TemplateType = "full-stack",

    [Parameter(Mandatory=$false)]
    [string[]]$Agents,

    [Parameter(Mandatory=$false)]
    [switch]$CreateWorktrees,

    # P1-2: skip the per-project git worktree (agent worktrees are unaffected).
    [Parameter(Mandatory=$false)]
    [switch]$NoWorktree
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

# Portability: prefer an explicit AGENT_HQ_ROOT (tests / alternate checkouts),
# otherwise derive the repository root from this script's location.
$baseDir = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) {
    $env:AGENT_HQ_ROOT
} else {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
$projectsDir = Join-Path $baseDir "projects"
$projectDir = Join-Path $projectsDir $ProjectName

# Security: project-name whitelist lives in project-worktree.ps1 (single source,
# shared with project-queue.ps1) and is loaded here BEFORE anything is created.
# It accepts Cyrillic/Latin letters, digits, '_', '-' and spaces, and rejects
# path traversal, Windows-invalid characters, reserved device names and
# trailing spaces/dots.
$isolationHelperPath = Join-Path $PSScriptRoot "project-worktree.ps1"
$isolationHelperLoaded = $false
if (Test-Path -LiteralPath $isolationHelperPath -PathType Leaf) {
    . $isolationHelperPath
    if (Get-Command Test-ProjectName -ErrorAction SilentlyContinue) {
        $isolationHelperLoaded = $true
    }
}

$nameReason = ""
$nameValid = $false
if ($isolationHelperLoaded) {
    $nameValid = Test-ProjectName -ProjectName $ProjectName -Reason ([ref]$nameReason)
} else {
    # Degraded fallback (helper file missing): never weaker than the old rule.
    $nameValid = ($ProjectName -match '^[a-zA-Z0-9_\-]+$')
    if (-not $nameValid) {
        $nameReason = "allowed chars are a-zA-Z0-9_- (fallback: project-worktree.ps1 not found at $isolationHelperPath)"
    }
}
if (-not $nameValid) {
    Write-Host "ERROR: Invalid project name '$ProjectName': $nameReason" -ForegroundColor Red
    exit 1
}

$projFull = [System.IO.Path]::GetFullPath($projectDir)
$rootFull = [System.IO.Path]::GetFullPath($projectsDir).TrimEnd('\') + '\'
if (-not $projFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: Path traversal detected: '$ProjectName' escapes projects root" -ForegroundColor Red
    exit 1
}

Write-Host "=== Creating project: $ProjectName ===" -ForegroundColor Cyan
Write-Host "Template: $TemplateType" -ForegroundColor Yellow

if (Test-Path $projectDir) {
    Write-Host "ERROR: Project directory already exists: $projectDir" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
Write-Host "Created project: $projectDir" -ForegroundColor Green

# ============================================================
# Create agent worktrees if requested
# ============================================================
function New-AgentWorktree {
    param(
        [string[]]$AgentNames,
        [string]$ProjectName
    )

    $baseAgentsDir = (Split-Path $PSScriptRoot -Parent)
    $worktreesDir = Join-Path $baseAgentsDir "worktrees"
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    $gitAvailable = $null -ne $gitExe

    if ($AgentNames.Count -eq 0) {
        Write-Host "No agents specified for worktree creation." -ForegroundColor Yellow
        return
    }

    Write-Host "Creating worktrees for $($AgentNames.Count) agent(s)" -ForegroundColor Yellow

    foreach ($agent in $AgentNames) {
        $agentWorktreeDir = Join-Path $worktreesDir $agent

        if (Test-Path $agentWorktreeDir) {
            Write-Host "WARNING: Worktree already exists for agent '$agent', skipping (idempotent): $agentWorktreeDir" -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path $worktreesDir)) {
            New-Item -ItemType Directory -Path $worktreesDir -Force | Out-Null
        }

        if ($gitAvailable -and (Test-Path (Join-Path $baseAgentsDir ".git"))) {
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

        Write-Host "Creating folder stub for agent '$agent'" -ForegroundColor Cyan

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
# Copy shared template files
# ============================================================

$templateDir = Join-Path $PSScriptRoot "..\templates\project"
$timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"

Write-Host "Template: $TemplateType" -ForegroundColor Yellow
Write-Host "Template source: $templateDir" -ForegroundColor Gray

if (-not (Test-Path $templateDir)) {
    Write-Host "WARNING: Template directory not found: $templateDir - skipping template files" -ForegroundColor Yellow
} else {
    # CONTEXT-BUFFER.md
    $cbSrc = Join-Path $templateDir "CONTEXT-BUFFER.md"
    if (Test-Path $cbSrc) {
        $cbContent = [System.IO.File]::ReadAllText($cbSrc) -replace '\{name\}', $ProjectName
        [System.IO.File]::WriteAllText((Join-Path $projectDir "CONTEXT-BUFFER.md"), $cbContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Copied CONTEXT-BUFFER.md" -ForegroundColor Gray
    }

    # KNOWLEDGE-BASE.md
    $kbSrc = Join-Path $templateDir "KNOWLEDGE-BASE.md"
    if (Test-Path $kbSrc) {
        $kbContent = [System.IO.File]::ReadAllText($kbSrc) -replace '\{name\}', $ProjectName
        [System.IO.File]::WriteAllText((Join-Path $projectDir "KNOWLEDGE-BASE.md"), $kbContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Copied KNOWLEDGE-BASE.md" -ForegroundColor Gray
    }

    # README.md
    $rdSrc = Join-Path $templateDir "README.md"
    if (Test-Path $rdSrc) {
        $rdContent = [System.IO.File]::ReadAllText($rdSrc) -replace '\{name\}', $ProjectName
        [System.IO.File]::WriteAllText((Join-Path $projectDir "README.md"), $rdContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Copied README.md" -ForegroundColor Gray
    }

    # project.json
    $pjSrc = Join-Path $templateDir "project.json"
    if (Test-Path $pjSrc) {
        $pjContent = [System.IO.File]::ReadAllText($pjSrc)
        $pjContent = $pjContent -replace '\{name\}', $ProjectName
        $pjContent = $pjContent -replace '\{type\}', $TemplateType
        $pjContent = $pjContent -replace '\{created_at\}', $timestamp
        [System.IO.File]::WriteAllText((Join-Path $projectDir "project.json"), $pjContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Copied project.json" -ForegroundColor Gray
    }

    # queue.json
    $qSrc = Join-Path $templateDir "queue.json"
    if (Test-Path $qSrc) {
        Copy-Item -Path $qSrc -Destination (Join-Path $projectDir "queue.json") -Force
        Write-Host "  Copied queue.json" -ForegroundColor Gray
    }

    # memory/ directory with .gitkeep
    $memDir = Join-Path $projectDir "memory"
    if (-not (Test-Path $memDir)) {
        New-Item -ItemType Directory -Path $memDir -Force | Out-Null
    }
    $gkSrc = Join-Path $templateDir "memory\.gitkeep"
    $gkDst = Join-Path $memDir ".gitkeep"
    if ((Test-Path $gkSrc) -and -not (Test-Path $gkDst)) {
        Copy-Item -Path $gkSrc -Destination $gkDst -Force
    }
    Write-Host "  Created memory/" -ForegroundColor Gray
}

# ============================================================
# Type-specific directory structure
# ============================================================

switch ($TemplateType) {
    "full-stack" {
        $dirs = @("src\frontend", "src\backend", "src\shared", "tests", "docs", "scripts")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
    }
    "api-only" {
        $dirs = @("src\api", "src\models", "tests", "docs")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
    }
    "mobile" {
        $dirs = @("src\app", "src\components", "src\screens", "tests")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
    }
    "data-pipeline" {
        $dirs = @("src\etl", "src\transforms", "src\models", "tests", "configs")
        foreach ($d in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
        }
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

# ============================================================
# P1-2: per-project git worktree (isolation boundary)
# The project gets its own worktree under .agents\worktrees\<name> on branch
# project/<name> (only a space is percent-encoded as %20 there, because git refs
# forbid a space), so workers of different projects never share a checkout.
# The helper was already dot-sourced above for validation.
# Failures degrade to a warning: the project itself is already usable.
# ============================================================
if (-not $NoWorktree) {
    if ($isolationHelperLoaded) {
        try {
            $worktree = New-ProjectWorktree -Project $ProjectName -Root $baseDir
            if ($worktree.ok) {
                Write-Host "  Worktree: $($worktree.path) [mode: $($worktree.mode); branch: $($worktree.branch)]" -ForegroundColor Gray
            } else {
                Write-Host "  WARNING: per-project worktree not created: $($worktree.reason)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  WARNING: per-project worktree failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: project-worktree.ps1 not found at $isolationHelperPath - skipping worktree" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Project created: $projectDir ===" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. cd $projectDir" -ForegroundColor White
Write-Host "  2. git init ; git add -A ; git commit -m 'init'" -ForegroundColor White
Write-Host "  3. Start coding!" -ForegroundColor White

# Explicit success exit code (BUG-025). When this script is invoked in the SAME
# process (`& .\create-project.ps1 ...`), the caller reads $LASTEXITCODE. Without
# an explicit `exit 0` that value leaked from the last native command (or stayed
# at -1 after a caught git stderr), so a fully SUCCESSFUL run looked like a
# failure in-process; `powershell -File` hid the problem because PowerShell
# defaults the process exit code to 0 in that mode.
exit 0