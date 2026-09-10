[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$KillStale,
    [double]$ThresholdHours = 6,
    [switch]$KillAll
)

# ============================================================
# tui-cleanup.ps1 - chistilshik zavisshih opencode TUI-sessij
# Bezopasen po umolchaniyu (spisok bez ubijstva).
#   .\tui-cleanup.ps1                  - tablitsa (dry-run)
#   .\tui-cleanup.ps1 -KillStale       - ubit STALE (>6h po umolchaniyu)
#   .\tui-cleanup.ps1 -KillStale -ThresholdHours 12 - porog 12 chasov
#   .\tui-cleanup.ps1 -KillAll         - ubit vse krome NEWEST i SELF
#   -WhatIf                            - pokazat chto BYLO by ubito
# Log: .memory/traces/tui-cleanup.log (UTF-8 no BOM, append)
# Exit codes: 0 = ok/nichego, 1 = oshibka, 2 = chto-to ubito
# PowerShell 5.1 compatible.
# ============================================================

$ErrorActionPreference = "Stop"
$DefaultThresholdHours = 6

# WhatIf ne dolzhen protekat' v Get-CimInstance (shum v vyvode) -
# zahvatyvaem v svoyu peremennuyu i gasim preferens.
$script:WouldKill = [bool]$WhatIfPreference
$WhatIfPreference = $false

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$logDir = Join-Path $repoRoot ".memory\traces"
$logPath = Join-Path $logDir "tui-cleanup.log"

# --- Rezhim ---
# FIX (code-review major): primenenie+validaciya poroga DO vetvleniya rezhimov,
# inache dry-run/list pokazyvaet 6h nezavisimo ot peredannogo -ThresholdHours
if ($null -ne $ThresholdHours -and $ThresholdHours -lt 1) {
    Write-Host ("Oshibka: porog {0} ch nedopustim - minimum 1 chas (zashchita ot opechatki tipa 0.5)." -f $ThresholdHours) -ForegroundColor Red
    exit 1
}
$threshold = if ($null -ne $ThresholdHours) { $ThresholdHours } else { $DefaultThresholdHours }
$mode = "list"

if ($KillAll -and $KillStale) {
    Write-Warning "Ukazany i -KillAll i -KillStale: -KillAll imeet prioritet."
}

if ($KillAll) {
    $mode = "killall"
} elseif ($KillStale) {
    $mode = "killstale"
}

function Write-LogLine {
    param([string]$Line)
    try {
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $logDir -Force)
        }
        # Rotaciya: >1MB -> obrezat do poslednih 500 strok
        if (Test-Path -LiteralPath $logPath) {
            $fi = Get-Item -LiteralPath $logPath
            if ($fi.Length -gt 1MB) {
                $tail = @(Get-Content -LiteralPath $logPath -Tail 500)
                $enc0 = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllLines($logPath, $tail, $enc0)
            }
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($logPath, $Line + "`r`n", $enc)
    } catch {
        Write-Warning "Log write failed (audit lost): $($_.Exception.Message)"
    }
}

function Find-SelfOpencodePid {
    $found = 0
    $cur = $PID
    for ($i = 0; $i -lt 12; $i++) {
        if ($cur -le 0) { break }
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -eq "opencode.exe") { $found = [int]$p.ProcessId; break }
        $cur = [int]$p.ParentProcessId
    }
    return $found
}

# --- Sbor processov ---
# FIX (code-review minor): CIM-zapros v try/catch - sbroj WMI ne dolzhen krashit bez loga
try {
    $cimProcs = @(Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction Stop)
} catch {
    Write-Host "Oshibka sbora processov (WMI/CIM): $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($cimProcs.Count -eq 0) {
    Write-Host "No opencode.exe processes found. Nothing to do." -ForegroundColor Green
    exit 0
}

$now = Get-Date
$selfPid = Find-SelfOpencodePid

$procs = @()
foreach ($cp in $cimProcs) {
    $cmd = $cp.CommandLine
    if (-not $cmd) { $cmd = "" }
    $isWorker = ($cmd -match 'run\s+--agent')
    $cpuSec = 0.0
    $ramMb = 0
    try {
        $gp = Get-Process -Id $cp.ProcessId -ErrorAction Stop
        if ($gp.TotalProcessorTime) { $cpuSec = $gp.TotalProcessorTime.TotalSeconds }
        $ramMb = [math]::Round($gp.WorkingSet64 / 1MB)
    } catch { }

    $ageH = 0.0
    try { $ageH = ($now - $cp.CreationDate).TotalHours } catch { }

    $cmdShort = $cmd
    if ($cmdShort.Length -gt 100) { $cmdShort = $cmdShort.Substring(0, 100) + "..." }

    $procs += [PSCustomObject]@{
        PID        = [int]$cp.ProcessId
        Type       = if ($isWorker) { "WORKER" } else { "TUI" }
        StartTime  = $cp.CreationDate
        StartedAt  = $cp.CreationDate.ToString("yyyy-MM-ddTHH:mm:ss")
        AgeH       = [math]::Round($ageH, 1)
        CpuSec     = [math]::Round($cpuSec)
        RamMB      = $ramMb
        CmdShort   = $cmdShort
        Verdict    = ""
    }
}

$newestPid = ($procs | Sort-Object StartTime -Descending | Select-Object -First 1).PID

foreach ($p in $procs) {
    if ($p.PID -eq $newestPid) { $p.Verdict = "NEWEST" }
    elseif ($p.PID -eq $selfPid) { $p.Verdict = "SELF" }
    elseif ($p.Type -eq "WORKER" -and $p.AgeH -gt $threshold) { $p.Verdict = "WORKER-STUCK" }
    elseif ($p.Type -eq "TUI" -and $p.AgeH -gt $threshold) { $p.Verdict = "STALE" }
    else { $p.Verdict = "OK" }
}

