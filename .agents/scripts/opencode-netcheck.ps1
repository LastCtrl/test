# opencode-netcheck.ps1 - read-only diagnostics for opencode access through a local cntlm proxy.
# Exit: 0 ok, 2 proxy down, 3 network via proxy failed, 4 geo-block, 5 opencode missing, 1 usage.
param(
    [string]$ProviderUrl = 'https://api.openai.com/v1/models',
    [string]$ProxyHost = '127.0.0.1',
    [int]$ProxyPort = 3128,
    [string]$CntlmDir = 'C:\tools\cntlm',
    [int]$TimeoutSec = 15,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

function ConvertTo-NetcheckPathKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant())
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

function Test-CntlmOwnedProcess {
    param([object]$Process, [string]$AllowedDir, [string]$ExeName = 'cntlm.exe')
    if ($null -eq $Process) { return $false }
    $name = ([string]$Process.Name).Trim().ToLowerInvariant() -replace '\.exe$', ''
    $exe = ([string]$ExeName).Trim().ToLowerInvariant() -replace '\.exe$', ''
    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'cntlm' }
    if ($name -ne $exe) { return $false }
    $dirKey = ConvertTo-NetcheckPathKey $AllowedDir
    if ([string]::IsNullOrWhiteSpace($dirKey)) { return $false }
    $exeKey = ConvertTo-NetcheckPathKey ([string]$Process.ExecutablePath)
    if ([string]::IsNullOrWhiteSpace($exeKey)) { return $false }
    return $exeKey.StartsWith($dirKey + '\')
}

function Get-NetcheckOwnedProcesses {
    param([string]$AllowedDir, [string]$ExeName = 'cntlm.exe')
    $result = New-Object System.Collections.ArrayList
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        return @($result)
    }
    foreach ($p in $all) {
        if (-not (Test-CntlmOwnedProcess -Process $p -AllowedDir $AllowedDir -ExeName $ExeName)) { continue }
        $null = $result.Add([pscustomobject]@{
            pid      = [int]$p.ProcessId
            name     = [string]$p.Name
            exe_path = [string]$p.ExecutablePath
        })
    }
    return @($result)
}

function Get-NetcheckCrashDumps {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return @() }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    try {
        $items = @(Get-ChildItem -LiteralPath $Dir -Filter '*.stackdump' -File -ErrorAction Stop)
    } catch {
        return @()
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($i in $items) { $null = $out.Add([string]$i.FullName) }
    return @($out)
}

function Get-NetcheckEnv {
    $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')
    $proc = [ordered]@{}
    $user = [ordered]@{}
    $mismatch = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $p = [Environment]::GetEnvironmentVariable($n, 'Process')
        $u = [Environment]::GetEnvironmentVariable($n, 'User')
        $proc[$n] = if ($null -eq $p) { '' } else { [string]$p }
        $user[$n] = if ($null -eq $u) { '' } else { [string]$u }
        if ([string]$proc[$n] -ne [string]$user[$n]) { $null = $mismatch.Add($n) }
    }
    return [pscustomobject]@{ process = $proc; user = $user; mismatch = @($mismatch) }
}

function Get-NetcheckOpencode {
    $found = $false
    $path = ''
    $version = ''
    try {
        $cmd = Get-Command opencode -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            $found = $true
            $path = [string]$cmd.Source
            if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$cmd.Path }
        }
    } catch { }
    if ($found -and -not [string]::IsNullOrWhiteSpace($path)) {
        try {
            $raw = (& $path --version 2>&1 | Out-String).Trim()
            if ($raw.Length -gt 200) { $raw = $raw.Substring(0, 200) }
            $version = $raw
        } catch { $version = '' }
    }
    return [pscustomobject]@{ found = $found; path = $path; version = $version }
}

function Get-NetcheckDns {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return [pscustomobject]@{ host = ''; addresses = @(); error = 'empty host' }
    }
    $addr = New-Object System.Collections.ArrayList
    $err = ''
    try {
        $res = [System.Net.Dns]::GetHostAddresses($HostName)
        foreach ($r in @($res)) { $null = $addr.Add([string]$r.IPAddressToString) }
    } catch {
        $err = [string]$_.Exception.Message
    }
    return [pscustomobject]@{ host = $HostName; addresses = @($addr); error = $err }
}

function Read-NetcheckResponseText {
    param([System.Net.WebResponse]$Response)
    if ($null -eq $Response) { return '' }
    $stream = $null
    try {
        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) { return '' }
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($null -ne $stream) { try { $stream.Close() } catch { } }
    }
}

