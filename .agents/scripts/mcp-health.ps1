param(
    [switch]$Json,
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Continue"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root "opencode.json" }

# Networked MCP servers and their backend probe URLs (first reachable URL wins).
$networkProbes = @{
    "context7"         = @("https://context7.com/api/v1/search?query=test", "https://context7.com/")
    "hermes-atlas-mcp" = @("https://hermesatlas.com/")
}

# Proxy variables that must be neutralised for Node/undici to reach the network.
$proxyKeys = @(
    "HTTP_PROXY", "HTTPS_PROXY", "NODE_USE_ENV_PROXY",
    "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy",
    "GLOBAL_AGENT_HTTP_PROXY", "GLOBAL_AGENT_HTTPS_PROXY", "GLOBAL_AGENT_NO_PROXY"
)

# A wrapper .cmd must contain these clear statements to isolate the MCP process.
$wrapperMustClear = @("HTTP_PROXY", "NODE_USE_ENV_PROXY", "NO_PROXY")

# Regression guard: a networked MCP is protected from the global proxy-env only if
# opencode.json carries an environment override that clears the proxy vars, OR its
# command points to a wrapper script that clears them itself. If both are removed the
# server will break after restart -- this must be a FAIL, not a false PASS.
function Test-ProxyOverride {
    param($Srv, [string]$CmdName)

    $envDetail = "no environment block"
    $envOk = $false
    if ($null -ne $Srv.environment) {
        $envMap = @{}
        foreach ($p in $Srv.environment.PSObject.Properties) { $envMap[$p.Name] = [string]$p.Value }
        $noProxy = ""
        if ($envMap.ContainsKey("NO_PROXY")) { $noProxy = $envMap["NO_PROXY"] }
        $nodeClear = ($envMap.ContainsKey("NODE_USE_ENV_PROXY") -and [string]::IsNullOrWhiteSpace($envMap["NODE_USE_ENV_PROXY"]))
        $httpClear = ($envMap.ContainsKey("HTTP_PROXY") -and [string]::IsNullOrWhiteSpace($envMap["HTTP_PROXY"]))
        if ($nodeClear -and $httpClear -and -not [string]::IsNullOrWhiteSpace($noProxy)) {
            $envOk = $true
            $envDetail = "environment clears proxy"
        } else {
            $envDetail = "environment present but incomplete"
        }
    }

    $wrapperDetail = "command is not a wrapper file"
    $wrapperOk = $false
    if (-not [string]::IsNullOrWhiteSpace($CmdName) -and (Test-Path -LiteralPath $CmdName -PathType Leaf)) {
        $content = ""
        try { $content = [System.IO.File]::ReadAllText($CmdName) } catch { $content = "" }
        $allPresent = $true
        foreach ($needle in $wrapperMustClear) {
            if ($content -notmatch [regex]::Escape($needle)) { $allPresent = $false }
        }
        if ($allPresent) {
            $wrapperOk = $true
            $wrapperDetail = "wrapper clears proxy"
        } else {
            $wrapperDetail = "wrapper does not clear proxy"
        }
    }

    if ($envOk -or $wrapperOk) {
        $parts = @()
        if ($envOk) { $parts += $envDetail }
        if ($wrapperOk) { $parts += $wrapperDetail }
        return [pscustomobject]@{ status = "PASS"; detail = ($parts -join "; ") }
    }
    return [pscustomobject]@{ status = "FAIL"; detail = ($envDetail + "; " + $wrapperDetail) }
}

# Probes backend reachability with proxy env cleared in this process (mirrors the
# wrapper/override). NOTE: this is NOT an end-to-end MCP check -- the stdio server is
# actually spawned by opencode only after restart, so a live tool-call can be verified
# only post-restart. Here we validate the config-level override and backend reachability.
function Invoke-BackendProbe {
    param([string[]]$Urls, [int]$TimeoutSec = 12)

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        return [pscustomobject]@{ backendStatus = "WARN"; backendDetail = "node not found" }
    }

    $saved = @{}
    foreach ($k in $proxyKeys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process") }
    foreach ($k in $proxyKeys) { [Environment]::SetEnvironmentVariable($k, "", "Process") }

    $lastDetail = ""
    try {
        $ms = $TimeoutSec * 1000
        foreach ($url in $Urls) {
            $out = ""
            try {
                $js = "const mcpHealthProbe=new AbortController();const t=setTimeout(()=>mcpHealthProbe.abort(),$ms);try{t.unref()}catch(e){};fetch('$url',{signal:mcpHealthProbe.signal}).then(r=>{clearTimeout(t);console.log('HTTP '+r.status)}).catch(e=>{clearTimeout(t);console.log('ERR '+((e&&e.message)||e))});"
                $out = (& node -e $js 2>&1 | Out-String).Trim()
            } catch {
                $out = "ERR " + $_.Exception.Message
            }
            if ($out -match "(?m)^HTTP\s+(\d{3})\s*$") {
                $code = [int]$Matches[1]
                # 2xx/3xx plus 401/403 mean the endpoint answered and is reachable.
                if (($code -ge 200 -and $code -lt 400) -or $code -eq 401 -or $code -eq 403) {
                    return [pscustomobject]@{ backendStatus = "PASS"; backendDetail = "HTTP $code ($url)" }
                }
                $lastDetail = "HTTP $code ($url)"
            } else {
                if ([string]::IsNullOrWhiteSpace($out)) { $out = "no response" }
                $lastDetail = "$out ($url)"
            }
        }
    } finally {
        foreach ($k in $proxyKeys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], "Process") }
    }
    return [pscustomobject]@{ backendStatus = "FAIL"; backendDetail = $lastDetail }
}

