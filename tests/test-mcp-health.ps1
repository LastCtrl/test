# test-mcp-health.ps1 - checks for mcp-health.ps1 (offline parse checks + live network probes).
# Exit code: 0 - all checks passed, 1 - any FAIL.

$Here       = $PSScriptRoot
$RepoRoot   = Split-Path -Parent $Here
$Script     = Join-Path $RepoRoot ".agents\scripts\mcp-health.ps1"
$HealthChk  = Join-Path $RepoRoot ".agents\scripts\health-check.ps1"
$ConfigPath = Join-Path $RepoRoot "opencode.json"

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
        $script:Pass++
    } else {
        Write-Host ("    FAIL: " + $Label)
        $script:Fail++
    }
}

function Get-EolStats {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
    }
    return [pscustomobject]@{ LoneLF = ($lf - $crlf); CRLF = $crlf }
}

function Get-ParseErrorCount {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return $errors.Count
}

# Runs a child PowerShell with a hard timeout (no Start-Process, no orphan processes).
function Invoke-ChildPowerShell {
    param([string]$ScriptPath, [string[]]$ExtraArgs = @(), [int]$TimeoutSec = 45)
    $exe = (Get-Command powershell -ErrorAction Stop).Source
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File " + '"' + $ScriptPath + '"'
    foreach ($a in $ExtraArgs) { $argLine = $argLine + " " + $a }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    $output = ""
    try { $output = ($outTask.Result + $errTask.Result) } catch { $output = "" }
    $exitCode = -1
    if (-not $timedOut) { $exitCode = $proc.ExitCode }
    $proc.Dispose()
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode; TimedOut = $timedOut }
}

# Regression guard: a networked MCP is protected only if opencode.json has a proxy-clearing
# environment block OR its command points to a wrapper that clears the proxy itself.
function Test-ConfigProxyOverride {
    param([string]$Path)
    $results = [ordered]@{}
    $cfg = $null
    try { $cfg = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return $null }
    if ($null -eq $cfg -or $null -eq $cfg.mcp) { return $null }

    foreach ($nm in @("context7", "hermes-atlas-mcp")) {
        $prop = $cfg.mcp.PSObject.Properties[$nm]
        if ($null -eq $prop) { $results[$nm] = $false; continue }
        $srv = $prop.Value

        $envOk = $false
        if ($null -ne $srv.environment) {
            $m = @{}
            foreach ($p in $srv.environment.PSObject.Properties) { $m[$p.Name] = [string]$p.Value }
            $noProxy = ""
            if ($m.ContainsKey("NO_PROXY")) { $noProxy = $m["NO_PROXY"] }
            $envOk = ($m.ContainsKey("NODE_USE_ENV_PROXY") -and [string]::IsNullOrWhiteSpace($m["NODE_USE_ENV_PROXY"]) -and
                      $m.ContainsKey("HTTP_PROXY") -and [string]::IsNullOrWhiteSpace($m["HTTP_PROXY"]) -and
                      -not [string]::IsNullOrWhiteSpace($noProxy))
        }

        $wrOk = $false
        $cmd0 = ""
        if ($null -ne $srv.command -and @($srv.command).Count -gt 0) { $cmd0 = [string]@($srv.command)[0] }
        if (-not [string]::IsNullOrWhiteSpace($cmd0) -and (Test-Path -LiteralPath $cmd0 -PathType Leaf)) {
            $content = [System.IO.File]::ReadAllText($cmd0)
            $wrOk = ($content -match "NODE_USE_ENV_PROXY" -and $content -match "HTTP_PROXY" -and $content -match "NO_PROXY")
        }
        $results[$nm] = ($envOk -or $wrOk)
    }
    return $results
}

Write-Host "=== mcp-health tests ==="

# --- T1: file exists ---
Write-Check "T1) mcp-health.ps1 exists" (Test-Path -LiteralPath $Script -PathType Leaf)

