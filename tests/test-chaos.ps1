# test-chaos.ps1 - independent harness for chaos.ps1 (controlled fault injection).
# Pure PowerShell 5.1 (no Pester). Each case runs in an isolated temp root and drives
# .agents\scripts\chaos.ps1 as a CHILD process, using tests\fake-opencode.ps1 and
# tests\fake-model-cli.ps1 as CLIs - the real provider is never touched.
#
# Cases:
#   a) -List (plain + -Json)             -> all 5 scenarios listed, valid JSON, exit 0
#   b) worker-kill                       -> recovered; worker killed by PID; no loss; lease freed
#   c) model-down                        -> recovered; DEAD model -> dead-letter, exit 1
#   d) timeout                           -> recovered; hung CLI dead-lettered, no orphans
#   e) lease-expire                      -> recovered; stale sweep frees the lease, task processed
#   f) dead-letter-flood                 -> recovered; every message reaches dead-letter
#   g) -DryRun                           -> injected=false, nothing created on disk
#   h) foreign process                   -> a decoy powershell survives the worker-kill run
#   i) hygiene                           -> chaos.ps1 and this file are CRLF + ASCII, no forbidden token
#   j) repo-root guard                   -> no -Root on the real repo -> exit 2, nothing created
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Chaos = Join-Path $RepoRoot ".agents\scripts\chaos.ps1"
$FakeCli = Join-Path $Here "fake-opencode.ps1"
$FakeModelCli = Join-Path $Here "fake-model-cli.ps1"
$TestFile = Join-Path $Here "test-chaos.ps1"
$TempBase = Join-Path $env:TEMP ("agent-hq-chaos-tests-" + [guid]::NewGuid().ToString("N"))

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0
$script:Decoys = @()

function Test-PathLeaf {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Read-JsonFile {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
    } else {
        Write-Host ("    FAIL: " + $Label)
    }
    return $Condition
}

function Test-ProcessExists {
    param([int]$TargetPid)
    return ($null -ne (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue))
}

function Wait-PidGone {
    param([int]$TargetPid, [int]$TimeoutSeconds = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ProcessExists -TargetPid $TargetPid)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (-not (Test-ProcessExists -TargetPid $TargetPid))
}

function Start-Decoy {
    $marker = "chaos-decoy-" + [guid]::NewGuid().ToString("N")
    $cmd = "Start-Sleep -Seconds 180; # " + $marker
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", $cmd) -NoNewWindow -PassThru
    $decoy = [PSCustomObject]@{ Pid = [int]$proc.Id; Marker = $marker }
    $script:Decoys += $decoy
    return $decoy
}

function Stop-Decoy {
    param($Decoy)
    if ($null -eq $Decoy) { return }
    $p = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$Decoy.Pid) -ErrorAction SilentlyContinue
    if ($null -ne $p) {
        if ([string]$p.CommandLine -like ("*" + $Decoy.Marker + "*")) {
            Stop-Process -Id ([int]$Decoy.Pid) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-AllDecoys {
    foreach ($d in $script:Decoys) { Stop-Decoy -Decoy $d }
    $script:Decoys = @()
}

function Remove-CaseRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root) -and (Test-Path -LiteralPath $Root)) {
        try { [System.IO.Directory]::Delete($Root, $true) } catch { }
    }
}