function Write-JsonError {
    param([string]$Message)
    $doc = [ordered]@{
        summary = [ordered]@{ pass = 0; warn = 0; fail = 1; total = 0 }
        servers = @()
        error   = $Message
    }
    Write-Output (ConvertTo-Json $doc -Depth 8)
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    if ($Json) { Write-JsonError "opencode.json not found" }
    else { Write-Host "[FAIL] opencode.json not found: $ConfigPath" -ForegroundColor Red }
    exit 1
}

$config = $null
$configError = ""
try { $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { $configError = $_.Exception.Message }

if ($null -eq $config) {
    $msg = "opencode.json is malformed or empty"
    if (-not [string]::IsNullOrWhiteSpace($configError)) { $msg = $msg + ": " + $configError }
    if ($Json) { Write-JsonError $msg }
    else { Write-Host ("[FAIL] " + $msg) -ForegroundColor Red }
    exit 1
}
if ($null -eq $config.mcp) {
    if ($Json) { Write-JsonError "mcp section not found" }
    else { Write-Host "[FAIL] mcp section not found in opencode.json" -ForegroundColor Red }
    exit 1
}

$servers = @()
foreach ($prop in $config.mcp.PSObject.Properties) {
    $name = [string]$prop.Name
    $srv = $prop.Value

    $enabled = $true
    if ($null -ne $srv.enabled -and $srv.enabled -eq $false) { $enabled = $false }
    if (-not $enabled) { continue }

    $type = [string]$srv.type
    $cmdName = ""
    if ($null -ne $srv.command -and @($srv.command).Count -gt 0) { $cmdName = [string]@($srv.command)[0] }

    $wrapperStatus = "PASS"
    $wrapperDetail = "wrapper found"
    if ($type -eq "local") {
        if ([string]::IsNullOrWhiteSpace($cmdName)) {
            $wrapperStatus = "FAIL"
            $wrapperDetail = "no command defined"
        } elseif ($null -eq (Get-Command $cmdName -ErrorAction SilentlyContinue)) {
            $wrapperStatus = "FAIL"
            $wrapperDetail = "wrapper not found"
        }
    }

    $needsOverride = $networkProbes.ContainsKey($name)
    $overrideStatus = "SKIP"
    $overrideDetail = ""
    if ($needsOverride) {
        $ov = Test-ProxyOverride -Srv $srv -CmdName $cmdName
        $overrideStatus = $ov.status
        $overrideDetail = $ov.detail
    }

    $backendUrl = ""
    $backendStatus = "SKIP"
    $backendDetail = ""
    if ($needsOverride) {
        $backendUrl = (@($networkProbes[$name]) -join ", ")
        if ($wrapperStatus -eq "FAIL" -or $overrideStatus -eq "FAIL") {
            $backendStatus = "SKIP"
            $backendDetail = "prerequisite failed"
        } else {
            $probe = Invoke-BackendProbe -Urls $networkProbes[$name] -TimeoutSec 12
            $backendStatus = $probe.backendStatus
            $backendDetail = $probe.backendDetail
        }
    }

    $status = "PASS"
    if ($wrapperStatus -eq "FAIL" -or $overrideStatus -eq "FAIL" -or $backendStatus -eq "FAIL") { $status = "FAIL" }
    elseif ($wrapperStatus -eq "WARN" -or $overrideStatus -eq "WARN" -or $backendStatus -eq "WARN") { $status = "WARN" }

    $servers += [pscustomobject]@{
        name           = $name
        type           = $type
        wrapper        = $cmdName
        wrapperStatus  = $wrapperStatus
        wrapperDetail  = $wrapperDetail
        overrideStatus = $overrideStatus
        overrideDetail = $overrideDetail
        backend        = $backendUrl
        backendStatus  = $backendStatus
        backendDetail  = $backendDetail
        status         = $status
    }
}

$pass = @($servers | Where-Object { $_.status -eq "PASS" }).Count
$warn = @($servers | Where-Object { $_.status -eq "WARN" }).Count
$fail = @($servers | Where-Object { $_.status -eq "FAIL" }).Count

if ($Json) {
    $doc = [ordered]@{
        summary   = [ordered]@{ pass = $pass; warn = $warn; fail = $fail; total = $servers.Count }
        servers   = @($servers)
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-Output (ConvertTo-Json $doc -Depth 8)
} else {
    Write-Host "=== MCP Health ===" -ForegroundColor Cyan
    foreach ($s in $servers) {
        $color = "Green"
        if ($s.status -eq "FAIL") { $color = "Red" }
        elseif ($s.status -eq "WARN") { $color = "Yellow" }
        Write-Host ("[" + $s.status + "] " + $s.name + " (wrapper: " + $s.wrapperStatus + ", override: " + $s.overrideStatus + ", backend: " + $s.backendStatus + ")") -ForegroundColor $color
        if ($s.wrapperStatus -ne "PASS") { Write-Host ("        wrapper: " + $s.wrapperDetail) -ForegroundColor Gray }
        if ($s.overrideStatus -ne "" -and $s.overrideStatus -ne "SKIP") {
            $ovColor = "Gray"
            if ($s.overrideStatus -eq "FAIL") { $ovColor = "Red" } elseif ($s.overrideStatus -eq "WARN") { $ovColor = "Yellow" }
            Write-Host ("        override: " + $s.overrideDetail) -ForegroundColor $ovColor
        }
        if ($s.backend -ne "") { Write-Host ("        backend: " + $s.backend + " -> " + $s.backendDetail) -ForegroundColor Gray }
    }
    if ($fail -gt 0) {
        Write-Host "MCP HEALTH: FAIL" -ForegroundColor Red
    } elseif ($warn -gt 0) {
        Write-Host "MCP HEALTH: WARN" -ForegroundColor Yellow
    } else {
        Write-Host "MCP HEALTH: PASS" -ForegroundColor Green
    }
}

if ($fail -gt 0) { exit 1 }
exit 0