# --- Tablitsa ---
Write-Host "=== opencode TUI cleanup ===" -ForegroundColor Cyan
Write-Host ("Threshold: {0}h | Mode: {1} | Now: {2}" -f $threshold, $mode.ToUpper(), $now.ToString("yyyy-MM-dd HH:mm")) -ForegroundColor Gray
if ($selfPid -gt 0) {
    Write-Host ("Self-protected session PID: {0}" -f $selfPid) -ForegroundColor DarkGray
}
Write-Host ""

$procs = @($procs | Sort-Object StartTime)
Write-Host ("{0,-7} {1,-8} {2,9} {3,10} {4,7} {5,-14} {6}" -f "PID", "Type", "Age(h)", "CPU(s)", "RAM(MB)", "Verdict", "CommandLine") -ForegroundColor White
Write-Host ("-" * 118) -ForegroundColor DarkGray
foreach ($p in $procs) {
    $color = "Gray"
    if ($p.Verdict -in @("STALE", "WORKER-STUCK")) { $color = "Yellow" }
    if ($p.Verdict -in @("NEWEST", "SELF")) { $color = "Green" }
    Write-Host ("{0,-7} {1,-8} {2,9} {3,10} {4,7} {5,-14} {6}" -f $p.PID, $p.Type, $p.AgeH, $p.CpuSec, $p.RamMB, $p.Verdict, $p.CmdShort) -ForegroundColor $color
}
Write-Host ""

$staleCount = @($procs | Where-Object { $_.Verdict -in @("STALE", "WORKER-STUCK") }).Count

if ($mode -eq "list") {
    if ($staleCount -gt 0) {
        Write-Host ("run -KillStale to clean {0} stale processes" -f $staleCount) -ForegroundColor Yellow
    } else {
        Write-Host "No stale processes. All clean." -ForegroundColor Green
    }
    exit 0
}

# --- Vybor tseley ---
if ($mode -eq "killstale") {
    $targets = @($procs | Where-Object { $_.Verdict -in @("STALE", "WORKER-STUCK") })
} else {
    $targets = @($procs | Where-Object { $_.Verdict -notin @("NEWEST", "SELF") })
}

if ($targets.Count -eq 0) {
    Write-Host "Nothing to kill under current mode/threshold. All clean." -ForegroundColor Green
    exit 0
}

if ($script:WouldKill) {
    Write-Host "What if: WOULD KILL $($targets.Count) process(es):" -ForegroundColor Yellow
    foreach ($t in $targets) {
        Write-Host ("  PID {0} ({1}, age {2}h, verdict {3})" -f $t.PID, $t.Type, $t.AgeH, $t.Verdict) -ForegroundColor Yellow
    }
    Write-Host "What if: no processes were harmed." -ForegroundColor Yellow
    exit 0
}

if ($mode -eq "killall") {
    $list = ($targets | ForEach-Object { "PID $($_.PID) ($($_.Type), $($_.AgeH)h)" }) -join "; "
    Write-Warning "KillAll: budet ubito $($targets.Count) process(ov): $list"
    Write-Warning "Newest (PID $newestPid) i self (PID $selfPid) zashchishcheny."
    Start-Sleep -Seconds 3
}

$killed = 0
$failed = 0
foreach ($t in $targets) {
    $reason = if ($mode -eq "killall") { "killall (ne NEWEST/SELF)" } else { "$($t.Verdict.ToLower()) > $($threshold)h" }
    try {
        # FIX (code-review minor): PID-reuse race — re-verify chto process vse tot zhe
        # (get CreationDate do killeta; esli PID pereispolzovan novym processom — propuskaem)
        $recheck = Get-CimInstance Win32_Process -Filter "ProcessId=$($t.PID)" -ErrorAction SilentlyContinue
        if (-not $recheck -or $recheck.Name -ne "opencode.exe" -or $recheck.CreationDate.ToString("yyyy-MM-ddTHH:mm:ss") -ne $t.StartedAt) {
            $failed++
            Write-Warning ("PID $($t.PID) izmenilsya (PID-reuse) - propushchen. Novyj process ne trogat.")
            Write-LogLine ("{0} | SKIP-PIDREUSE | PID {1} | {2} | mode {3} | PID reused between scan and kill" -f `
                (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $t.PID, $t.Type, $mode)
            continue
        }
        Stop-Process -Id $t.PID -Force -ErrorAction Stop
        $killed++
        Write-Host ("KILLED PID {0} ({1}, age {2}h, {3} MB) - {4}" -f $t.PID, $t.Type, $t.AgeH, $t.RamMB, $reason) -ForegroundColor Red
        $ageInv = $t.AgeH.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        Write-LogLine ("{0} | KILL | PID {1} | {2} | age {3}h | RAM {4}MB | mode {5} | {6}" -f `
            (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $t.PID, $t.Type, $ageInv, $t.RamMB, $mode, $reason)
    } catch {
        $failed++
        Write-Warning ("Failed to kill PID $($t.PID): $($_.Exception.Message)")
        Write-LogLine ("{0} | FAIL | PID {1} | {2} | mode {3} | {4}" -f `
            (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $t.PID, $t.Type, $mode, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host ("Killed: {0} | Failed: {1} | Protected (NEWEST PID {2}, SELF PID {3})" -f $killed, $failed, $newestPid, $selfPid) -ForegroundColor Cyan
Write-Host "Log: $logPath" -ForegroundColor Gray

if ($failed -gt 0 -and $killed -eq 0) { exit 1 }
if ($killed -gt 0) { exit 2 }
exit 0
