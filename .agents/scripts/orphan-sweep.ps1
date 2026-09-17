# orphan-sweep.ps1 - report (default) or kill ORPHANED processes of THIS project.
# Safety: dry-run unless -Apply; targets only processes whose command line points at
# this repo root or at our temp launch dirs, whose parent is gone, and which are
# older than -OlderThanMinutes. Never kills by port / mask / range: only by PID,
# re-verified (name + start time) right before Stop-Process.
# Exit: 0 = clean / dry-run, 2 = killed >= 1, 1 = usage or enumeration error.
param(
    [switch]$Apply,
    [switch]$DryRun,
    [int]$OlderThanMinutes = 30,
    [string]$Root = '',
    [string[]]$ProcessNames = @('powershell', 'node', 'opencode', 'python')
)

$ErrorActionPreference = 'Continue'

function Get-OrphanRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($PSScriptRoot) { return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) }
    return (Get-Location).Path
}

function ConvertTo-OrphanKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim().ToLowerInvariant() -replace '/', '\')
}

function Get-OrphanMarkers {
    param([string]$RootValue)
    $markers = New-Object System.Collections.ArrayList
    $rootKey = ConvertTo-OrphanKey $RootValue
    if ($rootKey) { $null = $markers.Add($rootKey.TrimEnd('\')) }
    $tmp = ConvertTo-OrphanKey $env:TEMP
    if ($tmp) {
        $base = $tmp.TrimEnd('\')
        $null = $markers.Add($base + '\opencode')
        $null = $markers.Add($base + '\agent-hq')
    }
    return @($markers | Select-Object -Unique)
}

function Get-OrphanProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return ($Name.Trim().ToLowerInvariant() -replace '\.exe$', '')
}

function Test-OrphanMarkerMatch {
    param([string]$CommandLine, [string[]]$Markers)
    $cmd = ConvertTo-OrphanKey $CommandLine
    if (-not $cmd) { return $false }
    foreach ($m in @($Markers)) {
        if ((-not [string]::IsNullOrWhiteSpace($m)) -and $cmd.Contains($m)) { return $true }
    }
    return $false
}

function Get-OrphanProcessIndex {
    param([object[]]$Processes)
    $index = @{}
    foreach ($p in @($Processes)) {
        if ($null -eq $p) { continue }
        $procId = [int]$p.ProcessId
        if ($procId -le 0) { continue }
        if (-not $index.ContainsKey($procId)) { $index[$procId] = $p }
    }
    return $index
}

function Get-OrphanDescendantPids {
    param([object[]]$Processes, [int[]]$RootPids)
    $result = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object System.Collections.Queue
    foreach ($rp in @($RootPids)) {
        $rootId = [int]$rp
        if ($rootId -gt 0 -and $seen.Add($rootId)) { $queue.Enqueue($rootId) }
    }
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        foreach ($p in @($Processes)) {
            if ($null -eq $p) { continue }
            if ([int]$p.ParentProcessId -ne $cur) { continue }
            $childId = [int]$p.ProcessId
            if ($childId -le 0 -or $seen.Contains($childId)) { continue }
            $null = $seen.Add($childId)
            $null = $result.Add($childId)
            $queue.Enqueue($childId)
        }
    }
    return @($result)
}

# Active-job markers: *.lock / *.pid records that hold the PID of a live runner.
function Get-OrphanActiveJobPids {
    param([string]$RootValue)
    $found = New-Object System.Collections.ArrayList
    $dirs = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { $null = $dirs.Add((Join-Path $RootValue '.memory')) }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null = $dirs.Add((Join-Path $env:LOCALAPPDATA 'opencode\snapshot')) }
    foreach ($dir in @($dirs)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $files = @()
        try {
            # NOTE: -Include is ignored together with -LiteralPath in PS 5.1, so the
            # extension filter is explicit (otherwise every file in .memory matches).
            $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.lock' -or $_.Extension -eq '.pid' })
        } catch { $files = @() }
        foreach ($f in $files) {
            $raw = ''
            try { $raw = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
            $m = [regex]::Match($raw, '\d+')
            if (-not $m.Success) { continue }
            $value = 0
            if ([int]::TryParse($m.Value, [ref]$value) -and $value -gt 0) { $null = $found.Add($value) }
        }
    }
    return @($found | Select-Object -Unique)
}

# Orphan = no live parent. A parent PID that now belongs to a process started
# AFTER the child is PID reuse, i.e. the real parent is gone too.
function Test-OrphanParentDead {
    param([object]$Process, [hashtable]$Index)
    $parentId = [int]$Process.ParentProcessId
    if ($parentId -le 0) { return $true }
    if (-not $Index.ContainsKey($parentId)) { return $true }
    $parent = $Index[$parentId]
    $parentCreated = $null
    $childCreated = $null
    try { $parentCreated = [datetime]$parent.CreationDate } catch { $parentCreated = $null }
    try { $childCreated = [datetime]$Process.CreationDate } catch { $childCreated = $null }
    if (($null -ne $parentCreated) -and ($null -ne $childCreated) -and ($parentCreated -gt $childCreated)) { return $true }
    return $false
}

function Select-OrphanCandidate {
    param(
        [object[]]$Processes,
        [string]$RootValue,
        [string[]]$Names,
        [int]$OlderThanMinutes,
        [int[]]$ProtectedPids,
        [datetime]$Now
    )
    $wanted = @{}
    foreach ($n in @($Names)) {
        $key = Get-OrphanProcessName $n
        if ($key) { $wanted[$key] = $true }
    }
    $markers = Get-OrphanMarkers -RootValue $RootValue
    $index = Get-OrphanProcessIndex -Processes $Processes
    $protected = @{}
    foreach ($pp in @($ProtectedPids)) {
        $ppId = [int]$pp
        if ($ppId -gt 0) { $protected[$ppId] = $true }
    }

    $result = New-Object System.Collections.ArrayList
    foreach ($p in @($Processes)) {
        if ($null -eq $p) { continue }
        $procId = [int]$p.ProcessId
        if ($procId -le 0) { continue }
        if ($protected.ContainsKey($procId)) { continue }
        if (-not $wanted.ContainsKey((Get-OrphanProcessName ([string]$p.Name)))) { continue }
        if (-not (Test-OrphanMarkerMatch -CommandLine ([string]$p.CommandLine) -Markers $markers)) { continue }
        if (-not (Test-OrphanParentDead -Process $p -Index $index)) { continue }

        $created = $null
        try { $created = [datetime]$p.CreationDate } catch { $created = $null }
        if ($null -eq $created) { continue }
        $age = ($Now - $created).TotalMinutes
        if ($OlderThanMinutes -gt 0 -and $age -lt $OlderThanMinutes) { continue }

        $cmd = [string]$p.CommandLine
        if ($cmd.Length -gt 220) { $cmd = $cmd.Substring(0, 220) + '...' }
        $null = $result.Add([pscustomobject]@{
            PID         = $procId
            Name        = [string]$p.Name
            ParentPID   = [int]$p.ParentProcessId
            AgeMinutes  = [math]::Round($age, 1)
            CreatedISO  = $created.ToString('yyyy-MM-ddTHH:mm:ss')
            CommandLine = $cmd
        })
    }
    return @($result | Sort-Object AgeMinutes -Descending)
}

function Write-OrphanLog {
    param([string]$RootValue, [string]$Line)
    try {
        $dir = Join-Path $RootValue '.memory\traces'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText((Join-Path $dir 'orphan-sweep.log'), ("{0} {1}`r`n" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Line), $enc)
    } catch { }
}

if ($MyInvocation.InvocationName -ne '.') {

    $rootValue = Get-OrphanRoot -RootValue $Root

    if ($OlderThanMinutes -lt 0) {
        Write-Host ("orphan-sweep: -OlderThanMinutes must be >= 0 (got {0})" -f $OlderThanMinutes)
        exit 1
    }
    if ($Apply -and $DryRun) {
        Write-Host 'orphan-sweep: -Apply and -DryRun are mutually exclusive'
        exit 1
    }
    if ($Apply -and $OlderThanMinutes -lt 1) {
        Write-Host 'orphan-sweep: -Apply requires -OlderThanMinutes >= 1 (safety guard)'
        exit 1
    }

    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        Write-Host ('orphan-sweep: cannot enumerate processes (WMI/CIM): ' + $_.Exception.Message)
        exit 1
    }

    $index = Get-OrphanProcessIndex -Processes $all

    # Protect the current process, its ancestors (active launching chain) and all
    # of their descendants (the running job tree), plus every recorded live job PID.
    $protected = New-Object System.Collections.ArrayList
    $null = $protected.Add([int]$PID)
    $cursor = [int]$PID
    for ($i = 0; $i -lt 16; $i++) {
        if ($cursor -le 0 -or -not $index.ContainsKey($cursor)) { break }
        $cursor = [int]$index[$cursor].ParentProcessId
        if ($cursor -gt 0) { $null = $protected.Add($cursor) }
    }
    foreach ($d in @(Get-OrphanDescendantPids -Processes $all -RootPids @([int]$PID))) { $null = $protected.Add([int]$d) }

    $jobPidsFound = @(Get-OrphanActiveJobPids -RootValue $rootValue)
    $jobPids = @($jobPidsFound | Where-Object { $index.ContainsKey([int]$_) })
    foreach ($jp in $jobPids) {
        $null = $protected.Add([int]$jp)
        foreach ($d in @(Get-OrphanDescendantPids -Processes $all -RootPids @([int]$jp))) { $null = $protected.Add([int]$d) }
    }

    $now = Get-Date
    $candidates = @(Select-OrphanCandidate -Processes $all -RootValue $rootValue -Names $ProcessNames -OlderThanMinutes $OlderThanMinutes -ProtectedPids @($protected) -Now $now)
    $markedAnyAge = @(Select-OrphanCandidate -Processes $all -RootValue $rootValue -Names $ProcessNames -OlderThanMinutes 0 -ProtectedPids @($protected) -Now $now)
    $tooYoung = $markedAnyAge.Count - $candidates.Count

    $mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
    Write-Host '=== orphan-sweep ==='
    Write-Host ("root    : {0}" -f $rootValue)
    Write-Host ("markers : {0}" -f ((Get-OrphanMarkers -RootValue $rootValue) -join ' | '))
    Write-Host ("names   : {0}" -f (($ProcessNames | ForEach-Object { Get-OrphanProcessName $_ }) -join ', '))
    Write-Host ("mode    : {0} | older than {1} min | protected PIDs: {2} | live job PIDs: {3}" -f $mode, $OlderThanMinutes, $protected.Count, $jobPids.Count)

    if ($candidates.Count -eq 0) {
        Write-Host 'no orphaned project processes found.'
        if ($tooYoung -gt 0) { Write-Host ("({0} matching process(es) skipped: younger than the threshold)" -f $tooYoung) }
        exit 0
    }

    Write-Host ''
    Write-Host ("{0,-8} {1,-12} {2,-10} {3,10} {4,-21} {5}" -f 'PID', 'Name', 'ParentPID', 'Age(min)', 'Created', 'CommandLine')
    Write-Host ('-' * 110)
    foreach ($c in $candidates) {
        Write-Host ("{0,-8} {1,-12} {2,-10} {3,10} {4,-21} {5}" -f $c.PID, $c.Name, $c.ParentPID, $c.AgeMinutes, $c.CreatedISO, $c.CommandLine)
    }
    Write-Host ''
    Write-Host ("candidates: {0} (dry-run: nothing is killed)" -f $candidates.Count)

    if (-not $Apply) {
        Write-Host 'run with -Apply to kill exactly these PIDs (re-verified before kill).'
        exit 0
    }

    $killed = 0
    $failed = 0
    $skipped = 0
    foreach ($c in $candidates) {
        try {
            $recheck = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.PID) -ErrorAction SilentlyContinue
            if (-not $recheck) {
                $skipped++
                Write-Host ("  skip PID {0}: process is already gone" -f $c.PID)
                continue
            }
            $startIso = ''
            try { $startIso = ([datetime]$recheck.CreationDate).ToString('yyyy-MM-ddTHH:mm:ss') } catch { $startIso = '' }
            $sameName = ((Get-OrphanProcessName ([string]$recheck.Name)) -eq (Get-OrphanProcessName ([string]$c.Name)))
            if ((-not $sameName) -or ($startIso -ne $c.CreatedISO)) {
                $skipped++
                Write-Host ("  skip PID {0}: identity changed (PID reuse) - not touched" -f $c.PID)
                Write-OrphanLog -RootValue $rootValue -Line ("SKIP-PIDREUSE PID {0} name={1}" -f $c.PID, $c.Name)
                continue
            }
            Stop-Process -Id $c.PID -Force -ErrorAction Stop
            $killed++
            Write-Host ("  killed PID {0} ({1}, age {2} min, parent {3} is gone)" -f $c.PID, $c.Name, $c.AgeMinutes, $c.ParentPID)
            Write-OrphanLog -RootValue $rootValue -Line ("KILL PID {0} name={1} age={2}min parent={3}" -f $c.PID, $c.Name, $c.AgeMinutes, $c.ParentPID)
        } catch {
            $failed++
            Write-Host ("  failed PID {0}: {1}" -f $c.PID, $_.Exception.Message)
            Write-OrphanLog -RootValue $rootValue -Line ("FAIL PID {0} name={1} error={2}" -f $c.PID, $c.Name, $_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host ("killed: {0} | failed: {1} | skipped: {2}" -f $killed, $failed, $skipped)
    if ($failed -gt 0 -and $killed -eq 0) { exit 1 }
    if ($killed -gt 0) { exit 2 }
    exit 0
}
