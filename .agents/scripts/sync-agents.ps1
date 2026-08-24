param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$agentsDir = Join-Path $root ".opencode\agents"
$promptsDir = Join-Path $agentsDir "prompts"
$configPath = Join-Path $root "opencode.json"

if (-not (Test-Path $promptsDir)) {
    New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
}

$allowKeys = @("read", "edit", "bash", "glob", "grep", "skill", "question", "webfetch", "websearch", "task", "list")
$denyIfMissing = @("edit", "bash", "task")

$jsonFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }

Write-Host "=== Sync Agents: $($jsonFiles.Count) files found ===" -ForegroundColor Cyan

$agentSection = [ordered]@{}
$count = 0

foreach ($file in $jsonFiles) {
    $raw = [System.IO.File]::ReadAllText($file.FullName)
    $data = $raw | ConvertFrom-Json

    $name = if ($data.name) { $data.name } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }

    $promptFile = Join-Path $promptsDir "$name.txt"
    [System.IO.File]::WriteAllText($promptFile, $data.prompt, [System.Text.UTF8Encoding]::new($false))

    $perm = [ordered]@{}
    foreach ($key in $allowKeys) {
        if ($data.permissions -contains $key) {
            $perm[$key] = "allow"
        } elseif ($denyIfMissing -contains $key) {
            $perm[$key] = "deny"
        }
    }

    $entry = [ordered]@{}
    $entry["description"] = $data.description
    $entry["mode"] = if ($data.mode) { $data.mode } else { "subagent" }
    if ($data.model) { $entry["model"] = $data.model }
    if ($null -ne $data.temperature) { $entry["temperature"] = [double]$data.temperature }
    $entry["permission"] = $perm
    $entry["prompt"] = "{file:.opencode/agents/prompts/$name.txt}"

    $agentSection[$name] = $entry
    $count++
    Write-Host "  [$count] $name -> $($data.model)" -ForegroundColor Green
}

if ($DryRun) {
    Write-Host "`n=== DRY RUN: generated section preview ===" -ForegroundColor Yellow
    $agentSection | ConvertTo-Json -Depth 10
    exit 0
}

if (-not (Test-Path $configPath)) { throw "opencode.json not found: $configPath" }
$configRaw = [System.IO.File]::ReadAllText($configPath)
$config = $configRaw | ConvertFrom-Json

if ($config.PSObject.Properties["agent"]) {
    $config.agent = $agentSection
} else {
    $config | Add-Member -MemberType NoteProperty -Name "agent" -Value $agentSection
}

$jsonOut = $config | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($configPath, $jsonOut, [System.Text.UTF8Encoding]::new($false))

Write-Host "`n=== DONE: $count agents written to opencode.json ===" -ForegroundColor Cyan
Write-Host "Prompts saved to: $promptsDir" -ForegroundColor Gray