function Get-ProviderOutcome {
    param([int]$StatusCode = 0, [string]$Body = '', [string]$ErrorMessage = '')
    $text = ''
    if (-not [string]::IsNullOrEmpty($Body)) { $text = $Body }
    elseif (-not [string]::IsNullOrEmpty($ErrorMessage)) { $text = $ErrorMessage }
    if ($text -match 'unsupported_country_region_territory') { return 'geo-block' }
    if ($StatusCode -eq 401 -or $StatusCode -eq 403) { return 'network-ok' }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { return 'network-fail' }
    if ($StatusCode -gt 0) { return 'network-ok' }
    return 'network-fail'
}

function Invoke-NetcheckProvider {
    param([string]$Url, [string]$ProxyUrl, [int]$TimeoutMs, [string]$AuthToken)
    $statusCode = 0
    $body = ''
    $errMsg = ''
    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Proxy = New-Object System.Net.WebProxy($ProxyUrl)
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.UserAgent = 'agent-hq-netcheck/1.0'
        $request.Headers.Add('Authorization', $AuthToken)
        $response = $request.GetResponse()
        $statusCode = [int]([System.Net.HttpWebResponse]$response).StatusCode
        $body = Read-NetcheckResponseText -Response $response
    } catch [System.Net.WebException] {
        $we = $_.Exception
        $resp = $null
        try { $resp = $we.Response } catch { $resp = $null }
        if ($null -ne $resp) {
            try {
                $statusCode = [int]([System.Net.HttpWebResponse]$resp).StatusCode
                $body = Read-NetcheckResponseText -Response $resp
            } catch { $statusCode = 0 }
        } else {
            $errMsg = [string]$we.Message
        }
    } catch {
        $errMsg = [string]$_.Exception.Message
    } finally {
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }
    return [pscustomobject]@{ status_code = $statusCode; body = $body; error = $errMsg }
}

function Get-NetcheckSnippet {
    param([string]$Text, [int]$Max = 200)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = ($Text.Trim() -replace '\s+', ' ')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Get-NetcheckExitCode {
    param([bool]$ProxyUp, [string]$ProviderOutcome, [bool]$OpencodeFound)
    if (-not $ProxyUp) { return 2 }
    if ($ProviderOutcome -eq 'network-fail') { return 3 }
    if ($ProviderOutcome -eq 'geo-block') { return 4 }
    if (-not $OpencodeFound) { return 5 }
    return 0
}

function Get-NetcheckStatus {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return 'ok' }
        2 { return 'proxy-down' }
        3 { return 'network-fail' }
        4 { return 'geo-block' }
        5 { return 'opencode-missing' }
        default { return 'error' }
    }
}

