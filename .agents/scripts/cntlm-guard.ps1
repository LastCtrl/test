# cntlm-guard.ps1 - watchdog for the local cntlm proxy (127.0.0.1:3128).
# Modes: -Check (default, read-only) | -Restart (real heal; -DryRun simulates only).
# Safety: heals ONLY an owned cntlm (name + exe path under -AllowedDir); stop by PID
# after identity re-check; restart budget + circuit breaker; -DryRun never acts.
# Exit: 0 ok, 2 proxy down, 3 breaker open, 4 restart failed, 5 no owned process, 1 usage.
param(
    [switch]$Check,
    [switch]$Restart,
    [switch]$DryRun,
    [string]$ProxyHost = '127.0.0.1',
    [int]$ProxyPort = 3128,
    [int]$ProbeTimeoutMs = 1500,
    [string]$AllowedDir = 'C:\tools\cntlm',
    [string]$ExeName = 'cntlm.exe',
    [string]$ConfigPath = 'C:\tools\cntlm\cntlm.ini',
    [int]$MaxRestarts = 3,
    [int]$WindowMinutes = 60,
    [int]$StartWaitSeconds = 10,
    [string]$Root = '',
    [string]$LogFile = '',
    [string]$StateFile = ''
)

$ErrorActionPreference = 'Continue'

function Get-CntlmRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($PSScriptRoot) { return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) }
    return (Get-Location).Path
}

function Write-CntlmLog {
    param([string]$Path, [string]$Line)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, ("{0} {1}`r`n" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Line), $enc)
    } catch { }
}

function Test-CntlmPort {
    param([string]$TargetHost = '127.0.0.1', [int]$Port = 3128, [int]$TimeoutMs = 1500)
    if ($Port -lt 1 -or $Port -gt 65535) { return $false }
    if ([string]::IsNullOrWhiteSpace($TargetHost)) { $TargetHost = '127.0.0.1' }
    if ($TimeoutMs -lt 100) { $TimeoutMs = 100 }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

function ConvertTo-CntlmPathKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant())
}

function Test-CntlmName {
    param([string]$Name, [string]$ExeName = 'cntlm.exe')
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $n = ($Name.Trim().ToLowerInvariant() -replace '\.exe$', '')
    $e = ([string]$ExeName).Trim().ToLowerInvariant() -replace '\.exe$', ''
    if ([string]::IsNullOrWhiteSpace($e)) { $e = 'cntlm' }
    return ($n -eq $e)
}

function Test-CntlmOwnedProcess {
    param([object]$Process, [string]$AllowedDir, [string]$ExeName = 'cntlm.exe')
    if ($null -eq $Process) { return $false }
    if (-not (Test-CntlmName -Name ([string]$Process.Name) -ExeName $ExeName)) { return $false }
    $dirKey = ConvertTo-CntlmPathKey $AllowedDir
    if ([string]::IsNullOrWhiteSpace($dirKey)) { return $false }
    $exeKey = ConvertTo-CntlmPathKey ([string]$Process.ExecutablePath)
    if ([string]::IsNullOrWhiteSpace($exeKey)) { return $false }
    return $exeKey.StartsWith($dirKey + '\')
}

function Get-CntlmProcessList {
    param([object[]]$Processes, [string]$AllowedDir, [string]$ExeName = 'cntlm.exe')
    $result = New-Object System.Collections.ArrayList
    foreach ($p in @($Processes)) {
        if ($null -eq $p) { continue }
        if (-not (Test-CntlmOwnedProcess -Process $p -AllowedDir $AllowedDir -ExeName $ExeName)) { continue }
        $cmd = [string]$p.CommandLine
        if ($cmd.Length -gt 200) { $cmd = $cmd.Substring(0, 200) }
        $null = $result.Add([pscustomobject]@{
            PID         = [int]$p.ProcessId
            Name        = [string]$p.Name
            ExePath     = [string]$p.ExecutablePath
            CommandLine = $cmd
        })
    }
    return @($result)
}

function Get-CntlmRestartTimes {
    param([string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($StatePath)) { return @() }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return @() }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($StatePath) } catch { return @() }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if ($null -eq $obj -or $null -eq $obj.restarts) { return @() }
    $result = New-Object System.Collections.ArrayList
    foreach ($t in @($obj.restarts)) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$t, [ref]$dt)) { $null = $result.Add($dt) }
    }
    return @($result)
}

function Get-CntlmWindowCount {
    param([datetime[]]$Times, [int]$WindowMinutes = 60, [datetime]$Now)
    if ($WindowMinutes -lt 0) { $WindowMinutes = 0 }
    $cut = $Now.AddMinutes(-1.0 * $WindowMinutes)
    $n = 0
    foreach ($t in @($Times)) {
        if ($t -ge $cut -and $t -le $Now) { $n++ }
    }
    return $n
}

