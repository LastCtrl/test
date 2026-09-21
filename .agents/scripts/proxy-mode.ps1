# proxy-mode.ps1 - quick switch for the corporate cntlm proxy (default off).
# Modes: -Status (default) | -On | -Off | -Auto | -Json | -Persist | -Root <path>.
# Writes .agents/config/proxy.json and the CURRENT process env; HKCU only with -Persist.

$script:ProxyDefaultUrl = 'http://127.0.0.1:3128'
$script:ProxyDefaultNoProxy = 'localhost,127.0.0.1,10.*,192.168.*,*.minsk.energo.net'
$script:ProxyModeScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Get-ProxyRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    return (Split-Path (Split-Path $script:ProxyModeScriptDir -Parent) -Parent)
}

function Get-ProxyConfigPath {
    param([string]$Root)
    return (Join-Path (Get-ProxyRoot -Root $Root) '.agents\config\proxy.json')
}

function Get-DefaultProxyConfig {
    return [pscustomobject]@{ mode = 'off'; url = $script:ProxyDefaultUrl; no_proxy = $script:ProxyDefaultNoProxy; error = '' }
}

function Read-ProxyConfig {
    param([string]$Root)
    $path = Get-ProxyConfigPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (Get-DefaultProxyConfig) }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch {
        $failed = Get-DefaultProxyConfig
        $failed.error = 'read failed'
        return $failed
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $empty = Get-DefaultProxyConfig
        $empty.error = 'empty config'
        return $empty
    }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch {
        $broken = Get-DefaultProxyConfig
        $broken.error = 'invalid JSON'
        return $broken
    }
    if ($null -eq $doc) {
        $nullDoc = Get-DefaultProxyConfig
        $nullDoc.error = 'invalid JSON'
        return $nullDoc
    }
    $mode = 'off'
    if ($null -ne $doc.mode) { $mode = ([string]$doc.mode).Trim().ToLowerInvariant() }
    if ($mode -ne 'on') { $mode = 'off' }
    $url = $script:ProxyDefaultUrl
    if (($null -ne $doc.url) -and (-not [string]::IsNullOrWhiteSpace([string]$doc.url))) { $url = ([string]$doc.url).Trim() }
    $noProxy = $script:ProxyDefaultNoProxy
    if (($null -ne $doc.no_proxy) -and (-not [string]::IsNullOrWhiteSpace([string]$doc.no_proxy))) { $noProxy = ([string]$doc.no_proxy).Trim() }
    return [pscustomobject]@{ mode = $mode; url = $url; no_proxy = $noProxy; error = '' }
}

function Save-ProxyConfig {
    param([string]$Mode, [string]$Url, [string]$NoProxy, [string]$Root)
    if ($Mode -ne 'on') { $Mode = 'off' }
    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = $script:ProxyDefaultUrl }
    if ([string]::IsNullOrWhiteSpace($NoProxy)) { $NoProxy = $script:ProxyDefaultNoProxy }
    $path = Get-ProxyConfigPath -Root $Root
    $dir = Split-Path -Parent $path
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $obj = [ordered]@{ mode = $Mode; url = $Url; no_proxy = $NoProxy }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        return $false
    }
}

function Test-ProxyPort {
    param([string]$HostName = '127.0.0.1', [int]$Port = 3128, [int]$TimeoutMs = 1000)
    if ($Port -lt 1 -or $Port -gt 65535) { return $false }
    if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = '127.0.0.1' }
    if ($TimeoutMs -lt 100) { $TimeoutMs = 100 }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

function Get-ProxyEndpoint {
    param([string]$Url)
    $hostName = '127.0.0.1'
    $port = 3128
    if ([string]::IsNullOrWhiteSpace($Url)) { return [pscustomobject]@{ host = $hostName; port = $port } }
    try {
        $uri = [System.Uri]$Url
        if (-not [string]::IsNullOrWhiteSpace($uri.Host)) { $hostName = $uri.Host }
        if ($uri.Port -gt 0) { $port = $uri.Port }
    } catch { }
    return [pscustomobject]@{ host = $hostName; port = $port }
}

function Set-ProxyProcessEnv {
    param([pscustomobject]$Config)
    if ($Config.mode -eq 'on') {
        $env:HTTP_PROXY = $Config.url
        $env:HTTPS_PROXY = $Config.url
        $env:NO_PROXY = $Config.no_proxy
        $env:AGENT_HQ_PROXY_MODE = 'on'
    } else {
        Remove-Item Env:\HTTP_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:\HTTPS_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:\NO_PROXY -ErrorAction SilentlyContinue
        $env:AGENT_HQ_PROXY_MODE = 'off'
    }
}

function Set-ProxyPersist {
    param([string]$Mode, [pscustomobject]$Config)
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
        if ($Mode -eq 'on') {
            $value = $Config.url
            if ($name -eq 'NO_PROXY') { $value = $Config.no_proxy }
            [Environment]::SetEnvironmentVariable($name, $value, 'User')
        } else {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
        }
    }
    [Environment]::SetEnvironmentVariable('AGENT_HQ_PROXY_MODE', $Mode, 'User')
}

function Get-ProxyArgs {
    param([string]$Root)
    $config = Read-ProxyConfig -Root $Root
    if ($config.mode -eq 'on') { return @('-x', $config.url) }
    return @()
}

