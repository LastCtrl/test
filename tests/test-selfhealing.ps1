# test-selfhealing.ps1 - isolated tests for cntlm-guard / snapshot-backoff / token-preflight.
# Unit: owned-process / budget / breaker / backoff / token-estimate functions on synthetic data.
# Integration: real proxy probe, closed-port probe, -DryRun restart (never acts), CLI exit codes.
# Nothing real is restarted; no foreign process is touched. Exit 0 = all pass, 1 = any FAIL.
$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$CntlmGuard = Join-Path $RepoRoot '.agents\scripts\cntlm-guard.ps1'
$Backoff    = Join-Path $RepoRoot '.agents\scripts\snapshot-backoff.ps1'
$Preflight  = Join-Path $RepoRoot '.agents\scripts\token-preflight.ps1'
$TempBase   = Join-Path $env:TEMP ('agent-hq-selfhealing-' + [guid]::NewGuid().ToString('N'))
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$ProxyOnCfg  = Join-Path $TempBase 'proxy-on.json'
$ProxyOffCfg = Join-Path $TempBase 'proxy-off.json'
$ProxyRoot   = Join-Path $TempBase 'root-on'
$ProxyRootCfg = Join-Path $ProxyRoot '.agents\config\proxy.json'

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:CntlmPid = 0

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = '')
    $suffix = if ([string]::IsNullOrEmpty($Detail)) { '' } else { ' (' + $Detail + ')' }
    if ($Condition) {
        Write-Host ('    ok  : ' + $Label + $suffix)
        $script:Pass++
    } else {
        Write-Host ('    FAIL: ' + $Label + $suffix)
        $script:Fail++
    }
}

# Environment-dependent check whose precondition is absent on this machine.
# A skip is counted separately and never affects pass/fail (and thus the exit code).
function Write-Skip {
    param([string]$Label, [string]$Detail = '')
    $suffix = if ([string]::IsNullOrEmpty($Detail)) { '' } else { ' (' + $Detail + ')' }
    Write-Host ('    SKIP: ' + $Label + $suffix)
    $script:Skip++
}

function Invoke-Cli {
    param([string]$Script, [string[]]$ArgsList = @())
    $code = -1
    $out = ''
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @ArgsList 2>&1 | Out-String
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $out = 'spawn-error: ' + $_.Exception.Message
        $code = -1
    }
    return [pscustomobject]@{ Out = [string]$out; Code = [int]$code }
}

function New-FakeCntlm {
    param([int]$Id, [string]$Name, [string]$Exe, [string]$Cmd = '')
    return [pscustomobject]@{
        ProcessId      = $Id
        Name           = $Name
        ExecutablePath = $Exe
        CommandLine    = $Cmd
    }
}

function Test-FileInvariants {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Check ($Label + ' invariants: file exists') $false
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Check ($Label + ' invariants: UTF-8 BOM') $hasBom
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
    }
    Write-Check ($Label + ' invariants: CRLF (lone LF = 0)') (($lf - $crlf) -eq 0 -and $crlf -gt 0)
    $text = [System.IO.File]::ReadAllText($Path)
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize($text, [ref]$errors)
    Write-Check ($Label + ' invariants: PSParser 0 errors') ($errors.Count -eq 0)
    $nonAscii = 0
    for ($i = 0; $i -lt $text.Length; $i++) { if ([int]$text[$i] -gt 127) { $nonAscii++ } }
    Write-Check ($Label + ' invariants: ASCII-only body') ($nonAscii -eq 0)
    $needle = 's' + 'k' + '-'
    Write-Check ($Label + ' invariants: no forbidden token') (-not $text.Contains($needle))
}

function Get-FreeTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList @([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Test-TcpPortOpen {
    param([string]$TargetHost = '127.0.0.1', [int]$Port = 3128, [int]$TimeoutMs = 800)
    if ($Port -lt 1 -or $Port -gt 65535) { return $false }
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

function Write-ProxyConfigFile {
    param([string]$Path, [string]$Mode)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Mode -ne 'on') { $Mode = 'off' }
    $doc = [ordered]@{ mode = $Mode; url = 'http://127.0.0.1:3128'; no_proxy = 'localhost,127.0.0.1' }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $doc -Depth 3), $script:Utf8NoBom)
}

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) { New-Item -ItemType Directory -Path $TempBase -Force | Out-Null }

