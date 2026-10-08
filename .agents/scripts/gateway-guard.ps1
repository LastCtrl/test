# gateway-guard.ps1 - watchdog for the local model gateway (127.0.0.1:8899).
# Modes: default = ensure up (start run-gateway-hidden.vbs iff the port is closed);
#         -Check = read-only status probe only.
# Kill-switch: env AGENT_HQ_GATEWAY_GUARD_DISABLE=1 -> no action.
# Exit: -Check: 0 up, 2 down; default: 0 ok, 1 start failed.
param(
    [switch]$Check,
    [string]$HostAddress = '127.0.0.1',
    [int]$Port = 8899,
    [int]$ProbeTimeoutMs = 2000,
    [string]$Root = '',
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'

function Get-GatewayRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($PSScriptRoot) { return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) }
    return (Get-Location).Path
}

function Write-GatewayLog {
    param([string]$Path, [string]$Line)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, ("{0} {1}`r`n" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Line), $enc)
    } catch { }
}

function Test-GatewayPort {
    param([string]$TargetHost = '127.0.0.1', [int]$TargetPort = 8899, [int]$TimeoutMs = 2000)
    if ($TargetPort -lt 1 -or $TargetPort -gt 65535) { return $false }
    if ([string]::IsNullOrWhiteSpace($TargetHost)) { $TargetHost = '127.0.0.1' }
    if ($TimeoutMs -lt 100) { $TimeoutMs = 100 }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

if ($MyInvocation.InvocationName -ne '.') {

    if ($env:AGENT_HQ_GATEWAY_GUARD_DISABLE -eq '1') {
        Write-Host 'gateway-guard: disabled (AGENT_HQ_GATEWAY_GUARD_DISABLE=1)'
        exit 0
    }

    $rootValue = Get-GatewayRoot -RootValue $Root
    if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Join-Path $rootValue '.memory\gateway-guard.log' }
    $endpoint = '{0}:{1}' -f $HostAddress, $Port

    $up = Test-GatewayPort -TargetHost $HostAddress -TargetPort $Port -TimeoutMs $ProbeTimeoutMs

    if ($Check) {
        if ($up) {
            Write-Host ('gateway-guard: {0} up' -f $endpoint)
            exit 0
        }
        Write-Host ('gateway-guard: {0} down' -f $endpoint)
        exit 2
    }

    if ($up) { exit 0 }

    Write-GatewayLog -Path $LogFile -Line ('DOWN {0} - starting gateway' -f $endpoint)

    $launcher = Join-Path $PSScriptRoot 'run-gateway-hidden.vbs'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-Host ('gateway-guard: launcher missing: {0}' -f $launcher)
        Write-GatewayLog -Path $LogFile -Line ('START-FAIL missing {0}' -f $launcher)
        exit 1
    }

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $wscript -PathType Leaf)) { $wscript = 'wscript.exe' }

    try {
        Start-Process -FilePath $wscript -ArgumentList '//B', ('"' + $launcher + '"') -WindowStyle Hidden -ErrorAction Stop | Out-Null
        Write-Host ('gateway-guard: launched gateway (port {0} was down)' -f $endpoint)
        Write-GatewayLog -Path $LogFile -Line ('START ok {0}' -f $endpoint)
        exit 0
    } catch {
        Write-Host ('gateway-guard: start failed: {0}' -f $_.Exception.Message)
        Write-GatewayLog -Path $LogFile -Line ('START-FAIL {0} error={1}' -f $endpoint, $_.Exception.Message)
        exit 1
    }
}