function Get-NetcheckVerdict {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0 { return 'network via proxy works' }
        2 { return 'proxy is DOWN' }
        3 { return 'proxy port is UP but network via proxy failed (timeout/refused)' }
        4 { return 'geo-block: region not supported (proxy does not help)' }
        5 { return 'opencode not found in PATH' }
        default { return 'usage error' }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $uri = $null
        $validUrl = $false
        if (-not [string]::IsNullOrWhiteSpace($ProviderUrl)) {
            try {
                $uri = [Uri]$ProviderUrl
                if ($uri.IsAbsoluteUri -and ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https') -and -not [string]::IsNullOrWhiteSpace($uri.Host)) {
                    $validUrl = $true
                }
            } catch { $validUrl = $false }
        }
        if (-not $validUrl) { Write-Host 'opencode-netcheck: invalid -ProviderUrl'; exit 1 }
        if ($ProxyPort -lt 1 -or $ProxyPort -gt 65535) { Write-Host 'opencode-netcheck: invalid -ProxyPort'; exit 1 }
        if ($TimeoutSec -lt 1) { Write-Host 'opencode-netcheck: invalid -TimeoutSec'; exit 1 }

        $proxyUrl = 'http://{0}:{1}' -f $ProxyHost, $ProxyPort
        $timeoutMs = $TimeoutSec * 1000
        $portProbeMs = [Math]::Min($timeoutMs, 2000)
        if ($portProbeMs -lt 100) { $portProbeMs = 100 }

        $owned = @(Get-NetcheckOwnedProcesses -AllowedDir $CntlmDir)
        $proxyUp = Test-CntlmPort -TargetHost $ProxyHost -Port $ProxyPort -TimeoutMs $portProbeMs
        $dumps = @(Get-NetcheckCrashDumps -Dir $CntlmDir)
        $envView = Get-NetcheckEnv
        $oc = Get-NetcheckOpencode
        $dns = Get-NetcheckDns -HostName $uri.Host

        $statusCode = 0
        $body = ''
        $errMsg = ''
        if ($proxyUp) {
            $fakeToken = 'Bearer ' + ('sk' + '-diagnostic-invalid')
            $res = Invoke-NetcheckProvider -Url $ProviderUrl -ProxyUrl $proxyUrl -TimeoutMs $timeoutMs -AuthToken $fakeToken
            $statusCode = [int]$res.status_code
            $body = [string]$res.body
            $errMsg = [string]$res.error
        }
        $outcome = ''
        if ($proxyUp) { $outcome = Get-ProviderOutcome -StatusCode $statusCode -Body $body -ErrorMessage $errMsg }

        $exitCode = Get-NetcheckExitCode -ProxyUp $proxyUp -ProviderOutcome $outcome -OpencodeFound ([bool]$oc.found)
        $status = Get-NetcheckStatus -ExitCode $exitCode
        $verdict = Get-NetcheckVerdict -ExitCode $exitCode

        $snippet = ''
        if ($proxyUp) {
            if (-not [string]::IsNullOrWhiteSpace($body)) { $snippet = Get-NetcheckSnippet -Text $body }
            elseif (-not [string]::IsNullOrWhiteSpace($errMsg)) { $snippet = Get-NetcheckSnippet -Text $errMsg }
        }

        $report = [ordered]@{
            status  = $status
            verdict = $verdict
            exit_code = $exitCode
            proxy   = [ordered]@{
                host            = $ProxyHost
                port            = $ProxyPort
                up              = [bool]$proxyUp
                owned_processes = @($owned)
                crash_dumps     = @($dumps)
            }
            https   = [ordered]@{
                proxy_url   = $proxyUrl
                reachable   = [bool]($proxyUp -and ($statusCode -gt 0))
                status_code = $statusCode
            }
            env     = [ordered]@{
                process  = $envView.process
                user     = $envView.user
                mismatch = @($envView.mismatch)
            }
            opencode = [ordered]@{
                found   = [bool]$oc.found
                path    = [string]$oc.path
                version = [string]$oc.version
            }
            provider = [ordered]@{
                url         = $ProviderUrl
                host        = $uri.Host
                status_code = $statusCode
                outcome     = $outcome
                message     = $snippet
            }
            dns     = [ordered]@{
                host      = $dns.host
                addresses = @($dns.addresses)
                error     = [string]$dns.error
            }
        }

        if ($Json) {
            $report | ConvertTo-Json -Depth 6 | Write-Output
        } else {
            Write-Host '=== opencode-netcheck (read-only) ==='
            Write-Host ("proxy   : {0}:{1} {2}" -f $ProxyHost, $ProxyPort, $(if ($proxyUp) { 'UP' } else { 'DOWN' }))
            Write-Host ("cntlm   : {0} owned process(es)" -f $owned.Count)
            foreach ($p in $owned) { Write-Host ("  PID {0} {1}" -f $p.pid, $p.exe_path) }
            Write-Host ("crash   : {0} stackdump(s)" -f $dumps.Count)
            foreach ($d in $dumps) { Write-Host ("  " + $d) }
            Write-Host ("env     : HTTP_PROXY process='{0}' user='{1}'" -f $envView.process.HTTP_PROXY, $envView.user.HTTP_PROXY)
            if (@($envView.mismatch).Count -gt 0) { Write-Host ("env mismatch: " + (@($envView.mismatch) -join ', ')) }
            Write-Host ("opencode: {0}" -f $(if ($oc.found) { ($oc.path + ' ' + $oc.version).Trim() } else { 'NOT FOUND' }))
            if (@($dns.addresses).Count -gt 0) { Write-Host ("dns     : {0} -> {1}" -f $dns.host, (@($dns.addresses) -join ', ')) }
            else { Write-Host ("dns     : {0} -> error: {1}" -f $dns.host, $dns.error) }
            if ($proxyUp) { Write-Host ("provider: HTTP {0} -> {1}" -f $statusCode, $outcome) }
            if (-not [string]::IsNullOrWhiteSpace($snippet)) { Write-Host ("detail  : " + $snippet) }
            Write-Host ("VERDICT : {0} (exit {1})" -f $verdict, $exitCode)
        }
    } catch {
        Write-Host ('opencode-netcheck: unexpected error: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