try {
    Write-Host '=== self-healing tests ==='

    Write-Check 'cntlm-guard.ps1 exists' (Test-Path -LiteralPath $CntlmGuard -PathType Leaf)
    Write-Check 'snapshot-backoff.ps1 exists' (Test-Path -LiteralPath $Backoff -PathType Leaf)
    Write-Check 'token-preflight.ps1 exists' (Test-Path -LiteralPath $Preflight -PathType Leaf)

    # harness self-test: the catch block calls Write-Check with an extra detail
    # argument, so the function must accept it or a real harness failure would
    # throw again and hide itself.
    $detailOk = $false
    try {
        Write-Check 'h0) Write-Check accepts a detail argument' $true 'detail text'
        $detailOk = $true
    } catch {
        $detailOk = $false
    }
    Write-Check 'h1) Write-Check detail call did not throw' $detailOk

    if (-not (Test-Path -LiteralPath $CntlmGuard -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Backoff -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Preflight -PathType Leaf)) {
        throw 'one of the target scripts is missing'
    }

    # ---------------- cntlm-guard ----------------
    . $CntlmGuard

    $logFile = Join-Path $TempBase 'guard.log'
    $dryState = Join-Path $TempBase 'dry.state.json'
    $breakerState = Join-Path $TempBase 'breaker.state.json'
    $badState = Join-Path $TempBase 'bad.state.json'
    $seedPath = Join-Path $TempBase 'seed.state.json'
    $foreignDir = Join-Path $TempBase 'foreign-cntlm'

    # unit: ownership
    Write-Check 'u1) owned cntlm recognized' (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 1 -Name 'cntlm.exe' -Exe 'C:\tools\cntlm\cntlm.exe') -AllowedDir 'C:\tools\cntlm')
    Write-Check 'u2) cntlm outside allowed dir rejected' (-not (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 2 -Name 'cntlm.exe' -Exe 'C:\other\cntlm.exe') -AllowedDir 'C:\tools\cntlm'))
    Write-Check 'u3) non-cntlm name rejected' (-not (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 3 -Name 'other.exe' -Exe 'C:\tools\cntlm\other.exe') -AllowedDir 'C:\tools\cntlm'))
    Write-Check 'u4) empty exe path rejected' (-not (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 4 -Name 'cntlm.exe' -Exe '') -AllowedDir 'C:\tools\cntlm'))
    Write-Check 'u5) null process rejected' (-not (Test-CntlmOwnedProcess -Process $null -AllowedDir 'C:\tools\cntlm'))
    Write-Check 'u6) sibling dir prefix rejected' (-not (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 6 -Name 'cntlm.exe' -Exe 'C:\tools\cntlm-extra\cntlm.exe') -AllowedDir 'C:\tools\cntlm'))
    Write-Check 'u7) case-insensitive match' (Test-CntlmOwnedProcess -Process (New-FakeCntlm -Id 7 -Name 'CNTLM.EXE' -Exe 'C:\Tools\Cntlm\cntlm.exe') -AllowedDir 'C:\tools\cntlm')
    $mixed = @(
        (New-FakeCntlm -Id 11 -Name 'cntlm.exe' -Exe 'C:\tools\cntlm\cntlm.exe'),
        (New-FakeCntlm -Id 12 -Name 'cntlm.exe' -Exe 'C:\other\cntlm.exe'),
        (New-FakeCntlm -Id 13 -Name 'notepad.exe' -Exe 'C:\tools\cntlm\notepad.exe')
    )
    $picked = @(Get-CntlmProcessList -Processes $mixed -AllowedDir 'C:\tools\cntlm')
    Write-Check 'u8) process list keeps only owned (1)' ($picked.Count -eq 1 -and $picked[0].PID -eq 11)

    # unit: budget / breaker
    $now = Get-Date
    Write-Check 'u9) window count ignores old entries' ((Get-CntlmWindowCount -Times @($now, $now.AddMinutes(-10), $now.AddMinutes(-90)) -WindowMinutes 60 -Now $now) -eq 2)
    Write-Check 'u10) window count on empty set = 0' ((Get-CntlmWindowCount -Times @() -WindowMinutes 60 -Now $now) -eq 0)
    Write-Check 'u11) breaker closed below max' (-not (Test-CntlmBreakerOpen -Count 2 -MaxRestarts 3))
    Write-Check 'u12) breaker open at max' (Test-CntlmBreakerOpen -Count 3 -MaxRestarts 3)
    Write-Check 'u13) breaker open when max=0' (Test-CntlmBreakerOpen -Count 0 -MaxRestarts 0)
    $null = Add-CntlmRestartTime -StatePath $seedPath -At $now
    Write-Check 'u14) state round-trip (1 entry)' ((@(Get-CntlmRestartTimes -StatePath $seedPath)).Count -eq 1)
    [System.IO.File]::WriteAllText($badState, '{ not json', $Utf8NoBom)
    Write-Check 'u15) malformed state -> empty' ((@(Get-CntlmRestartTimes -StatePath $badState)).Count -eq 0)
    Write-Check 'u16) missing state -> empty' ((@(Get-CntlmRestartTimes -StatePath (Join-Path $TempBase 'nope.json'))).Count -eq 0)

    # integration: isolated proxy configs (never the repo-global config)
    Write-ProxyConfigFile -Path $ProxyOnCfg -Mode 'on'
    Write-ProxyConfigFile -Path $ProxyOffCfg -Mode 'off'
    Write-ProxyConfigFile -Path $ProxyRootCfg -Mode 'on'

    # live proxy probe with mode=on: the verdict must reflect the real port state
    $livePort = 3128
    $liveUp = Test-TcpPortOpen -TargetHost '127.0.0.1' -Port $livePort
    $live = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Check', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$livePort), '-LogFile', $logFile, '-StateFile', $dryState)
    if ($liveUp) {
        Write-Check 'i1) live proxy UP (mode=on) -> exit 0' ($live.Code -eq 0)
        Write-Check 'i2) live proxy UP (mode=on) -> STATUS: ok' ($live.Out -match 'STATUS: ok')
    } else {
        Write-Check 'i1) live proxy DOWN (mode=on) -> exit 2' ($live.Code -eq 2)
        Write-Check 'i2) live proxy DOWN (mode=on) -> STATUS: down' ($live.Out -match 'STATUS: down')
    }

    $closedPort = Get-FreeTcpPort
    $down = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Check', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-LogFile', $logFile)
    Write-Check 'i3) mode=on closed port -> exit 2' ($down.Code -eq 2)
    Write-Check 'i4) mode=on closed port -> STATUS: down' ($down.Out -match 'STATUS: down')

    $offChk = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Check', '-ProxyConfig', $ProxyOffCfg, '-ProxyPort', ([string]$closedPort), '-LogFile', $logFile)
    Write-Check 'i4b) mode=off short-circuit -> exit 0' ($offChk.Code -eq 0)
    Write-Check 'i4c) mode=off short-circuit -> STATUS: ok' ($offChk.Out -match 'STATUS: ok')
    Write-Check 'i4d) mode=off short-circuit -> cntlm not required' ($offChk.Out -match 'proxy mode is off')

    $rootIso = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Check', '-Root', $ProxyRoot, '-ProxyPort', ([string]$closedPort), '-LogFile', $logFile)
    Write-Check 'i4e) isolated -Root (mode=on) -> exit 2' ($rootIso.Code -eq 2)

    # locate the real owned cntlm so we can prove it survives every dry-run
    $realOwned = @(Get-CimInstance Win32_Process -Filter "Name='cntlm.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-CntlmOwnedProcess -Process $_ -AllowedDir 'C:\tools\cntlm' })
    if ($realOwned.Count -gt 0) { $script:CntlmPid = [int]$realOwned[0].ProcessId }

    # default cntlm scope with mode=on: no cntlm process -> guard must refuse to act
    $safe = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Restart', '-DryRun', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-LogFile', $logFile, '-StateFile', (Join-Path $TempBase 'safe.state.json'))
    Write-Check 'i7) default scope never mentions the test process' (-not ($safe.Out -match ('would stop PID ' + $PID)))
    # i7b/i7c assert the "no owned process" refusal in the DEFAULT scope (C:\tools\cntlm).
    # That holds only on machines without a real cntlm; a real owned cntlm makes the
    # guard plan a restart (exit 0), so the check would be environment-dependent. The
    # very same refusal is asserted deterministically in an isolated scope by i10/i11.
    if ($realOwned.Count -gt 0) {
        Write-Skip 'i7b) default scope, no cntlm process -> exit 5' 'real cntlm present in default scope; isolated equivalent in i10/i11'
        Write-Skip 'i7c) default scope, no cntlm process -> STATUS: no-process' 'real cntlm present in default scope; isolated equivalent in i10/i11'
    } else {
        Write-Check 'i7b) default scope, no cntlm process -> exit 5' ($safe.Code -eq 5)
        Write-Check 'i7c) default scope, no cntlm process -> STATUS: no-process' ($safe.Out -match 'STATUS: no-process')
    }

    # dry-run plumbing on an owned stand-in scope (powershell.exe, -DryRun never acts)
    $psDir = ''
    try { $psDir = Split-Path -Parent ((Get-Command powershell -ErrorAction Stop).Source) } catch { $psDir = '' }
    if (-not [string]::IsNullOrWhiteSpace($psDir) -and (Test-Path -LiteralPath $psDir -PathType Container)) {
        $dry = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Restart', '-DryRun', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-AllowedDir', $psDir, '-ExeName', 'powershell.exe', '-LogFile', $logFile, '-StateFile', $dryState)
        Write-Check 'i5) -Restart -DryRun with an owned process -> exit 0' ($dry.Code -eq 0)
        Write-Check 'i6) dry-run plans a stop, does not execute' (($dry.Out -match 'DRY-RUN: would stop') -and ($dry.Out -match 'STATUS: dry-run'))
        Write-Check 'i6b) dry-run reports nothing was stopped or started' ($dry.Out -match 'nothing was stopped or started')
        Write-Check 'i8) dry-run does not create a budget state file' (-not (Test-Path -LiteralPath $dryState))
    }
    if ($script:CntlmPid -gt 0) {
        Write-Check 'i9) real cntlm process still alive after dry-run' ($null -ne (Get-Process -Id $script:CntlmPid -ErrorAction SilentlyContinue))
    }

    # foreign processes: an allowed dir that holds no cntlm -> nothing to restart
    if (-not (Test-Path -LiteralPath $foreignDir)) { New-Item -ItemType Directory -Path $foreignDir -Force | Out-Null }
    $noProc = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Restart', '-DryRun', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-AllowedDir', $foreignDir, '-LogFile', $logFile, '-StateFile', (Join-Path $TempBase 'noproc.state.json'))
    Write-Check 'i10) no owned process -> exit 5' ($noProc.Code -eq 5)
    Write-Check 'i11) no owned process -> STATUS: no-process' ($noProc.Out -match 'STATUS: no-process')
    if ($script:CntlmPid -gt 0) {
        Write-Check 'i12) foreign dir did not touch the real cntlm' ($null -ne (Get-Process -Id $script:CntlmPid -ErrorAction SilentlyContinue))
    }

    # circuit breaker: budget already exhausted
    $null = Add-CntlmRestartTime -StatePath $breakerState -At (Get-Date)
    $null = Add-CntlmRestartTime -StatePath $breakerState -At (Get-Date)
    $null = Add-CntlmRestartTime -StatePath $breakerState -At (Get-Date)
    $brk = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Restart', '-DryRun', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-StateFile', $breakerState, '-MaxRestarts', '3', '-LogFile', $logFile)
    Write-Check 'i13) exhausted budget -> exit 3' ($brk.Code -eq 3)
    Write-Check 'i14) exhausted budget -> STATUS: breaker-open' ($brk.Out -match 'STATUS: breaker-open')

    $zero = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Restart', '-DryRun', '-ProxyConfig', $ProxyOnCfg, '-ProxyPort', ([string]$closedPort), '-StateFile', (Join-Path $TempBase 'zero.state.json'), '-MaxRestarts', '0', '-LogFile', $logFile)
    Write-Check 'i15) -MaxRestarts 0 -> exit 3 (breaker open)' ($zero.Code -eq 3)

    $usage = Invoke-Cli -Script $CntlmGuard -ArgsList @('-Check', '-Restart')
    Write-Check 'i16) -Check + -Restart rejected (exit 1)' ($usage.Code -eq 1)

    # ---------------- snapshot-backoff ----------------
    . $Backoff

    Write-Check 'b1) snapshot Busy error is retryable' (Test-SnapshotRetryable -Message 'Busy: FileSystem.writeFile failed')
    Write-Check 'b2) snapshot exclude error is retryable' (Test-SnapshotRetryable -Message 'opencode snapshot: exclude failed')
    Write-Check 'b3) EPERM/uv_spawn is retryable' (Test-SnapshotRetryable -Message "EPERM: operation not permitted, uv_spawn 'git'")
    Write-Check 'b4) failed-to-get-diff is retryable' (Test-SnapshotRetryable -Message 'WARN "failed to get diff"')
    Write-Check 'b5) syntax error is not retryable' (-not (Test-SnapshotRetryable -Message 'SyntaxError: unexpected token'))
    Write-Check 'b5b) fatal error naming snapshot is not retryable' (-not (Test-SnapshotRetryable -Message 'SyntaxError in snapshot.ts: unexpected token'))
    Write-Check 'b5c) fatal error naming exclude is not retryable' (-not (Test-SnapshotRetryable -Message 'FAIL exclude: cannot parse config'))
    Write-Check 'b5d) composed exclude+snapshot is retryable' (Test-SnapshotRetryable -Message 'opencode error: exclude lock while writing snapshot')
    Write-Check 'b6) empty message is not retryable' (-not (Test-SnapshotRetryable -Message ''))
    Write-Check 'b7) null message is not retryable' (-not (Test-SnapshotRetryable -Message $null))

    Write-Check 'b8) delay attempt 1 = 200' ((Get-SnapshotBackoffDelay -Attempt 1 -BaseDelayMs 200 -MaxDelayMs 5000 -Factor 2) -eq 200)
    Write-Check 'b9) delay attempt 2 = 400' ((Get-SnapshotBackoffDelay -Attempt 2 -BaseDelayMs 200 -MaxDelayMs 5000 -Factor 2) -eq 400)
    Write-Check 'b10) delay attempt 3 = 800' ((Get-SnapshotBackoffDelay -Attempt 3 -BaseDelayMs 200 -MaxDelayMs 5000 -Factor 2) -eq 800)
    Write-Check 'b11) delay capped at max' ((Get-SnapshotBackoffDelay -Attempt 5 -BaseDelayMs 1000 -MaxDelayMs 2500 -Factor 2) -eq 2500)
    Write-Check 'b12) delay attempt<1 clamped to base' ((Get-SnapshotBackoffDelay -Attempt 0 -BaseDelayMs 100 -MaxDelayMs 5000 -Factor 2) -eq 100)

    $script:fails = 0
    $sb = { $script:fails++; if ($script:fails -le 2) { throw 'Busy: FileSystem.writeFile snapshot exclude' }; return 'done' }
    $r1 = Invoke-SnapshotBackoff -Operation $sb -MaxRetries 4 -BaseDelayMs 30 -MaxDelayMs 120 -Factor 2
    Write-Check 'b13) success after 2 retries -> ok' ($r1.Status -eq 'ok')
    Write-Check 'b14) success after 2 retries -> attempts 3' ($r1.Attempts -eq 3)
    Write-Check 'b15) success after 2 retries -> result passed through' ($r1.Result -eq 'done')
    Write-Check 'b16) success after 2 retries -> 2 delays (30, 60)' ($r1.Delays.Count -eq 2 -and $r1.Delays[0] -eq 30 -and $r1.Delays[1] -eq 60)

    $sbAlways = { throw 'Busy: FileSystem.writeFile snapshot exclude' }
    $r2 = Invoke-SnapshotBackoff -Operation $sbAlways -MaxRetries 3 -BaseDelayMs 10 -MaxDelayMs 40 -NoSleep
    Write-Check 'b17) always failing -> exhausted' ($r2.Status -eq 'exhausted')
    Write-Check 'b18) always failing -> bounded attempts (4)' ($r2.Attempts -eq 4)
    Write-Check 'b19) always failing -> bounded delays (3)' ($r2.Delays.Count -eq 3)

    $sbFatal = { throw 'TypeError: cannot read property of undefined' }
    $r3 = Invoke-SnapshotBackoff -Operation $sbFatal -MaxRetries 3 -BaseDelayMs 10 -NoSleep
    Write-Check 'b20) non-retryable -> single attempt' ($r3.Status -eq 'non-retryable' -and $r3.Attempts -eq 1)
    Write-Check 'b21) non-retryable -> no delays' ($r3.Delays.Count -eq 0)

    $sbValue = { return 42 }
    $r4 = Invoke-SnapshotBackoff -Operation $sbValue -MaxRetries 2
    Write-Check 'b22) first-try success keeps value' ($r4.Status -eq 'ok' -and $r4.Attempts -eq 1 -and $r4.Result -eq 42)

    $c1 = Invoke-Cli -Script $Backoff -ArgsList @('-ErrorText', 'Busy: FileSystem.writeFile snapshot exclude')
    Write-Check 'b23) CLI retryable -> exit 2' ($c1.Code -eq 2)
    Write-Check 'b24) CLI retryable -> RETRYABLE' ($c1.Out -match 'RETRYABLE')
    $c2 = Invoke-Cli -Script $Backoff -ArgsList @('-ErrorText', 'SyntaxError: unexpected token')
    Write-Check 'b25) CLI non-retryable -> exit 0' ($c2.Code -eq 0)
    $c3 = Invoke-Cli -Script $Backoff -ArgsList @('-ErrorText', 'Busy: FileSystem.writeFile snapshot exclude', '-Json', '-MaxRetries', '3')
    $jsonOk = $false
    try { $null = $c3.Out.Trim() | ConvertFrom-Json -ErrorAction Stop; $jsonOk = $true } catch { $jsonOk = $false }
    Write-Check 'b26) CLI -Json valid' ($jsonOk)
    $c4 = Invoke-Cli -Script $Backoff -ArgsList @('-ErrorText', '')
    Write-Check 'b27) CLI empty error text -> exit 1' ($c4.Code -eq 1)
    $c5 = Invoke-Cli -Script $Backoff -ArgsList @('-ErrorText', 'SyntaxError in snapshot.ts: unexpected token')
    Write-Check 'b28) CLI snapshot word alone -> exit 0' ($c5.Code -eq 0)

    # ---------------- token-preflight ----------------
    $warnFile = Join-Path $TempBase 'warn.txt'
    $overFile = Join-Path $TempBase 'over.txt'
    $binFile = Join-Path $TempBase 'bin.dat'
    [System.IO.File]::WriteAllText($warnFile, ('a' * 400), $Utf8NoBom)
    [System.IO.File]::WriteAllText($overFile, ('a' * 800), $Utf8NoBom)
    [System.IO.File]::WriteAllBytes($binFile, [byte[]]@(0, 1, 2, 3, 0, 65, 66))

    $p1 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Input', 'hello world')
    Write-Check 'p1) small input -> exit 0' ($p1.Code -eq 0)
    Write-Check 'p2) small input -> verdict ok' ($p1.Out -match 'verdict : ok')

    $p3 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Files', $warnFile, '-LimitTokens', '100', '-CharsPerToken', '4')
    Write-Check 'p3) at-limit input -> exit 2 (warn)' ($p3.Code -eq 2)
    Write-Check 'p4) at-limit input -> verdict warn' ($p3.Out -match 'verdict : warn')

    $p5 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Files', $overFile, '-LimitTokens', '100', '-CharsPerToken', '4')
    Write-Check 'p5) oversized input -> exit 3 (over)' ($p5.Code -eq 3)
    Write-Check 'p6) oversized input -> /compact advice' ($p5.Out -match '/compact')

    $p7 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Input', 'hello', '-Json')
    $pj = $null
    try { $pj = $p7.Out.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { $pj = $null }
    Write-Check 'p7) -Json output is valid JSON' ($null -ne $pj)
    Write-Check 'p8) -Json has verdict and estTokens' ($null -ne $pj -and $null -ne $pj.verdict -and $null -ne $pj.estTokens)

    $missing = Join-Path $TempBase 'does-not-exist.txt'
    $p9 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Files', $missing, '-Json')
    $pj9 = $null
    try { $pj9 = $p9.Out.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { $pj9 = $null }
    Write-Check 'p9) missing file -> exit 0, no crash' ($p9.Code -eq 0 -and ($p9.Out -notmatch 'Exception'))
    Write-Check 'p10) missing file -> item status missing' ($null -ne $pj9 -and $pj9.items[0].status -eq 'missing')

    $p11 = Invoke-Cli -Script $Preflight -ArgsList @('-Check')
    Write-Check 'p11) no input -> exit 0' ($p11.Code -eq 0)
    Write-Check 'p12) no input -> no crash' ($p11.Out -notmatch 'Exception')

    $p13 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Input', 'abc', '-LimitTokens', '0')
    Write-Check 'p13) invalid limit -> exit 1, no crash' ($p13.Code -eq 1 -and ($p13.Out -notmatch 'Exception'))

    $p14 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Input', 'abcd', '-CharsPerToken', '0', '-Json')
    $pj14 = $null
    try { $pj14 = $p14.Out.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { $pj14 = $null }
    Write-Check 'p14) CharsPerToken 0 coerced to 4' ($p14.Code -eq 0 -and $null -ne $pj14 -and $pj14.charsPerToken -eq 4)

    $p15 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Files', $binFile, '-Json')
    $pj15 = $null
    try { $pj15 = $p15.Out.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { $pj15 = $null }
    Write-Check 'p15) binary file skipped, exit 0' ($p15.Code -eq 0 -and $null -ne $pj15 -and $pj15.items[0].status -eq 'binary')

    $dirPath = Join-Path $TempBase 'ctx'
    if (-not (Test-Path -LiteralPath $dirPath)) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $dirPath 'a.txt'), 'hello', $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $dirPath 'b.txt'), 'world', $Utf8NoBom)
    $p16 = Invoke-Cli -Script $Preflight -ArgsList @('-Check', '-Dir', $dirPath, '-Json')
    $pj16 = $null
    try { $pj16 = $p16.Out.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { $pj16 = $null }
    Write-Check 'p16) -Dir enumerates files, exit 0' ($p16.Code -eq 0 -and $null -ne $pj16 -and @($pj16.items).Count -eq 2)

    # ---------------- file invariants ----------------
    Test-FileInvariants -Path $CntlmGuard -Label 'cntlm-guard'
    Test-FileInvariants -Path $Backoff -Label 'snapshot-backoff'
    Test-FileInvariants -Path $Preflight -Label 'token-preflight'
    Test-FileInvariants -Path (Join-Path $Here 'test-selfhealing.ps1') -Label 'test-selfhealing'

} catch {
    Write-Check 'harness' $false ('unhandled exception: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionScript)
} finally {
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=================================================='
Write-Host ('SUMMARY: passed=' + $script:Pass + ' failed=' + $script:Fail + ' skipped=' + $script:Skip + ' total=' + ($script:Pass + $script:Fail))
Write-Host '=================================================='

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
