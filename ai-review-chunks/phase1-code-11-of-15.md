# PHASE1 PART 11/15

  304: Set-Content -Path (Join-Path $projectDir ".gitignore") -Value $gitignore
  305: 
  306: Write-Host ""
  307: Write-Host "=== Project created: $projectDir ===" -ForegroundColor Green
  308: Write-Host "Next steps:" -ForegroundColor Yellow
  309: Write-Host "  1. cd $projectDir" -ForegroundColor White
  310: Write-Host "  2. git init ; git add -A ; git commit -m 'init'" -ForegroundColor White
```

### `.agents/scripts/agent-utilization.ps1` lines 1-205

```powershell
    1: # agent-utilization.ps1 - Agent utilization metrics and audit log
    2: # US-014 Resource Awareness
    3: #
    4: # Parameters:
    5: #   -Json                    Output metrics as JSON (machine-readable)
    6: #   -Watch [-IntervalSec N]  Live dashboard mode (default 30s interval)
    7: #   -LogAssignment           Log an assignment to agent-assignments.jsonl
    8: #     -Agent <name>          Agent name
    9: #     -Project <name>        Project name
   10: #     -Task <id>             Task ID
   11: #
   12: # Reads: .memory/agent-registry.json
   13: # Writes: .memory/agent-assignments.jsonl (append, UTF-8 no BOM)
   14: 
   15: param(
   16:     [switch]$Json,
   17:     [switch]$Watch,
   18:     [int]$IntervalSec = 30,
   19:     [switch]$LogAssignment,
   20:     [string]$Agent,
   21:     [string]$Project,
   22:     [string]$Task
   23: )
   24: 
   25: $ErrorActionPreference = "Stop"
   26: 
   27: # --------------------------------------------------
   28: # Path resolution: script is in .agents/scripts/
   29: # Project root is two levels up
   30: # --------------------------------------------------
   31: $scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
   32: $projectRoot = Split-Path (Split-Path $scriptDir -Parent) -Parent
   33: 
   34: $RegistryPath = Join-Path $projectRoot ".memory\agent-registry.json"
   35: $AssignmentsPath = Join-Path $projectRoot ".memory\agent-assignments.jsonl"
   36: $ProjectsDir = Join-Path $projectRoot "projects"
   37: 
   38: # UTF-8 without BOM encoding
   39: $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
   40: 
   41: # --------------------------------------------------
   42: # Helper: Load registry JSON
   43: # --------------------------------------------------
   44: function Load-Registry {
   45:     if (-not (Test-Path $RegistryPath)) {
   46:         Write-Error "Registry file not found: $RegistryPath"
   47:         return $null
   48:     }
   49:     try {
   50:         $content = [System.IO.File]::ReadAllText($RegistryPath, $utf8NoBom)
   51:         $registry = $content | ConvertFrom-Json
   52:         return $registry
   53:     } catch {
   54:         Write-Error "Failed to parse registry JSON: $_"
   55:         return $null
   56:     }
   57: }
   58: 
   59: # --------------------------------------------------
   60: # Helper: Enumerate projects dynamically from projects/ dir
   61: # --------------------------------------------------
   62: function Get-ProjectNames {
   63:     $names = @()
   64:     if (Test-Path $ProjectsDir) {
   65:         $dirs = Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue
   66:         foreach ($d in $dirs) {
   67:             $names += $d.Name
   68:         }
   69:     }
   70:     return $names
   71: }
   72: 
   73: # --------------------------------------------------
   74: # Compute utilization metrics
   75: # Returns PSCustomObject with all metrics
   76: # --------------------------------------------------
   77: function Get-UtilizationMetrics {
   78:     $registry = Load-Registry
   79:     if (-not $registry) {
   80:         return $null
   81:     }
   82: 
   83:     $allAgents = @()
   84:     foreach ($name in $registry.agents.PSObject.Properties.Name) {
   85:         $allAgents += $registry.agents.$name
   86:     }
   87: 
   88:     $total = $allAgents.Count
   89:     $busy = ($allAgents | Where-Object { $_.status -eq "busy" }).Count
   90:     $free = ($allAgents | Where-Object { $_.status -eq "free" }).Count
   91:     $errorCount = ($allAgents | Where-Object { $_.status -eq "error" }).Count
   92: 
   93:     if ($total -gt 0) {
   94:         $utilizationPct = [math]::Round(($busy / $total) * 100, 1)
   95:     } else {
   96:         $utilizationPct = 0
   97:     }
   98: 
   99:     # By project: count busy agents per current_project
  100:     $byProject = @{}
  101:     foreach ($a in $allAgents) {
  102:         if ($a.status -eq "busy" -and $a.current_project) {
  103:             $proj = $a.current_project
  104:             if (-not $byProject.ContainsKey($proj)) {
  105:                 $byProject[$proj] = 0
  106:             }
  107:             $byProject[$proj]++
  108:         }
  109:     }
  110: 
  111:     # Free agents by specialization/role
  112:     $freeBySpec = @{}
  113:     foreach ($a in $allAgents) {
  114:         if ($a.status -eq "free") {
  115:             $role = $a.role
  116:             if (-not $freeBySpec.ContainsKey($role)) {
  117:                 $freeBySpec[$role] = 0
  118:             }
  119:             $freeBySpec[$role]++
  120:         }
  121:     }
  122: 
  123:     # Alerts
  124:     $alerts = @()
  125:     if ($utilizationPct -lt 50) {
  126:         $alerts += "UNDERUTILIZED: utilization ${utilizationPct}% < 50% threshold"
  127:     }
  128:     if ($utilizationPct -gt 90) {
  129:         $alerts += "OVERLOADED: utilization ${utilizationPct}% > 90% threshold"
  130:     }
  131: 
  132:     $metrics = [PSCustomObject]@{
  133:         total               = $total
  134:         busy                = $busy
  135:         free                = $free
  136:         error               = $errorCount
  137:         utilization_pct     = $utilizationPct
  138:         by_project          = $byProject
  139:         free_by_specialization = $freeBySpec
  140:         alerts              = $alerts
  141:     }
  142: 
  143:     return $metrics
  144: }
  145: 
  146: # --------------------------------------------------
  147: # Render text dashboard
  148: # --------------------------------------------------
  149: function Show-TextDashboard {
  150:     $metrics = Get-UtilizationMetrics
  151:     if (-not $metrics) {
  152:         Write-Output "ERROR: Could not load agent registry"
  153:         return
  154:     }
  155: 
  156:     Write-Output ""
  157:     Write-Output "=== AGENT UTILIZATION DASHBOARD ==="
  158:     Write-Output ""
  159: 
  160:     # Summary
  161:     Write-Output "Total: $($metrics.total) | Busy: $($metrics.busy) | Free: $($metrics.free) | Error: $($metrics.error)"
  162:     Write-Output "Utilization: $($metrics.utilization_pct)%"
  163:     Write-Output ""
  164: 
  165:     # By project
  166:     Write-Output "--- Busy Agents by Project ---"
  167:     if ($metrics.by_project.Count -eq 0) {
  168:         Write-Output "  (no busy agents)"
  169:     } else {
  170:         foreach ($proj in ($metrics.by_project.Keys | Sort-Object)) {
  171:             $count = $metrics.by_project[$proj]
  172:             Write-Output "  $proj : $count agent(s)"
  173:         }
  174:     }
  175:     Write-Output ""
  176: 
  177:     # Free by specialization
  178:     Write-Output "--- Free Agents by Role ---"
  179:     if ($metrics.free_by_specialization.Count -eq 0) {
  180:         Write-Output "  (no free agents)"
  181:     } else {
  182:         foreach ($role in ($metrics.free_by_specialization.Keys | Sort-Object)) {
  183:             $count = $metrics.free_by_specialization[$role]
  184:             Write-Output "  $role : $count"
  185:         }
  186:     }
  187:     Write-Output ""
  188: 
  189:     # Alerts
  190:     if ($metrics.alerts.Count -gt 0) {
  191:         Write-Output "--- ALERTS ---"
  192:         foreach ($alert in $metrics.alerts) {
  193:             Write-Output "  [!] $alert"
  194:         }
  195:         Write-Output ""
  196:     }
  197: 
  198:     # Recent assignments (last 5)
  199:     Show-RecentAssignments -Count 5
  200: }
  201: 
  202: # --------------------------------------------------
  203: # Show last N assignment log entries
  204: # --------------------------------------------------
  205: function Show-RecentAssignments {
```

### `.agents/scripts/verify-phase.ps1` lines 1-165

```powershell
    1: param()
    2: 
    3: # CI auto-detect: GitHub Actions / generic CI runners have no local runtime artifacts
    4: $isCI = ($env:GITHUB_ACTIONS -eq "true") -or ($env:CI -eq "true")
    5: 
    6: Write-Host "=== Agent-HQ Phase Verification ===" -ForegroundColor Cyan
    7: Write-Host "Mode: $(if ($isCI) { 'CI' } else { 'LOCAL' })" -ForegroundColor Cyan
    8: Write-Host ""
    9: 
   10: $pass = 0
   11: $fail = 0
   12: $total = 0
   13: $ciSkipped = 0
   14: 
   15: function Test-Check {
   16:     param([string]$Name, [bool]$Condition)
   17:     $script:total++
   18:     if ($Condition) {
   19:         Write-Host "  [PASS] $Name" -ForegroundColor Green
   20:         $script:pass++
   21:     } else {
   22:         Write-Host "  [FAIL] $Name" -ForegroundColor Red
   23:         $script:fail++
   24:     }
   25: }
   26: 
   27: # Local-only check: runtime artifact of a working machine, absent on CI runners.
   28: # In CI mode prints [CI-SKIP] and is not counted in pass/fail.
   29: function Test-LocalCheck {
   30:     param([string]$Name, [bool]$Condition)
   31:     if ($script:isCI) {
   32:         Write-Host "  [CI-SKIP] $Name (local runtime artifact)" -ForegroundColor DarkYellow
   33:         $script:ciSkipped++
   34:     } else {
   35:         Test-Check $Name $Condition
   36:     }
   37: }
   38: 
   39: # Phase 0: ACP
   40: Write-Host "Phase 0: Agent Communication Protocol" -ForegroundColor Yellow
   41: Test-LocalCheck ".memory/inbox/ exists" (Test-Path ".memory\inbox")
   42: Test-Check ".memory/outbox/ exists" (Test-Path ".memory\outbox")
   43: Test-LocalCheck ".memory/dead-letter/ exists" (Test-Path ".memory\dead-letter")
   44: 
   45: $inboxAgents = Get-ChildItem ".memory\inbox" -Directory -ErrorAction SilentlyContinue | Measure-Object
   46: Test-LocalCheck "At least 1 agent inbox" ($inboxAgents.Count -ge 1)
   47: 
   48: # Phase 0.5: Sandbox
   49: Write-Host ""
   50: Write-Host "Phase 0.5: Sandbox via git worktree" -ForegroundColor Yellow
   51: Test-LocalCheck ".agents/worktrees/ exists" (Test-Path ".agents\worktrees")
   52: 
   53: $worktrees = Get-ChildItem ".agents\worktrees" -Directory -ErrorAction SilentlyContinue | Measure-Object
   54: Test-LocalCheck "At least 1 worktree" ($worktrees.Count -ge 1)
   55: 
   56: # Phase 1: Memory Bank
   57: Write-Host ""
   58: Write-Host "Phase 1: Memory Bank" -ForegroundColor Yellow
   59: $mbFiles = @("activeContext.md", "decisionLog.md", "productContext.md", "progress.md", "systemPatterns.md")
   60: foreach ($f in $mbFiles) {
   61:     $path = ".memory\$f"
   62:     $exists = Test-Path $path
   63:     if ($exists) {
   64:         $size = (Get-Item $path).Length
   65:         Test-Check "$f exists and not empty" ($size -gt 0)
   66:     } else {
   67:         Test-Check "$f exists and not empty" $false
   68:     }
   69: }
   70: 
   71: # Phase 2: Agent Configs
   72: Write-Host ""
   73: Write-Host "Phase 2: Agent Configurations" -ForegroundColor Yellow
   74: Test-Check ".opencode/agents/ exists" (Test-Path ".opencode\agents")
   75: 
   76: $jsonFiles = Get-ChildItem ".opencode\agents\*.json" -ErrorAction SilentlyContinue | Measure-Object
   77: Test-Check "At least 5 JSON configs" ($jsonFiles.Count -ge 5)
   78: 
   79: # Phase 2.5: Git
   80: Write-Host ""
   81: Write-Host "Phase 2.5: Git Versioning" -ForegroundColor Yellow
   82: Test-Check ".git/ exists" (Test-Path ".git")
   83: Test-Check ".gitignore exists" (Test-Path ".gitignore")
   84: 
   85: # Phase 3: Skills
   86: Write-Host ""
   87: Write-Host "Phase 3: Skills" -ForegroundColor Yellow
   88: Test-Check ".agents/skills/ exists" (Test-Path ".agents\skills")
   89: 
   90: $skills = Get-ChildItem ".agents\skills" -Directory -ErrorAction SilentlyContinue | Measure-Object
   91: Test-Check "At least 1 skill folder" ($skills.Count -ge 1)
   92: 
   93: # Phase 11: Commands
   94: Write-Host ""
   95: Write-Host "Phase 11: Commands" -ForegroundColor Yellow
   96: $config = Get-Content "opencode.json" -Raw | ConvertFrom-Json
   97: $hasSync = $null -ne $config.command.sync
   98: $hasStatus = $null -ne $config.command.status
   99: Test-Check "/sync command defined" $hasSync
  100: Test-Check "/status command defined" $hasStatus
  101: 
  102: # Phase B2: Agent Registration
  103: Write-Host ""
  104: Write-Host "Phase B2: Agent Registration" -ForegroundColor Yellow
  105: $ocRaw = Get-Content "opencode.json" -Raw -ErrorAction SilentlyContinue
  106: if ($ocRaw) {
  107:     $oc = $ocRaw | ConvertFrom-Json
  108:     Test-Check "opencode.json has agents section" ($null -ne $oc.agents)
  109:     if ($null -ne $oc.agents) {
  110:         $agentCount = ($oc.agents | Get-Member -MemberType NoteProperty).Count
  111:         Test-Check "agents section has >= 30 entries ($agentCount found)" ($agentCount -ge 30)
  112:     } else {
  113:         Test-Check "agents section has >= 30 entries" $false
  114:     }
  115: } else {
  116:     Test-Check "opencode.json has agents section" $false
  117:     Test-Check "agents section has >= 30 entries" $false
  118: }
  119: $promptsDir = ".opencode\agents\prompts"
  120: $promptsExist = Test-Path $promptsDir
  121: Test-Check ".opencode/agents/prompts/ exists" $promptsExist
  122: if ($promptsExist) {
  123:     $promptFiles = Get-ChildItem "$promptsDir\*.txt" -ErrorAction SilentlyContinue | Measure-Object
  124:     Test-Check "prompts has >= 19 .txt files ($($promptFiles.Count) found)" ($promptFiles.Count -ge 19)
  125: } else {
  126:     Test-Check "prompts has >= 19 .txt files" $false
  127: }
  128: 
  129: # Phase D2: Context Bus
  130: Write-Host ""
  131: Write-Host "Phase D2: Context Bus" -ForegroundColor Yellow
  132: $ctxExists = Test-Path "CONTEXT-BUFFER.md"
  133: if ($ctxExists) {
  134:     $ctxSize = (Get-Item "CONTEXT-BUFFER.md").Length
  135:     Test-Check "CONTEXT-BUFFER.md exists and not empty" ($ctxSize -gt 0)
  136: } else {
  137:     Test-Check "CONTEXT-BUFFER.md exists and not empty" $false
  138: }
  139: $agentsExists = Test-Path "AGENTS.md"
  140: if ($agentsExists) {
  141:     $agentsSize = (Get-Item "AGENTS.md").Length
  142:     Test-Check "AGENTS.md exists and not empty" ($agentsSize -gt 0)
  143: } else {
  144:     Test-Check "AGENTS.md exists and not empty" $false
  145: }
  146: 
  147: # Phase E2: Real Code Features
  148: Write-Host ""
  149: Write-Host "Phase E2: Real Code Features" -ForegroundColor Yellow
  150: Test-Check ".opencode/plugins/tracer.js exists" (Test-Path ".opencode\plugins\tracer.js")
  151: Test-Check ".opencode/plugins/scoring.js exists" (Test-Path ".opencode\plugins\scoring.js")
  152: Test-Check ".agents/scripts/health-check.ps1 exists" (Test-Path ".agents\scripts\health-check.ps1")
  153: $tracesDir = Join-Path $env:LOCALAPPDATA "opencode\agent-hq-traces"
  154: $tracesPath = Join-Path $tracesDir "traces.jsonl"
  155: $tracesExists = Test-Path $tracesPath
  156: if ($tracesExists) {
  157:     $tracesSize = (Get-Item $tracesPath).Length
  158:     Test-LocalCheck "traces.jsonl exists and not empty (in LOCALAPPDATA)" ($tracesSize -gt 0)
  159: } else {
  160:     Test-LocalCheck "traces.jsonl exists and not empty (in LOCALAPPDATA)" $false
  161: }
  162: 
  163: # Phase F: US-011..015 Multi-Project
  164: Write-Host ""
  165: Write-Host "Phase F: US-011..015 Multi-Project" -ForegroundColor Yellow
```

### `.agents/scripts/verify-phase.ps1` lines 214-396

```powershell
  214: # F4: .memory/agent-registry.json valid JSON, 30 agents, has status/daily_load fields
  215: $registryPath = ".memory\agent-registry.json"
  216: $registryValid = $false
  217: $registryAgentCount = 0
  218: $hasStatusField = $false
  219: $hasDailyLoadField = $false
  220: if (Test-Path $registryPath) {
  221:     try {
  222:         $content = [System.IO.File]::ReadAllText($registryPath, [System.Text.UTF8Encoding]::new($false))
  223:         $registry = $content | ConvertFrom-Json -ErrorAction Stop
  224:         $registryValid = $true
  225:         if ($registry.agents) {
  226:             $registryAgentCount = ($registry.agents | Get-Member -MemberType NoteProperty).Count
  227:             # Check first agent for status and daily_load fields
  228:             $firstAgentName = ($registry.agents | Get-Member -MemberType NoteProperty)[0].Name
  229:             $firstAgent = $registry.agents.$firstAgentName
  230:             $hasStatusField = $null -ne $firstAgent.status
  231:             $hasDailyLoadField = $null -ne $firstAgent.daily_load
  232:         }
  233:     } catch {
  234:         $registryValid = $false
  235:     }
  236: }
  237: Test-Check "F4: agent-registry.json valid, 30 agents, has status/daily_load ($registryAgentCount agents)" ($registryValid -and $registryAgentCount -ge 30 -and $hasStatusField -and $hasDailyLoadField)
  238: 
  239: # F5: agent-registry.ps1 -List -Status free -> exit 0, output contains "free"
  240: $regScript = ".agents\scripts\agent-registry.ps1"
  241: $f5Pass = $false
  242: if (Test-Path $regScript) {


---
Ответь только: `Принято 11/15`. Жди следующую часть.
