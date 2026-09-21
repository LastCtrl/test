# test-proxy-mode.ps1 - independent tests for .agents\scripts\proxy-mode.ps1
# Pure PowerShell 5.1 (no Pester). Runs against an isolated temp root through
# $env:AGENT_HQ_ROOT. No downloads: the only socket is a localhost TCP connect
# probe used independently to validate -Auto. HKCU is read (not written).
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here      = $PSScriptRoot
$RepoRoot  = Split-Path -Parent $Here
$ProxyMode = Join-Path $RepoRoot ".agents\scripts\proxy-mode.ps1"

$TempBase   = Join-Path $env:TEMP "agent-hq-proxy-mode-tests"
$Root       = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigDir  = Join-Path $Root ".agents\config"
$ConfigPath = Join-Path $ConfigDir "proxy.json"

$script:CasePass = 0
$script:CaseFail = 0

$script:SavedEnv = @{}
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY','AGENT_HQ_PROXY_MODE','AGENT_HQ_ROOT')) {
    $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) { Write-Host ("    ok  : " + $Label) } else { Write-Host ("    FAIL: " + $Label) }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Get-Env {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function Get-UserEnv {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 800)
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

function Get-ConfigMode {
    $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    return ([string](($raw | ConvertFrom-Json).mode)).Trim().ToLowerInvariant()
}

New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
$env:AGENT_HQ_ROOT = $Root

. $ProxyMode

$expectedUrl     = 'http://127.0.0.1:3128'
$expectedNoProxy = 'localhost,127.0.0.1,10.*,192.168.*,*.minsk.energo.net'

# --- a) missing config -> default off, no crash ------------------------------
Write-Host ""
Write-Host "CASE: a) missing config defaults to off without crashing"
$caseOk = $true
Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue

& $ProxyMode -Json | Out-Null
$caseOk = (Write-Check "-Json exits 0 with no config" ($LASTEXITCODE -eq 0)) -and $caseOk

$jsonOut = (& $ProxyMode -Json | Out-String)
$parsed = $null
try { $parsed = $jsonOut | ConvertFrom-Json } catch { $parsed = $null }
$caseOk = (Write-Check "-Json output parses" ($null -ne $parsed)) -and $caseOk
$caseOk = (Write-Check "mode defaults to off" ($null -ne $parsed -and [string]$parsed.mode -eq 'off')) -and $caseOk
$caseOk = (Write-Check "url uses the default" ($null -ne $parsed -and [string]$parsed.url -eq $expectedUrl)) -and $caseOk
$caseOk = (Write-Check "Get-ProxyArgs is empty when off" (@(Get-ProxyArgs).Count -eq 0)) -and $caseOk

Close-Case "a) missing config default off" $caseOk

# --- b) -On sets config + process env ----------------------------------------
Write-Host ""
Write-Host "CASE: b) -On writes mode=on and exports the proxy env"
$caseOk = $true

& $ProxyMode -On | Out-Null
$caseOk = (Write-Check "-On exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "config file created" (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) -and $caseOk
$caseOk = (Write-Check "config mode is on" ((Get-ConfigMode) -eq 'on')) -and $caseOk
$caseOk = (Write-Check "HTTP_PROXY is the url" ((Get-Env 'HTTP_PROXY') -eq $expectedUrl)) -and $caseOk
$caseOk = (Write-Check "HTTPS_PROXY is the url" ((Get-Env 'HTTPS_PROXY') -eq $expectedUrl)) -and $caseOk
$caseOk = (Write-Check "NO_PROXY is set" ((Get-Env 'NO_PROXY') -eq $expectedNoProxy)) -and $caseOk
$caseOk = (Write-Check "AGENT_HQ_PROXY_MODE is on" ((Get-Env 'AGENT_HQ_PROXY_MODE') -eq 'on')) -and $caseOk
$argsOn = @(Get-ProxyArgs)
$caseOk = (Write-Check "Get-ProxyArgs returns -x url" ($argsOn.Count -eq 2 -and $argsOn[0] -eq '-x' -and $argsOn[1] -eq $expectedUrl)) -and $caseOk

Close-Case "b) -On" $caseOk

# --- c) -Off clears config + process env -------------------------------------
Write-Host ""
Write-Host "CASE: c) -Off clears the proxy env"
$caseOk = $true

& $ProxyMode -Off | Out-Null
$caseOk = (Write-Check "-Off exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "config mode is off" ((Get-ConfigMode) -eq 'off')) -and $caseOk
$caseOk = (Write-Check "HTTP_PROXY cleared" ($null -eq (Get-Env 'HTTP_PROXY'))) -and $caseOk
$caseOk = (Write-Check "HTTPS_PROXY cleared" ($null -eq (Get-Env 'HTTPS_PROXY'))) -and $caseOk
$caseOk = (Write-Check "NO_PROXY cleared" ($null -eq (Get-Env 'NO_PROXY'))) -and $caseOk
$caseOk = (Write-Check "AGENT_HQ_PROXY_MODE is off" ((Get-Env 'AGENT_HQ_PROXY_MODE') -eq 'off')) -and $caseOk
$caseOk = (Write-Check "Get-ProxyArgs is empty when off" (@(Get-ProxyArgs).Count -eq 0)) -and $caseOk

Close-Case "c) -Off" $caseOk

# --- d) -Status / -Json are valid --------------------------------------------
Write-Host ""
Write-Host "CASE: d) -Status and -Json report a valid status"
$caseOk = $true

& $ProxyMode -Status | Out-Null
$caseOk = (Write-Check "-Status exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk

$human = (& $ProxyMode -Status 6>&1 | Out-String)
$caseOk = (Write-Check "-Status prints the mode line" ($human -match 'mode\s*:')) -and $caseOk

$statusJson = (& $ProxyMode -Status -Json | Out-String)
$statusObj = $null
try { $statusObj = $statusJson | ConvertFrom-Json } catch { $statusObj = $null }
$caseOk = (Write-Check "-Status -Json parses" ($null -ne $statusObj)) -and $caseOk
$caseOk = (Write-Check "status carries mode/url/no_proxy" ($null -ne $statusObj -and $null -ne $statusObj.mode -and [string]$statusObj.url -eq $expectedUrl -and [string]$statusObj.no_proxy -eq $expectedNoProxy)) -and $caseOk
$caseOk = (Write-Check "status carries the port state" ($null -ne $statusObj -and $null -ne $statusObj.PSObject.Properties['port_open'])) -and $caseOk
$caseOk = (Write-Check "status carries the env view" ($null -ne $statusObj -and $null -ne $statusObj.env -and [string]$statusObj.env.AGENT_HQ_PROXY_MODE -eq 'off')) -and $caseOk

Close-Case "d) -Status/-Json" $caseOk

# --- e) -Auto follows the port state -----------------------------------------
Write-Host ""
Write-Host "CASE: e) -Auto follows the 3128 listener state"
$caseOk = $true

$portOpen = Test-TcpPort -HostName '127.0.0.1' -Port 3128
$expectedMode = if ($portOpen) { 'on' } else { 'off' }

& $ProxyMode -Auto | Out-Null
$caseOk = (Write-Check "-Auto exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check ("config mode matches the listener (port_open=" + $portOpen + ")") ((Get-ConfigMode) -eq $expectedMode)) -and $caseOk
$caseOk = (Write-Check "AGENT_HQ_PROXY_MODE matches" ((Get-Env 'AGENT_HQ_PROXY_MODE') -eq $expectedMode)) -and $caseOk
$argsAuto = @(Get-ProxyArgs)
$expectedArgs = if ($expectedMode -eq 'on') { 2 } else { 0 }
$caseOk = (Write-Check "Get-ProxyArgs matches the auto mode" ($argsAuto.Count -eq $expectedArgs)) -and $caseOk

Close-Case "e) -Auto" $caseOk

# --- f) -Persist does not touch HKCU without the flag ------------------------
Write-Host ""
Write-Host "CASE: f) -Persist is required before HKCU is written"
$caseOk = $true

$userBefore = [ordered]@{}
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) { $userBefore[$name] = Get-UserEnv $name }

& $ProxyMode -On | Out-Null
$userAfter = [ordered]@{}
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) { $userAfter[$name] = Get-UserEnv $name }

$unchanged = $true
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
    if ([string]$userBefore[$name] -ne [string]$userAfter[$name]) { $unchanged = $false }
}
$caseOk = (Write-Check "HKCU proxy vars are unchanged without -Persist" $unchanged) -and $caseOk

& $ProxyMode -Off | Out-Null
$userOff = [ordered]@{}
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) { $userOff[$name] = Get-UserEnv $name }
$unchangedOff = $true
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY')) {
    if ([string]$userBefore[$name] -ne [string]$userOff[$name]) { $unchangedOff = $false }
}
$caseOk = (Write-Check "HKCU proxy vars are unchanged after -Off without -Persist" $unchangedOff) -and $caseOk