function Invoke-ChaosProcess {
    param([string[]]$ChaosArgs)
    $outFile = Join-Path $TempBase ("out-" + [guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $TempBase ("err-" + [guid]::NewGuid().ToString("N") + ".txt")
    $argList = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ('"' + $Chaos + '"'))
    $argList += $ChaosArgs
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = ""
    $stderr = ""
    if (Test-PathLeaf $outFile) { $stdout = [System.IO.File]::ReadAllText($outFile) }
    if (Test-PathLeaf $errFile) { $stderr = [System.IO.File]::ReadAllText($errFile) }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ ExitCode = [int]$proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function ConvertFrom-JsonSafe {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-RepoChaosArtifacts {
    $base = Join-Path $RepoRoot ".memory"
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "chaos-*" })
}

function Invoke-ChaosScenario {
    param([string]$Name)
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
    $run = Invoke-ChaosProcess -ChaosArgs @("-Scenario", $Name, "-Run", "-Json", "-Root", $root)
    $ok = (Write-Check "chaos exit 0" ($run.ExitCode -eq 0))
    $rep = ConvertFrom-JsonSafe -Text $run.Stdout
    $ok = (Write-Check "stdout is valid JSON" ($null -ne $rep)) -and $ok

    if ($null -ne $rep) {
        $ok = (Write-Check ("scenario = " + $Name) ([string]$rep.scenario -eq $Name)) -and $ok
        $ok = (Write-Check "injected = true" ([bool]$rep.injected -eq $true)) -and $ok
        $ok = (Write-Check "recovered = true" ([bool]$rep.recovered -eq $true)) -and $ok
        $failed = @($rep.checks | Where-Object { -not $_.passed })
        $ok = (Write-Check "no failed checks in the report" ($failed.Count -eq 0)) -and $ok

        $reportFile = Join-Path $root (".memory\chaos\" + [string]$rep.runId + ".json")
        $ok = (Write-Check "report file written" (Test-PathLeaf $reportFile)) -and $ok
        $repFile = $null
        if (Test-PathLeaf $reportFile) { $repFile = ConvertFrom-JsonSafe -Text ([System.IO.File]::ReadAllText($reportFile)) }
        $ok = (Write-Check "report file is valid JSON" ($null -ne $repFile)) -and $ok
        $ok = (Write-Check "report file scenario matches" ($null -ne $repFile -and [string]$repFile.scenario -eq $Name)) -and $ok

        foreach ($key in @("daemonPid", "retryDaemonPid", "workerPid")) {
            if ($rep.details.PSObject.Properties[$key]) {
                $pidValue = 0
                if ([int]::TryParse([string]$rep.details.$key, [ref]$pidValue) -and $pidValue -gt 0) {
                    $ok = (Write-Check ($key + " " + $pidValue + " is gone") (Wait-PidGone -TargetPid $pidValue -TimeoutSeconds 5)) -and $ok
                }
            }
        }
    }

    return [PSCustomObject]@{ Ok = $ok; Report = $rep; Root = $root; Run = $run }
}

function Test-CaseList {
    $run = Invoke-ChaosProcess -ChaosArgs @("-List")
    $all = (Write-Check "list exit 0" ($run.ExitCode -eq 0))
    foreach ($name in @("worker-kill", "model-down", "timeout", "lease-expire", "dead-letter-flood")) {
        $all = (Write-Check ("scenario listed: " + $name) ($run.Stdout -match [regex]::Escape($name))) -and $all
    }
    $runJson = Invoke-ChaosProcess -ChaosArgs @("-List", "-Json")
    $parsed = ConvertFrom-JsonSafe -Text $runJson.Stdout
    $all = (Write-Check "list -Json is valid JSON" ($null -ne $parsed)) -and $all
    $all = (Write-Check "list -Json has 5 scenarios" (@($parsed).Count -eq 5)) -and $all
    return $all
}

function Test-CaseWorkerKill {
    $decoy = Start-Decoy
    $c = Invoke-ChaosScenario -Name "worker-kill"
    try {
        if ($null -eq $c.Report) { return $false }
        $ok = $c.Ok
        $ok = (Write-Check "worker process was killed by its own PID" ([bool]$c.Report.details.killed -eq $true)) -and $ok
        $ok = (Write-Check "task kept in inbox after the kill" ([int]$c.Report.details.inboxAfterKill -ge 1)) -and $ok
        $ok = (Write-Check "stale lease revoked by the sweep" ([int]$c.Report.details.revoked -ge 1 -and [int]$c.Report.details.claimsAfter -eq 0)) -and $ok
        $ok = (Write-Check "retry delivered the task to outbox (no loss)" ([int]$c.Report.details.outbox -eq 1)) -and $ok
        $ok = (Write-Check "first run exit 1, retry exit 0" ([int]$c.Report.details.firstExitCode -eq 1 -and [int]$c.Report.details.retryExitCode -eq 0)) -and $ok
        $ok = (Write-Check "decoy foreign process was not touched" (Test-ProcessExists -TargetPid $decoy.Pid)) -and $ok
        return $ok
    } finally {
        Stop-Decoy -Decoy $decoy
        Remove-CaseRoot $c.Root
    }
}

function Test-CaseModelDown {
    $c = Invoke-ChaosScenario -Name "model-down"
    try {
        if ($null -eq $c.Report) { return $false }
        $ok = $c.Ok
        $ok = (Write-Check "DEAD model dead-lettered the task (not lost)" ([int]$c.Report.details.deadLetter -eq 1 -and [int]$c.Report.details.inboxFinal -eq 0)) -and $ok
        $ok = (Write-Check "no false outbox result" ([int]$c.Report.details.outbox -eq 0)) -and $ok
        $ok = (Write-Check "daemon exit code 1" ([int]$c.Report.details.exitCode -eq 1)) -and $ok
        return $ok
    } finally { Remove-CaseRoot $c.Root }
}

function Test-CaseTimeout {
    $c = Invoke-ChaosScenario -Name "timeout"
    try {
        if ($null -eq $c.Report) { return $false }
        $ok = $c.Ok
        $ok = (Write-Check "hung CLI task dead-lettered (not lost)" ([int]$c.Report.details.deadLetter -eq 1 -and [int]$c.Report.details.inboxFinal -eq 0)) -and $ok
        $ok = (Write-Check "timeout markers recorded" ([int]$c.Report.details.timeouts -ge 1)) -and $ok
        $ok = (Write-Check "run stayed inside the bound" ([int]$c.Report.details.elapsedSeconds -lt 60)) -and $ok
        return $ok
    } finally { Remove-CaseRoot $c.Root }
}

function Test-CaseLeaseExpire {
    $c = Invoke-ChaosScenario -Name "lease-expire"
    try {
        if ($null -eq $c.Report) { return $false }
        $ok = $c.Ok
        $ok = (Write-Check "foreign lease existed before the sweep" ([int]$c.Report.details.claimBefore -ge 1)) -and $ok
        $ok = (Write-Check "stale sweep revoked it (claim freed)" ([int]$c.Report.details.revoked -ge 1 -and [int]$c.Report.details.claimsAfter -eq 0)) -and $ok
        $ok = (Write-Check "freed task processed to outbox (no loss)" ([int]$c.Report.details.outbox -eq 1 -and [int]$c.Report.details.inboxFinal -eq 0)) -and $ok
        return $ok
    } finally { Remove-CaseRoot $c.Root }
}

function Test-CaseDeadLetterFlood {
    $c = Invoke-ChaosScenario -Name "dead-letter-flood"
    try {
        if ($null -eq $c.Report) { return $false }
        $ok = $c.Ok
        $count = [int]$c.Report.details.messages
        $ok = (Write-Check ("every flooded message dead-lettered (" + $count + ")") ([int]$c.Report.details.deadLetter -eq $count)) -and $ok
        $ok = (Write-Check "no message lost" (([int]$c.Report.details.deadLetter + [int]$c.Report.details.inboxFinal) -eq $count)) -and $ok
        $ok = (Write-Check "daemon exit code 1" ([int]$c.Report.details.exitCode -eq 1)) -and $ok
        return $ok
    } finally { Remove-CaseRoot $c.Root }
}

function Test-CaseDryRun {
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
    try {
        $run = Invoke-ChaosProcess -ChaosArgs @("-Scenario", "model-down", "-Run", "-DryRun", "-Json", "-Root", $root)
        $ok = (Write-Check "dry-run exit 0" ($run.ExitCode -eq 0))
        $rep = ConvertFrom-JsonSafe -Text $run.Stdout
        $ok = (Write-Check "dry-run stdout is valid JSON" ($null -ne $rep)) -and $ok
        $ok = (Write-Check "dry-run injected = false" ($null -ne $rep -and [bool]$rep.injected -eq $false)) -and $ok
        $ok = (Write-Check "dry-run created nothing on disk" (-not (Test-Path -LiteralPath $root))) -and $ok
        return $ok
    } finally { Remove-CaseRoot $root }
}

function Test-CaseUsage {
    $run = Invoke-ChaosProcess -ChaosArgs @("-Scenario", "model-down")
    $ok = (Write-Check "missing -Run exits 2" ($run.ExitCode -eq 2))
    $run2 = Invoke-ChaosProcess -ChaosArgs @("-Scenario", "no-such-scenario", "-Run")
    $ok = (Write-Check "unknown scenario exits 2" ($run2.ExitCode -eq 2)) -and $ok
    return $ok
}

function Test-CaseRepoRootGuard {
    $before = @(Get-RepoChaosArtifacts)
    $saved = $env:AGENT_HQ_ROOT
    try {
        $env:AGENT_HQ_ROOT = $RepoRoot
        $run = Invoke-ChaosProcess -ChaosArgs @("-Scenario", "model-down", "-Run", "-Json")
    } finally {
        $env:AGENT_HQ_ROOT = $saved
    }
    $ok = (Write-Check "guard exits 2 without -Root" ($run.ExitCode -eq 2))
    $ok = (Write-Check "guard refuses the real repository" ($run.Stdout -match "refusing")) -and $ok
    $ok = (Write-Check "guard emitted no chaos report" ($run.Stdout -notmatch '"recovered"')) -and $ok
    $after = @(Get-RepoChaosArtifacts)
    $ok = (Write-Check "guard created nothing in the repo" ($after.Count -eq $before.Count)) -and $ok
    return $ok
}

function Test-CaseFileHygiene {
    $ok = $true
    foreach ($file in @($Chaos, $TestFile)) {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $loneLf = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) { $loneLf++ }
        }
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        $leaf = Split-Path $file -Leaf
        $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        $masked = $raw.Replace(('ta' + 'sk' + '-state.ps1'), 'helper.ps1')
        $tokenHits = ([regex]::Matches($masked, [regex]::Escape('s' + 'k-'))).Count
        $ok = (Write-Check ($leaf + " uses CRLF (lone LF = " + $loneLf + ")") ($loneLf -eq 0)) -and $ok
        $ok = (Write-Check ($leaf + " is ASCII-only") ($nonAscii -eq 0)) -and $ok
        $ok = (Write-Check ($leaf + " has no forbidden token") ($tokenHits -eq 0)) -and $ok
    }
    return $ok
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host ("CASE: " + $Name)
    $ok = $false
    try {
        $ok = [bool](& $Body)
    } catch {
        Write-Host ("    FAIL: unhandled exception -> " + $_.Exception.Message)
        $ok = $false
    } finally {
        Stop-AllDecoys
    }
    if ($ok) {
        $script:CasePass++
        Write-Host ("PASS " + $Name)
    } else {
        $script:CaseFail++
        Write-Host ("FAIL " + $Name)
    }
}

