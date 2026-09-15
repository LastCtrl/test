<#
.SYNOPSIS
  Generates machine-readable agent cards per A2A Agent Card pattern.
.DESCRIPTION
  Reads .opencode/agents/<name>.json (except registry.json), extracts
  name, model, mode, prompt; heuristically determines role_summary and capabilities;
  generates .agents/cards/<name>.json and .agents/cards/index.json.
.PARAMETER Root
  Repository root path. Default: $env:AGENT_HQ_ROOT if set, else inferred from $PSScriptRoot.
.PARAMETER OutDir
  Output directory for cards (relative to Root). Default: .agents\cards\.
.NOTES
  PowerShell 5.1, UTF-8 without BOM.
  Do not commit. Clean up temp files.
#>

[CmdletBinding()]
param(
    [string]$Root = $(if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }),
    [string]$OutDir = ".agents\cards\"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Input validation ---
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Root directory not found: $Root"
}

$AgentsDir = Join-Path $Root ".opencode\agents"
if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    throw "Agents directory not found: $AgentsDir"
}

$FullOutDir = Join-Path $Root $OutDir
if (-not (Test-Path -LiteralPath $FullOutDir -PathType Container)) {
    New-Item -ItemType Directory -Path $FullOutDir -Force | Out-Null
}

# UTF-8 without BOM encoding
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Read-only agents list
$ReadOnlyAgents = @("qa-engineer", "code-reviewer", "security-auditor")

# Delegation agents list
$DelegationAgents = @("team-lead")

# --- Read and process agents ---
$AgentFiles = Get-ChildItem -LiteralPath $AgentsDir -Filter "*.json" |
    Where-Object { $_.Name -ne "registry.json" }

if ($AgentFiles.Count -eq 0) {
    throw "No agent .json files found in $AgentsDir"
}

$Cards = @()

foreach ($File in $AgentFiles) {
    try {
        # Read JSON with guaranteed UTF-8
        $JsonText = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
        $Agent = $JsonText | ConvertFrom-Json
    }
    catch {
        Write-Warning "Error reading/parsing $($File.Name): $_"
        continue
    }

    # --- Field validation ---
    if ([string]::IsNullOrWhiteSpace($Agent.name)) {
        Write-Warning "Skipping $($File.Name): 'name' field is empty"
        continue
    }
    if ([string]::IsNullOrWhiteSpace($Agent.model)) {
        Write-Warning "Skipping $($Agent.name): 'model' field is empty"
        continue
    }

    $Name = $Agent.name
    $Model = $Agent.model
    $Mode = if ($Agent.mode) { $Agent.mode } else { "subagent" }
    $Prompt = if ($Agent.prompt) { $Agent.prompt } else { "" }

    # --- Role Summary: first 2-3 lines before first ## ---
    $RoleSummary = ""
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $Lines = $Prompt -split "`n"
        $RoleLines = @()
        foreach ($Line in $Lines) {
            $Trimmed = $Line.Trim()
            if ($Trimmed -match "^##") { break }
            if ($Trimmed.Length -gt 0) {
                $RoleLines += $Trimmed
            }
            if ($RoleLines.Count -ge 3) { break }
        }
        $RoleSummary = ($RoleLines -join " ").Trim()
        # Limit to 200 chars
        if ($RoleSummary.Length -gt 200) {
            $RoleSummary = $RoleSummary.Substring(0, 200)
        }
    }

    # --- Capabilities: heuristic detection ---
    $Capabilities = @()

    # MCP: marker presence
    if ($Prompt -match "ИНСТРУМЕНТЫ MCP") {
        $Capabilities += "MCP"
    }

    # skills-first: .agents/skills/ mention
    if ($Prompt -match "\.agents/skills/") {
        $Capabilities += "skills-first"
    }

    # read-only: checking agents
    if ($ReadOnlyAgents -contains $Name) {
        $Capabilities += "read-only"
    }

    # delegation: delegating agents
    if ($DelegationAgents -contains $Name) {
        $Capabilities += "delegation"
    }

    # --- Agent Card (A2A pattern) ---
    $Card = [ordered]@{
        name         = $Name
        model        = $Model
        mode         = $Mode
        role_summary = $RoleSummary
        capabilities = $Capabilities
        division     = $Agent.division
        deliverable  = $Agent.deliverable
        success_metric = $Agent.success_metric
        generated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    }

    # Write individual card
    $CardPath = Join-Path $FullOutDir "$Name.json"
    $CardJson = $Card | ConvertTo-Json -Depth 10 -Compress
    try {
        [System.IO.File]::WriteAllText($CardPath, $CardJson, $Utf8NoBom)
    }
    catch {
        Write-Warning "Error writing card for $Name : $_"
        continue
    }

    $Cards += $Card
}

if ($Cards.Count -eq 0) {
    throw "No cards were created"
}

# --- Index file ---
$Index = [ordered]@{
    schema       = "a2a-agent-card-index"
    version      = "1.0"
    generated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    count        = $Cards.Count
    agents       = $Cards
}

$IndexPath = Join-Path $FullOutDir "index.json"
$IndexJson = $Index | ConvertTo-Json -Depth 10 -Compress
try {
    [System.IO.File]::WriteAllText($IndexPath, $IndexJson, $Utf8NoBom)
}
catch {
    throw "Error writing index.json: $_"
}

# --- Print table ---
Write-Output ""
Write-Output "=== Agent Cards Generated ==="
Write-Output ("{0,-25} {1,-40} {2}" -f "AGENT", "MODEL", "CAPS")
Write-Output ("-" * 80)

foreach ($Card in $Cards) {
    $CapCount = $Card.capabilities.Count
    $CapsStr = if ($CapCount -gt 0) { $Card.capabilities -join "," } else { "-" }
    Write-Output ("{0,-25} {1,-40} {2}" -f $Card.name, $Card.model, $CapsStr)
}

Write-Output ("-" * 80)
Write-Output "Total: $($Cards.Count) agents"

# --- Self-check: index.json == agent count ---
Write-Output ""
Write-Output "=== Self-Check ==="

$VerifyJson = [System.IO.File]::ReadAllText($IndexPath, [System.Text.Encoding]::UTF8)
$VerifyIndex = $VerifyJson | ConvertFrom-Json
$VerifyCount = @($VerifyIndex.agents).Count

if ($VerifyCount -ge 19) {
    Write-Output "PASS: index.json contains $VerifyCount agent cards (>= 19)"
}
else {
    Write-Warning "FAIL: index.json contains $VerifyCount agent cards (>= 19 expected)"
}

# Files count in cards/
$CardFiles = Get-ChildItem -LiteralPath $FullOutDir -Filter "*.json"
Write-Output "Files in $OutDir : $($CardFiles.Count)"