# --- T2: encoding/parsing invariants ---
$bytes = [System.IO.File]::ReadAllBytes($Script)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Write-Check "T2) UTF-8 BOM" $hasBom
$eol = Get-EolStats -Path $Script
Write-Check "T2) CRLF (lone LF = 0)" ($eol.LoneLF -eq 0 -and $eol.CRLF -gt 0)
$nonAscii = 0
for ($i = 3; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $nonAscii++ } }
Write-Check "T2) ASCII-only" ($nonAscii -eq 0)
Write-Check "T2) Parser::ParseFile 0 errors (mcp-health.ps1)" ((Get-ParseErrorCount -Path $Script) -eq 0)
Write-Check "T2) Parser::ParseFile 0 errors (health-check.ps1)" ((Get-ParseErrorCount -Path $HealthChk) -eq 0)

# --- T3: -Json output is valid ---
$childJson = Invoke-ChildPowerShell -ScriptPath $Script -ExtraArgs @("-Json")
Write-Check "T3) child did not time out" (-not $childJson.TimedOut)
$raw = $childJson.Output
$exitCode = $childJson.ExitCode
$json = $null
$parseOk = $true
try { $json = $raw | ConvertFrom-Json } catch { $parseOk = $false }
Write-Check "T3) -Json output parses" $parseOk
Write-Check "T3) summary present" ($parseOk -and $null -ne $json.summary)
Write-Check "T3) servers present" ($parseOk -and $null -ne $json.servers)

if ($parseOk) {
    $names = @($json.servers | ForEach-Object { $_.name })
    foreach ($expected in @("context7", "hermes-atlas-mcp", "sequential-thinking")) {
        Write-Check ("T4) server listed: " + $expected) ($names -contains $expected)
    }
    foreach ($sv in @($json.servers)) {
        Write-Check ("T4) wrapper found: " + $sv.name) ($sv.wrapperStatus -eq "PASS")
        $valid = @("PASS", "WARN", "FAIL", "SKIP")
        Write-Check ("T4) backend status valid: " + $sv.name) ($valid -contains $sv.backendStatus)
        $ovValid = @("PASS", "WARN", "FAIL", "SKIP")
        Write-Check ("T4) override status valid: " + $sv.name) ($ovValid -contains $sv.overrideStatus)
    }
    $fail = [int]$json.summary.fail
    if ($fail -gt 0) {
        Write-Check "T5) exit 1 on FAIL" ($exitCode -eq 1)
    } else {
        Write-Check "T5) exit 0 when no FAIL" ($exitCode -eq 0)
    }
} else {
    Write-Check "T4) server checks skipped" $false
    Write-Check "T5) exit code check skipped" $false
}

# --- T6: human-readable mode runs ---
$childHuman = Invoke-ChildPowerShell -ScriptPath $Script
Write-Check "T6) human mode did not time out" (-not $childHuman.TimedOut)
Write-Check "T6) human mode prints header" ($childHuman.Output -match "MCP Health")

# --- T7: no orphan node probe processes ---
$orphans = @()
try {
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*mcpHealthProbe*" })
} catch { }
Write-Check "T7) no orphan node probe processes" ($orphans.Count -eq 0)

# --- T8: no temp files created by the script ---
$tempMatches = @(Get-ChildItem -Path $env:TEMP -Filter "*mcp*health*" -ErrorAction SilentlyContinue)
Write-Check "T8) no temp files named *mcp*health*" ($tempMatches.Count -eq 0)
$src = [System.IO.File]::ReadAllText($Script)
$writesTemp = ($src -match "New-TemporaryFile" -or $src -match "GetTempFileName" -or $src -match '\$env:TEMP')
Write-Check "T8) source does not create temp files" (-not $writesTemp)

# --- T9: regression guard - opencode.json still carries the proxy override/wrapper ---
$ov = Test-ConfigProxyOverride -Path $ConfigPath
Write-Check "T9) opencode.json readable for override check" ($null -ne $ov)
if ($null -ne $ov) {
    foreach ($nm in @("context7", "hermes-atlas-mcp")) {
        Write-Check ("T9) proxy override/wrapper present: " + $nm) ([bool]$ov[$nm])
    }
} else {
    Write-Check "T9) override checks skipped" $false
}

# --- T10: health-check keeps MCP FAIL visible but non-fatal ---
$healthSrc = [System.IO.File]::ReadAllText($HealthChk)
Write-Check "T10) health-check prints explicit MCP warning" ($healthSrc -match '\[WARN\] MCP: \$McpFail failing')

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
