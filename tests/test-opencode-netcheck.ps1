# test-opencode-netcheck.ps1 - offline tests for .agents\scripts\opencode-netcheck.ps1.
# No internet, no live cntlm, no writes. Exit 0 when all pass, 1 otherwise.
$Here = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$ScriptPath = Join-Path $RepoRoot ".agents\scripts\opencode-netcheck.ps1"

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) { Write-Host ("    ok  : " + $Label); $script:Pass++ }
    else { Write-Host ("    FAIL: " + $Label); $script:Fail++ }
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 400)
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

function Get-ClosedPort {
    for ($p = 31990; $p -le 32020; $p++) {
        if (-not (Test-TcpPort -HostName '127.0.0.1' -Port $p -TimeoutMs 250)) { return $p }
    }
    return 31999
}

function Invoke-Netcheck {
    param([string[]]$ExtraArgs)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArgs
    $out = (& powershell @argList | Out-String)
    return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Test-FileInvariants {
    param([string]$Label, [string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Check ($Label + ": UTF-8 BOM") $hasBom
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) { $lf++; if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } }
    }
    Write-Check ($Label + ": CRLF (lone LF = 0)") (($lf - $crlf) -eq 0 -and $crlf -gt 0)
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText($Path), [ref]$errors) | Out-Null
    Write-Check ($Label + ": PSParser 0 errors") ($errors.Count -eq 0)
}

Write-Host "=== opencode-netcheck tests (offline) ==="

# --- a) file + parser + exported functions -----------------------------------
Write-Host ""
Write-Host "CASE: a) script file exists, parses, exposes functions"
Write-Check "a) script exists" (Test-Path -LiteralPath $ScriptPath -PathType Leaf)
if (Test-Path -LiteralPath $ScriptPath -PathType Leaf) {
    Test-FileInvariants "a) opencode-netcheck.ps1" $ScriptPath
    . $ScriptPath
    Write-Check "a) Get-ProviderOutcome defined" ($null -ne (Get-Command Get-ProviderOutcome -ErrorAction SilentlyContinue))
    Write-Check "a) Get-NetcheckExitCode defined" ($null -ne (Get-Command Get-NetcheckExitCode -ErrorAction SilentlyContinue))
    Write-Check "a) Test-CntlmPort defined" ($null -ne (Get-Command Test-CntlmPort -ErrorAction SilentlyContinue))
    Write-Check "a) Get-NetcheckDns defined" ($null -ne (Get-Command Get-NetcheckDns -ErrorAction SilentlyContinue))
}

# --- b) response classifier on mocks -----------------------------------------
Write-Host ""
Write-Host "CASE: b) classifier on mocked responses"
Write-Check "b) 401 -> network-ok" ((Get-ProviderOutcome -StatusCode 401 -Body '{"error":"bad key"}') -eq 'network-ok')
Write-Check "b) 403 -> network-ok" ((Get-ProviderOutcome -StatusCode 403 -Body '{"error":"forbidden"}') -eq 'network-ok')
Write-Check "b) country marker -> geo-block" ((Get-ProviderOutcome -StatusCode 403 -Body '{"error":{"code":"unsupported_country_region_territory"}}') -eq 'geo-block')
Write-Check "b) country marker wins over 403" ((Get-ProviderOutcome -StatusCode 403 -Body 'x unsupported_country_region_territory y') -eq 'geo-block')
Write-Check "b) timeout -> network-fail" ((Get-ProviderOutcome -StatusCode 0 -ErrorMessage 'The operation has timed out') -eq 'network-fail')
Write-Check "b) refused -> network-fail" ((Get-ProviderOutcome -StatusCode 0 -ErrorMessage 'Unable to connect to the remote server') -eq 'network-fail')
Write-Check "b) 200 -> network-ok" ((Get-ProviderOutcome -StatusCode 200 -Body '{}') -eq 'network-ok')
Write-Check "b) empty -> network-fail" ((Get-ProviderOutcome -StatusCode 0) -eq 'network-fail')

