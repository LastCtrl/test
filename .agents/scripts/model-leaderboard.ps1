<#
.SYNOPSIS
    Rating leaderboard for models based on acceptance records.
.DESCRIPTION
    Reads .memory/ratings.jsonl, builds summary tables by model, agent, and task type.
    Bad lines produce a warning and are skipped. Empty file shows a "no ratings" message.
.PARAMETER ByModel
    Summary table: model -> count, average grade
.PARAMETER ByAgent
    Summary table: agent -> count, average grade
.PARAMETER ByTaskType
    Filter by task type (string)
.PARAMETER Root
    Project root directory. Defaults to the script's grandparent directory.
.EXAMPLE
    .\model-leaderboard.ps1
    .\model-leaderboard.ps1 -ByModel
    .\model-leaderboard.ps1 -ByAgent
    .\model-leaderboard.ps1 -ByTaskType "review"
    .\model-leaderboard.ps1 -Root "D:\Projects\my-project"
#>
[CmdletBinding()]
param(
    [switch]$ByModel,
    [switch]$ByAgent,
    [string]$ByTaskType,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

# Path resolution: try $PSScriptRoot, fall back to $pwd
if ([string]::IsNullOrEmpty($Root)) {
    if (![string]::IsNullOrEmpty($PSScriptRoot)) {
        $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    }
    else {
        $Root = $pwd.Path
    }
}

$RatingsPath = Join-Path $Root ".memory\ratings.jsonl"

# If nothing specified - show all
$ShowAll = (-not $ByModel) -and (-not $ByAgent) -and (-not $ByTaskType)

# --- Read and parse ---
$entries = @()
if (!(Test-Path $RatingsPath)) {
    Write-Host "Ratings file not found: $RatingsPath"
    exit 1
}

$lines = Get-Content -Path $RatingsPath -Encoding UTF8 -ErrorAction SilentlyContinue
if ($null -eq $lines -or $lines.Count -eq 0) {
    Write-Host "Rating is empty - no ratings yet"
    exit 0
}

$lineNum = 0
foreach ($line in $lines) {
    $lineNum++
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

    try {
        $obj = $trimmed | ConvertFrom-Json
        # Validate required fields
        if ([string]::IsNullOrEmpty($obj.model) -or
            [string]::IsNullOrEmpty($obj.agent) -or
            [string]::IsNullOrEmpty($obj.task_type) -or
            $null -eq $obj.grade -or
            [string]::IsNullOrEmpty($obj.date)) {
            Write-Warning "Line ${lineNum}: skipped - missing required fields (model/agent/task_type/grade/date)"
            continue
        }
        # Validate grade type
        if ($obj.grade -isnot [int] -and $obj.grade -isnot [double]) {
            Write-Warning "Line ${lineNum}: skipped - grade is not a number (type: $($obj.grade.GetType().Name))"
            continue
        }
        $entries += $obj
    }
    catch {
        Write-Warning "Line ${lineNum}: skipped - JSON parse error: $($_.Exception.Message)"
        continue
    }
}

if ($entries.Count -eq 0) {
    Write-Host "Rating is empty - no ratings yet"
    exit 0
}

# --- Display table function ---
function Show-GroupTable {
    param(
        [string]$Title,
        [array]$Data,
        [string]$GroupField
    )

    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    Write-Host ""

    $grouped = $Data | Group-Object -Property $GroupField | Sort-Object { $_.Name }
    $results = @()

    foreach ($g in $grouped) {
        $count = $g.Count
        $avg = ($g.Group | Measure-Object -Property grade -Average).Average
        $results += [PSCustomObject]@{
            Name  = $g.Name
            Count = $count
            Avg   = [math]::Round($avg, 2)
        }
    }

    $colLabel = $GroupField.Replace('_',' ').ToUpper()
    $results | Format-Table -AutoSize -Property `
        @{Label=$colLabel; Expression={$_.Name}},
        @{Label="COUNT"; Expression={$_.Count}},
        @{Label="AVG"; Expression={$_.Avg}}
}

# --- Output ---
Write-Host ""
Write-Host "RATING LEADERBOARD" -ForegroundColor Green
Write-Host "Total ratings: $($entries.Count)" -ForegroundColor Yellow
Write-Host "Unique models: $(($entries | Select-Object -ExpandProperty model -Unique).Count)"
Write-Host "Unique agents: $(($entries | Select-Object -ExpandProperty agent -Unique).Count)"

if ($ShowAll -or $ByModel) {
    Show-GroupTable -Title "BY MODEL" -Data $entries -GroupField "model"
}

if ($ShowAll -or $ByAgent) {
    Show-GroupTable -Title "BY AGENT" -Data $entries -GroupField "agent"
}

if ($ShowAll -or $ByTaskType) {
    if ($ByTaskType) {
        $filtered = $entries | Where-Object { $_.task_type -eq $ByTaskType }
        if ($filtered.Count -eq 0) {
            Write-Host ""
            Write-Host "No ratings with task_type='$ByTaskType'" -ForegroundColor Yellow
        }
        else {
            Show-GroupTable -Title "BY TASK TYPE: $ByTaskType (found: $($filtered.Count))" -Data $filtered -GroupField "task_type"
            Show-GroupTable -Title "MODELS IN TYPE '$ByTaskType'" -Data $filtered -GroupField "model"
        }
    }
    else {
        Show-GroupTable -Title "BY TASK TYPES" -Data $entries -GroupField "task_type"
    }
}

Write-Host ""
