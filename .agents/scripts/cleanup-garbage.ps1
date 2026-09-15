param(
    [switch]$DryRun,
    [switch]$Execute,
    [switch]$Verbose
)

# ============================================================
# cleanup-garbage.ps1 - avtoochistka musora v repo agent-hq
# Bezopasen po umolchaniyu (dry-run). Idempotenten. S otchyotom.
# PowerShell 5.1 compatible.
# ============================================================

$ErrorActionPreference = "Stop"

# --- Opredelyaem rezim ---
$isDryRun = $true
if ($Execute -and -not $DryRun) {
    $isDryRun = $false
}

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Error "Repo root not found: $root"
    exit 1
}

Write-Host "=== Cleanup Garbage ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
if ($isDryRun) {
    Write-Host "Mode: DRY RUN (use -Execute to delete)" -ForegroundColor Yellow
} else {
    Write-Host "Mode: EXECUTE (real deletion)" -ForegroundColor Red
}
Write-Host ""

# --- Sobirayem kandidatov ---
$candidates = [System.Collections.ArrayList]::new()

# --- Kategoriya 1: temp_* v korne ---
$tempFiles = Get-ChildItem -LiteralPath $root -Filter "temp_*" -File -ErrorAction SilentlyContinue
foreach ($f in $tempFiles) {
    [void]$candidates.Add(@{
        Path     = $f.FullName
        Size     = $f.Length
        Category = "temp_* (root)"
    })
}

# --- Kategoriya 1b: temp_* direktorii v korne ---
$tempDirs = Get-ChildItem -LiteralPath $root -Filter "temp_*" -Directory -ErrorAction SilentlyContinue
foreach ($d in $tempDirs) {
    $relPath = $d.FullName.Substring($root.Length + 1)
    if ($relPath -eq ".git" -or $relPath -eq ".agents\worktrees" -or $relPath -eq ".memory") {
        if ($Verbose) { Write-Host "  SKIP protected dir: $relPath" -ForegroundColor DarkGray }
        continue
    }
    $size = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) { $size = 0 }
    [void]$candidates.Add(@{
        Path     = $d.FullName
        Size     = $size
        Category = "temp_* (dir)"
    })
}

# --- Kategoriya 2: *.bak.* v .opencode/agents/ ---
$agentsDir = Join-Path $root ".opencode\agents"
if (Test-Path -LiteralPath $agentsDir -PathType Container) {
    $bakFiles = Get-ChildItem -LiteralPath $agentsDir -Filter "*.bak.*" -File -ErrorAction SilentlyContinue
    foreach ($f in $bakFiles) {
        [void]$candidates.Add(@{
            Path     = $f.FullName
            Size     = $f.Length
            Category = "*.bak.* (agents)"
        })
    }
}

# --- Kategoriya 3: opencode.json.bak.* v korne (ostavit' poslednie 3) ---
$rootBaks = Get-ChildItem -LiteralPath $root -Filter "opencode.json.bak.*" -File -ErrorAction SilentlyContinue
if ($rootBaks.Count -gt 3) {
    $toDelete = $rootBaks | Sort-Object Name -Descending | Select-Object -Skip 3
    foreach ($f in $toDelete) {
        [void]$candidates.Add(@{
            Path     = $f.FullName
            Size     = $f.Length
            Category = "opencode.json.bak.* (old)"
        })
    }
}

# --- Kategoriya 4: Stray root-level agent JSON (dynamic detection) ---
# Any *.json in root that has a same-named counterpart in .opencode/agents/
# EXCLUDE: opencode.json (legitimate repo config)
if (Test-Path -LiteralPath $agentsDir -PathType Container) {
    $agentJsonFiles = Get-ChildItem -LiteralPath $agentsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($agentFile in $agentJsonFiles) {
        $strayPath = Join-Path $root $agentFile.Name
        if ($agentFile.Name -ne "opencode.json" -and (Test-Path -LiteralPath $strayPath -PathType Leaf)) {
            $size = (Get-Item -LiteralPath $strayPath).Length
            [void]$candidates.Add(@{
                Path     = $strayPath
                Size     = $size
                Category = "stray agent JSON (root)"
            })
        }
    }
}

# --- Kategoriya 4b: Stray root-level prompts/ directory ---
# If canonical .opencode/agents/prompts/ exists AND root prompts/ exists, root is stray
$canonicalPrompts = Join-Path $agentsDir "prompts"
$rootPrompts = Join-Path $root "prompts"
$canonicalExists = Test-Path -LiteralPath $canonicalPrompts -PathType Container
$rootPromptsExists = Test-Path -LiteralPath $rootPrompts -PathType Container
if ($canonicalExists -and $rootPromptsExists) {
    $promptsSize = (Get-ChildItem -LiteralPath $rootPrompts -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $promptsSize) { $promptsSize = 0 }
    [void]$candidates.Add(@{
        Path     = $rootPrompts
        Size     = $promptsSize
        Category = "stray root prompts/"
    })
}

# --- Kategoriya 5: pustye temp_* direktorii ---
foreach ($d in $tempDirs) {
    $items = Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -eq $items -or $items.Count -eq 0) {
        $already = $false
        foreach ($c in $candidates) {
            if ($c.Path -eq $d.FullName) { $already = $true; break }
        }
        if (-not $already) {
            [void]$candidates.Add(@{
                Path     = $d.FullName
                Size     = 0
                Category = "temp_* (empty dir)"
            })
        }
    }
}

# --- Vivod tablitsy ---
Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host ("{0,-28} {1,-35} {2,10} {3,8}" -f "Category", "Path", "Size", "Action") -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor DarkGray

$totalSize = 0
foreach ($c in $candidates) {
    $sizeKB = [math]::Round($c.Size / 1024, 1)
    $shortPath = $c.Path
    if ($shortPath.StartsWith($root)) {
        $shortPath = "." + $shortPath.Substring($root.Length)
    }
    $action = if ($isDryRun) { "skip*" } else { "delete" }
    Write-Host ("{0,-28} {1,-35} {2,8} KB {3,8}" -f $c.Category, $shortPath, $sizeKB, $action)
    $totalSize += $c.Size
}
Write-Host ("=" * 70) -ForegroundColor DarkGray

if ($candidates.Count -eq 0) {
    Write-Host "`nNo garbage found. Repo is clean." -ForegroundColor Green
    exit 0
}

$totalSizeKB = [math]::Round($totalSize / 1024, 1)
Write-Host "`nFound: $($candidates.Count) item(s), total $totalSizeKB KB" -ForegroundColor White

# --- DryRun ---
if ($isDryRun) {
    Write-Host "`nDRY RUN -- nothing deleted. Use -Execute to delete." -ForegroundColor Yellow
    exit 0
}

# --- Execute: udalenie ---
$removed = 0
$skipped = 0
$freed = 0

foreach ($c in $candidates) {
    try {
        if (Test-Path -LiteralPath $c.Path) {
            Remove-Item -LiteralPath $c.Path -Recurse -Force
            $removed++
            $freed += $c.Size
            if ($Verbose) {
                Write-Host "  DELETED: $($c.Path)" -ForegroundColor Red
            }
        } else {
            $skipped++
            if ($Verbose) {
                Write-Host "  GONE (already): $($c.Path)" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        $skipped++
        Write-Warning "Failed to delete: $($c.Path) -- $($_.Exception.Message)"
    }
}

$freedKB = [math]::Round($freed / 1024, 1)
Write-Host "`nRemoved: $removed | Skipped: $skipped | Freed: $freed KB" -ForegroundColor Cyan
exit 0