function Test-CntlmBreakerOpen {
    param([int]$Count, [int]$MaxRestarts = 3)
    if ($MaxRestarts -lt 0) { $MaxRestarts = 0 }
    return [bool]($Count -ge $MaxRestarts)
}

function Add-CntlmRestartTime {
    param([string]$StatePath, [datetime]$At, [int]$Keep = 100)
    if ([string]::IsNullOrWhiteSpace($StatePath)) { return $false }
    $list = New-Object System.Collections.ArrayList
    foreach ($t in @(Get-CntlmRestartTimes -StatePath $StatePath)) { $null = $list.Add($t) }
    $null = $list.Add($At)
    while ($list.Count -gt $Keep) { $list.RemoveAt(0) }
    $iso = New-Object System.Collections.ArrayList
    foreach ($t in @($list)) { $null = $iso.Add(([datetime]$t).ToString('o')) }
    $obj = [pscustomobject]@{ restarts = @($iso); updated = (Get-Date).ToString('o') }
    try {
        $dir = Split-Path -Parent $StatePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        [System.IO.File]::WriteAllText($StatePath, ($obj | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        return $false
    }
}

if ($MyInvocation.InvocationName -ne '.') {

    if ($Check -and $Restart) {
        Write-Host 'cntlm-guard: -Check and -Restart are mutually exclusive'
        exit 1
    }
    if ($DryRun -and -not $Restart) {
        Write-Host 'cntlm-guard: -DryRun applies to -Restart; -Check is read-only anyway'
    }

    $rootValue = Get-CntlmRoot -RootValue $Root
    if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Join-Path $rootValue '.memory\cntlm-guard.log' }
    if ([string]::IsNullOrWhiteSpace($StateFile)) { $StateFile = Join-Path $rootValue '.memory\cntlm-guard.state.json' }

    # Proxy mode (default off): when off, cntlm is not required and its absence
    # is healthy, so the guard must not report a fault nor restart anything.
    $proxyMode = 'on'
    $proxyModePath = Join-Path $PSScriptRoot 'proxy-mode.ps1'
    if (Test-Path -LiteralPath $proxyModePath -PathType Leaf) {
        try {
            . $proxyModePath
            $proxyMode = (Read-ProxyConfig -Root $rootValue).mode
        } catch { $proxyMode = 'on' }
    }

    $mode = if ($Restart) { 'restart' } else { 'check' }
    Write-Host '=== cntlm-guard ==='
    Write-Host ("mode    : {0}{1}" -f $mode, $(if ($DryRun) { ' (dry-run)' } else { '' }))
    Write-Host ("proxy   : {0}:{1}" -f $ProxyHost, $ProxyPort)
    Write-Host ("owned   : {0}" -f $AllowedDir)

    $up = Test-CntlmPort -TargetHost $ProxyHost -Port $ProxyPort -TimeoutMs $ProbeTimeoutMs
    Write-Host ("probe   : {0}" -f $(if ($up) { 'UP' } else { 'DOWN' }))

    if ($mode -eq 'check') {
        if ($up) {
            Write-Host 'STATUS: ok'
            Write-CntlmLog -Path $LogFile -Line ("CHECK ok host={0} port={1}" -f $ProxyHost, $ProxyPort)
            exit 0
        }
        if ($proxyMode -eq 'off') {
            Write-Host 'proxy mode is off - cntlm is not required.'
            Write-Host 'STATUS: ok'
            Write-CntlmLog -Path $LogFile -Line 'CHECK ok (mode=off, proxy not required)'
            exit 0
        }
        Write-Host 'STATUS: down'
        Write-CntlmLog -Path $LogFile -Line ("CHECK down host={0} port={1}" -f $ProxyHost, $ProxyPort)
        exit 2
    }

    if ($proxyMode -eq 'off') {
        Write-Host 'proxy mode is off - nothing to restart.'
        Write-Host 'STATUS: ok'
        Write-CntlmLog -Path $LogFile -Line 'RESTART skipped (mode=off)'
        exit 0
    }

    if ($up) {
        Write-Host 'proxy is UP - nothing to restart.'
        Write-Host 'STATUS: ok'
        Write-CntlmLog -Path $LogFile -Line 'RESTART skipped (proxy up)'
        exit 0
    }

    $all = @()
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        Write-Host ('cntlm-guard: cannot enumerate processes: ' + $_.Exception.Message)
        exit 1
    }
    $owned = @(Get-CntlmProcessList -Processes $all -AllowedDir $AllowedDir -ExeName $ExeName)

    $times = @(Get-CntlmRestartTimes -StatePath $StateFile)
    $windowCount = Get-CntlmWindowCount -Times $times -WindowMinutes $WindowMinutes -Now (Get-Date)
    $breaker = Test-CntlmBreakerOpen -Count $windowCount -MaxRestarts $MaxRestarts
    Write-Host ("budget  : {0}/{1} restart(s) in last {2} min" -f $windowCount, $MaxRestarts, $WindowMinutes)

    if ($breaker) {
        Write-Host ("circuit breaker OPEN: {0} >= {1} restart(s) in {2} min window - refusing to act." -f $windowCount, $MaxRestarts, $WindowMinutes)
        Write-Host 'STATUS: breaker-open'
        Write-CntlmLog -Path $LogFile -Line ("BREAKER open count={0} max={1}" -f $windowCount, $MaxRestarts)
        exit 3
    }

    if ($owned.Count -eq 0) {
        Write-Host ("no owned cntlm process under '{0}' - nothing to restart (no foreign process touched)." -f $AllowedDir)
        Write-Host 'STATUS: no-process'
        Write-CntlmLog -Path $LogFile -Line ("NO-PROCESS allowed={0}" -f $AllowedDir)
        exit 5
    }

    Write-Host ("owned   : {0} process(es) -> {1}" -f $owned.Count, (($owned | ForEach-Object { $_.PID }) -join ', '))

    if ($DryRun) {
        foreach ($p in $owned) {
            Write-Host ("DRY-RUN: would stop PID {0} ({1})" -f $p.PID, $p.ExePath)
        }
        Write-Host ("DRY-RUN: would start '{0}' -c '{1}'" -f (Join-Path $AllowedDir $ExeName), $ConfigPath)
        Write-Host ("DRY-RUN: would consume 1/{0} restart(s) in the {1} min window" -f $MaxRestarts, $WindowMinutes)
        Write-Host 'DRY-RUN: nothing was stopped or started.'
        Write-Host 'STATUS: dry-run'
        Write-CntlmLog -Path $LogFile -Line ("DRY-RUN plan stop={0} start={1}" -f (($owned | ForEach-Object { $_.PID }) -join ','), $ExeName)
        exit 0
    }

    # real restart path: re-verify identity right before stop, then start with -c config.
    $stopped = 0
    foreach ($p in $owned) {
        try {
            $recheck = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.PID) -ErrorAction SilentlyContinue
            if (-not $recheck) { continue }
            if (-not (Test-CntlmOwnedProcess -Process $recheck -AllowedDir $AllowedDir -ExeName $ExeName)) {
                Write-Host ("  skip PID {0}: identity changed (not owned) - not touched" -f $p.PID)
                continue
            }
            Stop-Process -Id $p.PID -Force -ErrorAction Stop
            $stopped++
            Write-Host ("  stopped PID {0}" -f $p.PID)
            Write-CntlmLog -Path $LogFile -Line ("STOP PID {0}" -f $p.PID)
        } catch {
            Write-Host ("  failed to stop PID {0}: {1}" -f $p.PID, $_.Exception.Message)
            Write-CntlmLog -Path $LogFile -Line ("STOP-FAIL PID {0} error={1}" -f $p.PID, $_.Exception.Message)
        }
    }
    if ($stopped -eq 0) {
        Write-Host 'no owned process could be stopped.'
        Write-Host 'STATUS: no-process'
        exit 5
    }

    Start-Sleep -Milliseconds 800
    $exePath = Join-Path $AllowedDir $ExeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Write-Host ("cntlm executable not found: {0}" -f $exePath)
        Write-Host 'STATUS: restart-failed'
        Write-CntlmLog -Path $LogFile -Line ("START-FAIL missing-exe {0}" -f $exePath)
        exit 4
    }
    $argList = @('-c')
    if ($ConfigPath -match '\s') { $argList += ('"' + $ConfigPath + '"') } else { $argList += $ConfigPath }
    try {
        Start-Process -FilePath $exePath -ArgumentList $argList -WorkingDirectory $AllowedDir -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ('failed to start cntlm: ' + $_.Exception.Message)
        Write-Host 'STATUS: restart-failed'
        Write-CntlmLog -Path $LogFile -Line ("START-FAIL error={0}" -f $_.Exception.Message)
        exit 4
    }
    $null = Add-CntlmRestartTime -StatePath $StateFile -At (Get-Date)

    $deadline = (Get-Date).AddSeconds($StartWaitSeconds)
    $restored = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-CntlmPort -TargetHost $ProxyHost -Port $ProxyPort -TimeoutMs $ProbeTimeoutMs) { $restored = $true; break }
    }
    if ($restored) {
        Write-Host 'STATUS: restart-ok'
        Write-CntlmLog -Path $LogFile -Line ('RESTART ok stopped={0}' -f $stopped)
        exit 0
    }
    Write-Host 'STATUS: restart-failed'
    Write-CntlmLog -Path $LogFile -Line ('RESTART failed stopped={0}' -f $stopped)
    exit 4
}
