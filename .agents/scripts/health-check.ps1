param()

$ErrorActionPreference = "Continue"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hasFail = $false

Write-Host "=== agent-hq Health Check ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host ""

# --- 1. Traces: type:error за последние 60 минут ---
$tracesPath = Join-Path $root ".memory\traces\traces.jsonl"
if (Test-Path $tracesPath) {
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
    $errorCount = 0
    $lines = Get-Content $tracesPath -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -eq $obj) { continue }
            if ($obj.type -eq "error" -and $obj.ts) {
                $ts = [DateTime]::Parse($obj.ts).ToUniversalTime()
                if ($ts -ge $cutoff) { $errorCount++ }
            }
        } catch { continue }
    }
    if ($errorCount -gt 5) {
        Write-Host "[FAIL] Traces: $errorCount errors in last 60 min" -ForegroundColor Red
        $hasFail = $true
    } elseif ($errorCount -gt 0) {
        Write-Host "[WARN] Traces: $errorCount errors in last 60 min" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Traces: 0 errors in last 60 min" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] Traces: traces.jsonl not found (no errors)" -ForegroundColor Green
}

# --- 2. Inbox backlog ---
$inboxDir = Join-Path $root ".memory\inbox"
$inboxCount = 0
if (Test-Path $inboxDir) {
    $inboxCount = (Get-ChildItem -Path $inboxDir -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    if ($inboxCount -gt 50) {
        Write-Host "[FAIL] Inbox backlog: $inboxCount files" -ForegroundColor Red
        $hasFail = $true
    } elseif ($inboxCount -gt 20) {
        Write-Host "[WARN] Inbox backlog: $inboxCount files" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Inbox backlog: $inboxCount files" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] Inbox: directory not found" -ForegroundColor Green
}

# --- 3. Outbox (информативно) ---
$outboxDir = Join-Path $root ".memory\outbox"
$outboxCount = 0
if (Test-Path $outboxDir) {
    $outboxCount = (Get-ChildItem -Path $outboxDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
    Write-Host "[OK] Outbox: $outboxCount files" -ForegroundColor Green
} else {
    Write-Host "[OK] Outbox: directory not found" -ForegroundColor Green
}

# --- 4. Worktrees ---
Write-Host "" -ForegroundColor Gray
Write-Host "--- Git Worktrees ---" -ForegroundColor Cyan
try {
    $wtOutput = & git -C $root worktree list 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $wtOutput) { Write-Host "  $line" -ForegroundColor Gray }
        Write-Host "[OK] Worktrees: listed" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Worktrees: git command failed" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] Worktrees: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 5. Performance: средняя duration_ms ---
$perfPath = Join-Path $root ".memory\traces\performance.jsonl"
if (Test-Path $perfPath) {
    $durations = @()
    $perfLines = Get-Content $perfPath -ErrorAction SilentlyContinue
    foreach ($line in $perfLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $obj -and $obj.duration_ms) {
                $durations += [double]$obj.duration_ms
            }
        } catch { continue }
    }
    if ($durations.Count -gt 0) {
        $avgMs = ($durations | Measure-Object -Average).Average
        $avgSec = [math]::Round($avgMs / 1000, 2)
        Write-Host "[OK] Performance: avg session duration = ${avgSec}s ($($durations.Count) sessions)" -ForegroundColor Green
    } else {
        Write-Host "[OK] Performance: no duration data" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] Performance: performance.jsonl not found" -ForegroundColor Green
}

# --- 6. Disk space ---
$drive = Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue
if ($drive) {
    $freeGB = [math]::Round($drive.Free / 1GB, 2)
    if ($freeGB -lt 5) {
        Write-Host "[WARN] Disk: ${freeGB}GB free" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Disk: ${freeGB}GB free" -ForegroundColor Green
    }
} else {
    Write-Host "[WARN] Disk: cannot determine free space" -ForegroundColor Yellow
}

# --- Итог ---
Write-Host "" -ForegroundColor Gray
if ($hasFail) {
    Write-Host "HEALTH: FAIL" -ForegroundColor Red
    exit 1
} else {
    Write-Host "HEALTH: PASS" -ForegroundColor Green
    exit 0
}