function Get-ProxyEnvDelta {
    param([string]$Root)
    $config = Read-ProxyConfig -Root $Root
    $delta = [ordered]@{}
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
        $value = $null
        if ($config.mode -eq 'on') {
            if ($name -eq 'NO_PROXY') { $value = $config.no_proxy } else { $value = $config.url }
        }
        $delta[$name] = $value
    }
    $delta['AGENT_HQ_PROXY_MODE'] = $config.mode
    return $delta
}

function Initialize-ProxyEnvironment {
    param([string]$Root)
    $config = Read-ProxyConfig -Root $Root
    Set-ProxyProcessEnv -Config $config
    return $config
}

function Get-ProxyStatus {
    param([string]$Root)
    $config = Read-ProxyConfig -Root $Root
    $endpoint = Get-ProxyEndpoint -Url $config.url
    $open = Test-ProxyPort -HostName $endpoint.host -Port $endpoint.port
    $envView = [ordered]@{
        HTTP_PROXY = [string]$env:HTTP_PROXY
        HTTPS_PROXY = [string]$env:HTTPS_PROXY
        NO_PROXY = [string]$env:NO_PROXY
        AGENT_HQ_PROXY_MODE = [string]$env:AGENT_HQ_PROXY_MODE
    }
    return [ordered]@{
        mode = $config.mode
        url = $config.url
        no_proxy = $config.no_proxy
        config_path = Get-ProxyConfigPath -Root $Root
        config_error = $config.error
        host = $endpoint.host
        port = $endpoint.port
        port_open = [bool]$open
        env = $envView
    }
}

function Apply-ProxySelection {
    param([string]$Mode, [string]$Root, [bool]$Persist)
    $config = Read-ProxyConfig -Root $Root
    $resolved = if ($Mode -eq 'on') { 'on' } else { 'off' }
    $newConfig = [pscustomobject]@{ mode = $resolved; url = $config.url; no_proxy = $config.no_proxy; error = '' }
    [void](Save-ProxyConfig -Mode $resolved -Url $newConfig.url -NoProxy $newConfig.no_proxy -Root $Root)
    Set-ProxyProcessEnv -Config $newConfig
    if ($Persist) { Set-ProxyPersist -Mode $resolved -Config $newConfig }
    return $newConfig
}

function Invoke-ProxyModeCli {
    param([object[]]$Arguments)
    $on = $false
    $off = $false
    $auto = $false
    $json = $false
    $persist = $false
    $root = ''
    if ($null -eq $Arguments) { $Arguments = @() }
    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        if ($token -eq '-On') { $on = $true; $index++ }
        elseif ($token -eq '-Off') { $off = $true; $index++ }
        elseif ($token -eq '-Auto') { $auto = $true; $index++ }
        elseif ($token -eq '-Json') { $json = $true; $index++ }
        elseif ($token -eq '-Persist') { $persist = $true; $index++ }
        elseif ($token -eq '-Status') { $index++ }
        elseif ($token -eq '-Root') {
            if (($index + 1) -ge $Arguments.Count) { Write-Host 'proxy-mode: -Root needs a value'; exit 1 }
            $root = [string]$Arguments[$index + 1]
            $index += 2
        }
        else {
            Write-Host ("proxy-mode: unknown argument '" + $token + "'")
            Write-Host 'usage: proxy-mode.ps1 [-Status] [-On] [-Off] [-Auto] [-Json] [-Persist] [-Root <path>]'
            exit 1
        }
    }

    $chosen = @()
    if ($on) { $chosen += 'on' }
    if ($off) { $chosen += 'off' }
    if ($auto) { $chosen += 'auto' }
    if ($chosen.Count -gt 1) { Write-Host 'proxy-mode: -On/-Off/-Auto are mutually exclusive'; exit 1 }

    if ($on) { [void](Apply-ProxySelection -Mode 'on' -Root $root -Persist $persist) }
    elseif ($off) { [void](Apply-ProxySelection -Mode 'off' -Root $root -Persist $persist) }
    elseif ($auto) {
        $config = Read-ProxyConfig -Root $root
        $endpoint = Get-ProxyEndpoint -Url $config.url
        $open = Test-ProxyPort -HostName $endpoint.host -Port $endpoint.port
        $autoMode = if ($open) { 'on' } else { 'off' }
        [void](Apply-ProxySelection -Mode $autoMode -Root $root -Persist $persist)
    }

    if ($json) {
        Write-Output (ConvertTo-Json -InputObject (Get-ProxyStatus -Root $root) -Depth 5)
        exit 0
    }

    $status = Get-ProxyStatus -Root $root
    Write-Host '=== proxy-mode ==='
    Write-Host ("mode     : {0}" -f $status.mode)
    Write-Host ("url      : {0}" -f $status.url)
    Write-Host ("no_proxy : {0}" -f $status.no_proxy)
    $note = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$status.config_error)) { $note = ' (' + $status.config_error + ')' }
    Write-Host ("config   : {0}{1}" -f $status.config_path, $note)
    Write-Host ("port     : {0}:{1} {2}" -f $status.host, $status.port, $(if ($status.port_open) { 'UP' } else { 'DOWN' }))
    Write-Host ("env      : HTTP_PROXY={0}; HTTPS_PROXY={1}; NO_PROXY={2}; AGENT_HQ_PROXY_MODE={3}" -f $status.env.HTTP_PROXY, $status.env.HTTPS_PROXY, $status.env.NO_PROXY, $status.env.AGENT_HQ_PROXY_MODE)
    Write-Host ("STATUS   : {0}" -f $status.mode)
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ProxyModeCli -Arguments $args
}