Write-Host "=== chaos fault-injection tests ==="
Write-Host ("Chaos  : " + $Chaos)
Write-Host ("FakeCLI: " + $FakeCli)

foreach ($required in @($Chaos, $FakeCli, $FakeModelCli)) {
    if (-not (Test-PathLeaf $required)) {
        Write-Host ("FATAL: required file not found: " + $required)
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

Invoke-Case "a) -List and -List -Json expose all scenarios" { Test-CaseList }
Invoke-Case "b) worker-kill: kill by PID, no loss, lease freed" { Test-CaseWorkerKill }
Invoke-Case "c) model-down: DEAD model -> dead-letter" { Test-CaseModelDown }
Invoke-Case "d) timeout: hung CLI -> dead-letter, no orphans" { Test-CaseTimeout }
Invoke-Case "e) lease-expire: stale sweep frees the task" { Test-CaseLeaseExpire }
Invoke-Case "f) dead-letter-flood: no message lost" { Test-CaseDeadLetterFlood }
Invoke-Case "g) -DryRun injects nothing" { Test-CaseDryRun }
Invoke-Case "h) usage errors exit 2" { Test-CaseUsage }
Invoke-Case "i) chaos.ps1 and test-chaos.ps1 are CRLF + ASCII" { Test-CaseFileHygiene }
Invoke-Case "j) guard refuses the real repository without -Root" { Test-CaseRepoRootGuard }

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

Stop-AllDecoys
if (Test-Path -LiteralPath $TempBase) {
    try { [System.IO.Directory]::Delete($TempBase, $true) } catch { }
}

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
