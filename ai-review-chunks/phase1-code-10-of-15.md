# PHASE1 PART 10/15

  129:                         } else {
  130:                             Delegate-To-Copy -copyName $freeCopy -originalTask "Recover from lock conflict - continue previous task"
  131:                         }
  132:                     }
  133: 
  134:                     # Ждём пока новая сессия поднимется
  135:                     Start-Sleep -Seconds 30
  136:                 } else {
  137:                     Write-Log "NO FREE COPY: All team-lead copies busy"
  138:                     # Записываем blocker
  139:                     $bufferPath = "D:\Тест\agent-hq\CONTEXT-BUFFER.md"
  140:                     $tsNow2 = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
  141:                     $entry = "[$tsNow2] session-recovery -> team-lead:`nTYPE: blocker | PRIORITY: critical`nCONTENT: Lock conflict detected but ALL team-lead copies busy. Manual intervention needed.`nSKILLS_LOADED: [""skill-enforcement"", ""model-router"", ""self-healing""]`nMCP_USED: []`nCOMPLIANCE: false`nSTATUS: open`n"
  142:                     Add-Content -Path $bufferPath -Value $entry -Encoding UTF8
  143:                 }
  144:             }
  145:         } catch {
  146:             Write-Log "ERROR: $($_.Exception.Message)"
  147:         }
  148: 
  149:         Start-Sleep -Seconds $CheckIntervalSec
  150:     }
  151: }
  152: 
  153: # Singleton lock
  154: if (Test-Path $LockFile) {
  155:     $existingPid = Get-Content $LockFile -ErrorAction SilentlyContinue
  156:     if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
  157:         Write-Host "Another recovery daemon already running (PID: $existingPid)" -ForegroundColor Yellow
  158:         exit 0
  159:     }
  160: }
  161: $currentPid = $PID
  162: $currentPid | Out-File -FilePath $LockFile -Encoding UTF8
  163: 
  164: try {
  165:     if ($Daemon) {
  166:         Main-Loop
  167:     } else {
  168:         # One-shot check
  169:         if (Test-LockConflict) {
  170:             Write-Host "Lock conflict detected!" -ForegroundColor Red
  171:             $freeCopy = Get-FreeTeamLeadCopy
  172:             if ($freeCopy) {
  173:                 Write-Host "Free copy available: $freeCopy" -ForegroundColor Green
  174:                 exit 0
  175:             } else {
  176:                 Write-Host "No free copies" -ForegroundColor Red
  177:                 exit 1
  178:             }
  179:         } else {
  180:             Write-Host "No lock conflicts" -ForegroundColor Green
  181:             exit 0
  182:         }
  183:     }
  184: } finally {
  185:     if (Test-Path $LockFile) { Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue }
```

### `.agents/scripts/create-project.ps1` lines 1-190

```powershell
    1: param(
    2:     [Parameter(Mandatory=$true)]
    3:     [string]$ProjectName,
    4: 
    5:     [Parameter(Mandatory=$false)]
    6:     [string]$TemplateType = "full-stack",
    7: 
    8:     [Parameter(Mandatory=$false)]
    9:     [string[]]$Agents,
   10: 
   11:     [Parameter(Mandatory=$false)]
   12:     [switch]$CreateWorktrees
   13: )
   14: 
   15: $ErrorActionPreference = "Stop"
   16: 
   17: # Agents will be normalized later when building the agent list
   18: # Handle comma-separated strings from -File invocation (PS 5.1 does not auto-split [string[]] with -File)
   19: if ($null -ne $Agents) {
   20:     $splitAgents = @()
   21:     foreach ($a in $Agents) {
   22:         $splitAgents += ($a -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
   23:     }
   24:     $Agents = $splitAgents
   25: }
   26: 
   27: $baseDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
   28: $projectsDir = Join-Path $baseDir "projects"
   29: $projectDir = Join-Path $projectsDir $ProjectName
   30: 
   31: # Security: whitelist project name + path traversal guard
   32: if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
   33:     Write-Host "ERROR: Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-" -ForegroundColor Red
   34:     exit 1
   35: }
   36: $projFull = [System.IO.Path]::GetFullPath($projectDir)
   37: $rootFull = [System.IO.Path]::GetFullPath($projectsDir).TrimEnd('\') + '\'
   38: if (-not $projFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
   39:     Write-Host "ERROR: Path traversal detected: '$ProjectName' escapes projects root" -ForegroundColor Red
   40:     exit 1
   41: }
   42: 
   43: Write-Host "=== Creating project: $ProjectName ===" -ForegroundColor Cyan
   44: Write-Host "Template: $TemplateType" -ForegroundColor Yellow
   45: 
   46: if (Test-Path $projectDir) {
   47:     Write-Host "ERROR: Project directory already exists: $projectDir" -ForegroundColor Red
   48:     exit 1
   49: }
   50: 
   51: New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
   52: Write-Host "Created project: $projectDir" -ForegroundColor Green
   53: 
   54: # ============================================================
   55: # Create agent worktrees if requested
   56: # ============================================================
   57: function New-AgentWorktree {
   58:     param(
   59:         [string[]]$AgentNames,
   60:         [string]$ProjectName
   61:     )
   62: 
   63:     $baseAgentsDir = (Split-Path $PSScriptRoot -Parent)
   64:     $worktreesDir = Join-Path $baseAgentsDir "worktrees"
   65:     $gitExe = Get-Command git -ErrorAction SilentlyContinue
   66:     $gitAvailable = $null -ne $gitExe
   67: 
   68:     if ($AgentNames.Count -eq 0) {
   69:         Write-Host "No agents specified for worktree creation." -ForegroundColor Yellow
   70:         return
   71:     }
   72: 
   73:     Write-Host "Creating worktrees for $($AgentNames.Count) agent(s)" -ForegroundColor Yellow
   74: 
   75:     foreach ($agent in $AgentNames) {
   76:         $agentWorktreeDir = Join-Path $worktreesDir $agent
   77: 
   78:         if (Test-Path $agentWorktreeDir) {
   79:             Write-Host "WARNING: Worktree already exists for agent '$agent', skipping (idempotent): $agentWorktreeDir" -ForegroundColor Yellow
   80:             continue
   81:         }
   82: 
   83:         if (-not (Test-Path $worktreesDir)) {
   84:             New-Item -ItemType Directory -Path $worktreesDir -Force | Out-Null
   85:         }
   86: 
   87:         if ($gitAvailable -and (Test-Path (Join-Path $baseAgentsDir ".git"))) {
   88:             $branchName = "worktree\$agent\$ProjectName"
   89:             Write-Host "Creating git worktree for agent '$agent' on branch '$branchName'" -ForegroundColor Cyan
   90:             $gitWorktreeOk = $false
   91:             try {
   92:                 & git worktree add "$agentWorktreeDir" -b "$branchName" 2>$null
   93:                 if ($LASTEXITCODE -ne 0) {
   94:                     throw "git worktree add exited with code $LASTEXITCODE"
   95:                 }
   96:                 $gitWorktreeOk = $true
   97:             } catch {
   98:                 Write-Host "WARNING: git worktree failed for '$agent' ($($_.Exception.Message)), falling back to folder copy" -ForegroundColor Yellow
   99:                 $gitAvailable = $false
  100:             }
  101:             if ($gitWorktreeOk) {
  102:                 $skillsSrc = Join-Path $baseAgentsDir "skills"
  103:                 $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"
  104: 
  105:                 if (Test-Path $skillsSrc) {
  106:                     $skillsDst = Join-Path $agentWorktreeDir "skills"
  107:                     Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
  108:                     $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
  109:                     if ($null -ne $skillItems) {
  110:                         foreach ($item in $skillItems) {
  111:                             $dst = Join-Path $skillsDst $item.Name
  112:                             Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  113:                         }
  114:                     }
  115:                     Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
  116:                 }
  117: 
  118:                 if (Test-Path $opencodeAgentsSrc) {
  119:                     $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
  120:                     Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
  121:                     $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
  122:                     if ($null -ne $opencodeItems) {
  123:                         foreach ($item in $opencodeItems) {
  124:                             $dst = Join-Path $opencodeAgentsDst $item.Name
  125:                             Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  126:                         }
  127:                     }
  128:                     Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
  129:                 }
  130:                 continue
  131:             }
  132:         }
  133: 
  134:         Write-Host "Creating folder stub for agent '$agent'" -ForegroundColor Cyan
  135: 
  136:         $skillsSrc = Join-Path $baseAgentsDir "skills"
  137:         if (Test-Path $skillsSrc) {
  138:             $skillsDst = Join-Path $agentWorktreeDir "skills"
  139:             Remove-Item -Path $skillsDst -Recurse -Force -ErrorAction SilentlyContinue
  140:             $skillItems = Get-ChildItem -Path $skillsSrc -ErrorAction SilentlyContinue
  141:             if ($null -ne $skillItems) {
  142:                 foreach ($item in $skillItems) {
  143:                     $dst = Join-Path $skillsDst $item.Name
  144:                     Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  145:                 }
  146:             }
  147:             Write-Host "  Copied .agents/skills to worktree" -ForegroundColor Gray
  148:         }
  149: 
  150:         $opencodeAgentsSrc = Join-Path (Join-Path $baseDir ".opencode") "agents"
  151:         if (Test-Path $opencodeAgentsSrc) {
  152:             $opencodeAgentsDst = Join-Path $agentWorktreeDir "agents"
  153:             Remove-Item -Path $opencodeAgentsDst -Recurse -Force -ErrorAction SilentlyContinue
  154:             $opencodeItems = Get-ChildItem -Path $opencodeAgentsSrc -ErrorAction SilentlyContinue
  155:             if ($null -ne $opencodeItems) {
  156:                 foreach ($item in $opencodeItems) {
  157:                     $dst = Join-Path $opencodeAgentsDst $item.Name
  158:                     Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
  159:                 }
  160:             }
  161:             Write-Host "  Copied .opencode/agents to worktree" -ForegroundColor Gray
  162:         }
  163:     }
  164: }
  165: 
  166: # Build the agent list to process
  167: $agentList = @()
  168: 
  169: if ($CreateWorktrees -and -not $Agents) {
  170:     $configDir = Join-Path (Join-Path $baseDir ".opencode") "agents"
  171:     if (Test-Path $configDir) {
  172:         $allConfigs = Get-ChildItem -Path $configDir -Filter "*.json" -ErrorAction SilentlyContinue
  173:         foreach ($config in $allConfigs) {
  174:             $name = [System.IO.Path]::GetFileNameWithoutExtension($config.Name)
  175:             if ($name -ne "registry") {
  176:                 $agentList += $name
  177:             }
  178:         }
  179:     }
  180: } elseif ($Agents -and $Agents.Count -gt 0) {
  181:     $agentList = $Agents
  182: }
  183: 
  184: if ($agentList.Count -gt 0) {
  185:     New-AgentWorktree -AgentNames $agentList -ProjectName $ProjectName
  186: }
  187: 
  188: # ============================================================
  189: # Copy shared template files
  190: # ============================================================
```

### `.agents/scripts/create-project.ps1` lines 188-310

```powershell
  188: # ============================================================
  189: # Copy shared template files
  190: # ============================================================
  191: 
  192: $templateDir = Join-Path $PSScriptRoot "..\templates\project"
  193: $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
  194: 
  195: Write-Host "Template: $TemplateType" -ForegroundColor Yellow
  196: Write-Host "Template source: $templateDir" -ForegroundColor Gray
  197: 
  198: if (-not (Test-Path $templateDir)) {
  199:     Write-Host "WARNING: Template directory not found: $templateDir - skipping template files" -ForegroundColor Yellow
  200: } else {
  201:     # CONTEXT-BUFFER.md
  202:     $cbSrc = Join-Path $templateDir "CONTEXT-BUFFER.md"
  203:     if (Test-Path $cbSrc) {
  204:         $cbContent = [System.IO.File]::ReadAllText($cbSrc) -replace '\{name\}', $ProjectName
  205:         [System.IO.File]::WriteAllText((Join-Path $projectDir "CONTEXT-BUFFER.md"), $cbContent, [System.Text.UTF8Encoding]::new($false))
  206:         Write-Host "  Copied CONTEXT-BUFFER.md" -ForegroundColor Gray
  207:     }
  208: 
  209:     # KNOWLEDGE-BASE.md
  210:     $kbSrc = Join-Path $templateDir "KNOWLEDGE-BASE.md"
  211:     if (Test-Path $kbSrc) {
  212:         $kbContent = [System.IO.File]::ReadAllText($kbSrc) -replace '\{name\}', $ProjectName
  213:         [System.IO.File]::WriteAllText((Join-Path $projectDir "KNOWLEDGE-BASE.md"), $kbContent, [System.Text.UTF8Encoding]::new($false))
  214:         Write-Host "  Copied KNOWLEDGE-BASE.md" -ForegroundColor Gray
  215:     }
  216: 
  217:     # README.md
  218:     $rdSrc = Join-Path $templateDir "README.md"
  219:     if (Test-Path $rdSrc) {
  220:         $rdContent = [System.IO.File]::ReadAllText($rdSrc) -replace '\{name\}', $ProjectName
  221:         [System.IO.File]::WriteAllText((Join-Path $projectDir "README.md"), $rdContent, [System.Text.UTF8Encoding]::new($false))
  222:         Write-Host "  Copied README.md" -ForegroundColor Gray
  223:     }
  224: 
  225:     # project.json
  226:     $pjSrc = Join-Path $templateDir "project.json"
  227:     if (Test-Path $pjSrc) {
  228:         $pjContent = [System.IO.File]::ReadAllText($pjSrc)
  229:         $pjContent = $pjContent -replace '\{name\}', $ProjectName
  230:         $pjContent = $pjContent -replace '\{type\}', $TemplateType
  231:         $pjContent = $pjContent -replace '\{created_at\}', $timestamp
  232:         [System.IO.File]::WriteAllText((Join-Path $projectDir "project.json"), $pjContent, [System.Text.UTF8Encoding]::new($false))
  233:         Write-Host "  Copied project.json" -ForegroundColor Gray
  234:     }
  235: 
  236:     # queue.json
  237:     $qSrc = Join-Path $templateDir "queue.json"
  238:     if (Test-Path $qSrc) {
  239:         Copy-Item -Path $qSrc -Destination (Join-Path $projectDir "queue.json") -Force
  240:         Write-Host "  Copied queue.json" -ForegroundColor Gray
  241:     }
  242: 
  243:     # memory/ directory with .gitkeep
  244:     $memDir = Join-Path $projectDir "memory"
  245:     if (-not (Test-Path $memDir)) {
  246:         New-Item -ItemType Directory -Path $memDir -Force | Out-Null
  247:     }
  248:     $gkSrc = Join-Path $templateDir "memory\.gitkeep"
  249:     $gkDst = Join-Path $memDir ".gitkeep"
  250:     if ((Test-Path $gkSrc) -and -not (Test-Path $gkDst)) {
  251:         Copy-Item -Path $gkSrc -Destination $gkDst -Force
  252:     }
  253:     Write-Host "  Created memory/" -ForegroundColor Gray
  254: }
  255: 
  256: # ============================================================
  257: # Type-specific directory structure
  258: # ============================================================
  259: 
  260: switch ($TemplateType) {
  261:     "full-stack" {
  262:         $dirs = @("src\frontend", "src\backend", "src\shared", "tests", "docs", "scripts")
  263:         foreach ($d in $dirs) {
  264:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  265:         }
  266:     }
  267:     "api-only" {
  268:         $dirs = @("src\api", "src\models", "tests", "docs")
  269:         foreach ($d in $dirs) {
  270:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  271:         }
  272:     }
  273:     "mobile" {
  274:         $dirs = @("src\app", "src\components", "src\screens", "tests")
  275:         foreach ($d in $dirs) {
  276:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  277:         }
  278:     }
  279:     "data-pipeline" {
  280:         $dirs = @("src\etl", "src\transforms", "src\models", "tests", "configs")
  281:         foreach ($d in $dirs) {
  282:             New-Item -ItemType Directory -Path (Join-Path $projectDir $d) -Force | Out-Null
  283:         }
  284:     }
  285:     default {
  286:         Write-Host "Unknown template: $TemplateType. Using full-stack." -ForegroundColor Yellow
  287:     }
  288: }
  289: 
  290: $gitignore = @"
  291: node_modules/
  292: __pycache__/
  293: *.pyc
  294: .venv/
  295: venv/
  296: dist/
  297: build/
  298: .env
  299: .env.local
  300: *.log
  301: .DS_Store
  302: Thumbs.db
  303: "@


---
Ответь только: `Принято 10/15`. Жди следующую часть.