Close-Case "f) -Persist guard" $caseOk

# --- g) broken config falls back to off --------------------------------------
Write-Host ""
Write-Host "CASE: g) a broken config falls back to off without crashing"
$caseOk = $true

[System.IO.File]::WriteAllText($ConfigPath, "{ this is not json", (New-Object System.Text.UTF8Encoding($false)))

& $ProxyMode -Json | Out-Null
$caseOk = (Write-Check "broken config still exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk

$brokenOut = (& $ProxyMode -Json | Out-String)
$brokenObj = $null
try { $brokenObj = $brokenOut | ConvertFrom-Json } catch { $brokenObj = $null }
$caseOk = (Write-Check "broken config still yields JSON" ($null -ne $brokenObj)) -and $caseOk
$caseOk = (Write-Check "broken config reports mode=off" ($null -ne $brokenObj -and [string]$brokenObj.mode -eq 'off')) -and $caseOk
$caseOk = (Write-Check "broken config reports an error" ($null -ne $brokenObj -and -not [string]::IsNullOrWhiteSpace([string]$brokenObj.config_error))) -and $caseOk
$caseOk = (Write-Check "Get-ProxyArgs is empty on a broken config" (@(Get-ProxyArgs).Count -eq 0)) -and $caseOk

Close-Case "g) broken config" $caseOk

# --- h) -On and -Off are mutually exclusive ----------------------------------
Write-Host ""
Write-Host "CASE: h) conflicting mode flags are rejected"
$caseOk = $true
& $ProxyMode -On -Off | Out-Null
$caseOk = (Write-Check "combining -On -Off exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk
Close-Case "h) conflicting flags" $caseOk

# --- summary + restore + cleanup ---------------------------------------------
$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

foreach ($name in @($script:SavedEnv.Keys)) {
    $value = $script:SavedEnv[$name]
    if ($null -ne $value) { [Environment]::SetEnvironmentVariable($name, [string]$value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