# --- c) exit-code function ----------------------------------------------------
Write-Host ""
Write-Host "CASE: c) exit-code function"
Write-Check "c) ok -> 0" ((Get-NetcheckExitCode -ProxyUp $true -ProviderOutcome 'network-ok' -OpencodeFound $true) -eq 0)
Write-Check "c) proxy down -> 2" ((Get-NetcheckExitCode -ProxyUp $false -ProviderOutcome '' -OpencodeFound $true) -eq 2)
Write-Check "c) network-fail -> 3" ((Get-NetcheckExitCode -ProxyUp $true -ProviderOutcome 'network-fail' -OpencodeFound $true) -eq 3)
Write-Check "c) geo-block -> 4" ((Get-NetcheckExitCode -ProxyUp $true -ProviderOutcome 'geo-block' -OpencodeFound $true) -eq 4)
Write-Check "c) opencode missing -> 5" ((Get-NetcheckExitCode -ProxyUp $true -ProviderOutcome 'network-ok' -OpencodeFound $false) -eq 5)
Write-Check "c) proxy down beats network-fail -> 2" ((Get-NetcheckExitCode -ProxyUp $false -ProviderOutcome 'network-fail' -OpencodeFound $false) -eq 2)

# --- d) real run on a closed port: exit 2 + valid JSON ------------------------
Write-Host ""
Write-Host "CASE: d) closed port returns 2 and valid -Json"
$port = Get-ClosedPort
Write-Check ("d) port " + $port + " is closed") (-not (Test-TcpPort -HostName '127.0.0.1' -Port $port -TimeoutMs 400))
$run = Invoke-Netcheck -ExtraArgs @('-ProxyPort', [string]$port, '-ProviderUrl', 'https://localhost/v1/models', '-Json')
Write-Check "d) exit code is 2" ($run.ExitCode -eq 2)
$obj = $null
try { $obj = $run.Output | ConvertFrom-Json } catch { $obj = $null }
Write-Check "d) -Json output parses" ($null -ne $obj)
if ($null -ne $obj) {
    Write-Check "d) status == proxy-down" ([string]$obj.status -eq 'proxy-down')
    Write-Check "d) exit_code == 2" ([int]$obj.exit_code -eq 2)
    Write-Check "d) proxy.up == false" ($obj.proxy.up -eq $false)
    Write-Check "d) proxy.port echoes input" ([int]$obj.proxy.port -eq $port)
    Write-Check "d) https.reachable == false" ($obj.https.reachable -eq $false)
    Write-Check "d) verdict present" (-not [string]::IsNullOrWhiteSpace([string]$obj.verdict))
    foreach ($field in @('status', 'proxy', 'https', 'env', 'opencode', 'provider', 'dns')) {
        Write-Check ("d) JSON field '" + $field + "' present") ($null -ne $obj.PSObject.Properties[$field])
    }
    Write-Check "d) env.process present" ($null -ne $obj.env.process)
    Write-Check "d) env.user present" ($null -ne $obj.env.user)
    Write-Check "d) provider.outcome empty on proxy down" ([string]$obj.provider.outcome -eq '')
}

# --- e) usage errors ----------------------------------------------------------
Write-Host ""
Write-Host "CASE: e) usage errors return 1"
$badUrl = Invoke-Netcheck -ExtraArgs @('-ProviderUrl', 'not a url', '-ProxyPort', [string]$port)
Write-Check "e) invalid -ProviderUrl -> exit 1" ($badUrl.ExitCode -eq 1)
$badPort = Invoke-Netcheck -ExtraArgs @('-ProxyPort', '70000')
Write-Check "e) invalid -ProxyPort -> exit 1" ($badPort.ExitCode -eq 1)

# --- f) secret / forbidden-cmdlet hygiene ------------------------------------
Write-Host ""
Write-Host "CASE: f) no secret-like literals, no mutating cmdlets"
$src = [System.IO.File]::ReadAllText($ScriptPath, [System.Text.Encoding]::UTF8)
$secretPattern = 's' + 'k' + '-[A-Za-z0-9]{8,}'
$bearerPattern = 'Bearer\s+' + 's' + 'k' + '-'
Write-Check "f) no realistic secret-like token" ($src -notmatch $secretPattern)
Write-Check "f) no literal Bearer token" ($src -notmatch $bearerPattern)
foreach ($bad in @('Start-Process', 'Stop-Process', 'SetEnvironmentVariable', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-Item', 'New-Item', 'Invoke-Expression', 'Add-Type')) {
    Write-Check ("f) no '" + $bad + "'") ($src -notmatch [regex]::Escape($bad))
}
Write-Check "f) no '&&' operator" ($src -notmatch '&&')
Write-Check "f) no '||' operator" ($src -notmatch '\|\|')

# --- invariants of the test file itself --------------------------------------
Write-Host ""
Write-Host "CASE: g) test file format invariants"
Test-FileInvariants "g) test-opencode-netcheck.ps1" $PSCommandPath

# --- summary ------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
