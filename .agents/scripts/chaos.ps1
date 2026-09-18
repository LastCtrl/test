# chaos.ps1 - controlled fault injection + recovery checks for agent-hq.
param(
    [switch]$List,
    [string]$Scenario = "",
    [switch]$Run,
    [switch]$DryRun,
    [switch]$Json,
    [string]$Root = "",
    [string]$FakeCli = "",
    [string]$FakeModelCli = "",
    [int]$DaemonTimeoutSeconds = 90
)

$script:ChaosScriptRoot = $PSScriptRoot
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:RepoRoot = Split-Path (Split-Path $script:ChaosScriptRoot -Parent) -Parent
$script:Daemon = Join-Path $script:ChaosScriptRoot "agent-hq-daemon.ps1"
$script:Engine = Join-Path $script:ChaosScriptRoot "inbox-engine.ps1"
$script:TaskState = Join-Path $script:ChaosScriptRoot "task-state.ps1"

if ([string]::IsNullOrWhiteSpace($FakeCli)) { $FakeCli = Join-Path $script:RepoRoot "tests\fake-opencode.ps1" }
if ([string]::IsNullOrWhiteSpace($FakeModelCli)) { $FakeModelCli = Join-Path $script:RepoRoot "tests\fake-model-cli.ps1" }
$script:FakeCli = $FakeCli
$script:FakeModelCli = $FakeModelCli

$script:ScenarioTable = @(
    [PSCustomObject]@{ name = "worker-kill";       description = "kill a worker process by PID mid-processing; message kept, lease stale-swept, retry delivers" },
    [PSCustomObject]@{ name = "model-down";        description = "swap the CLI model to a DEAD fake; task lands in dead-letter, never lost" },
    [PSCustomObject]@{ name = "timeout";           description = "fake CLI hangs; job timeout fires and the task is dead-lettered without orphans" },
    [PSCustomObject]@{ name = "lease-expire";      description = "age a foreign lease; stale sweep frees it and the task is processed" },
    [PSCustomObject]@{ name = "dead-letter-flood"; description = "flood failing messages; every one reaches dead-letter, none lost" }
)

$script:Checks = @()

if (Test-Path -LiteralPath $script:TaskState -PathType Leaf) { . $script:TaskState }

function Write-Info {
    param([string]$Text)
    if (-not $Json) { Write-Host $Text }
}

function Add-Check {
    param([string]$Name, [bool]$Passed)
    $script:Checks += [PSCustomObject]@{ name = $Name; passed = [bool]$Passed }
}

function New-InboxMessage {
    param([string]$Agent, [string]$Id)
    $dir = Join-Path $script:Root (".memory\inbox\" + $Agent)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $msg = [ordered]@{
        id       = $Id
        from     = "team-lead"
        to       = $Agent
        type     = "task"
        priority = "normal"
        payload  = "chaos task " + $Id
    }
    [System.IO.File]::WriteAllText((Join-Path $dir ($Id + ".json")), ($msg | ConvertTo-Json -Compress), $script:Utf8NoBom)
}

function Get-JsonCount {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
}

function Get-InboxCount {
    $inbox = Join-Path $script:Root ".memory\inbox"
    if (-not (Test-Path -LiteralPath $inbox -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $inbox -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
}

function Get-ClaimCount {
    $claims = Join-Path $script:Root ".memory\claims"
    if (-not (Test-Path -LiteralPath $claims -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $claims -Filter "*.claim.json" -File -ErrorAction SilentlyContinue).Count
}

function Convert-CreationDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value) } catch { return $null }
}

function Get-OwnedChildren {
    param([int]$ParentProcessId, [datetime]$NotBefore)
    $found = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $ParentProcessId) -ErrorAction SilentlyContinue)) {
        if ($p.Name -notmatch 'powershell') { continue }
        $created = Convert-CreationDate $p.CreationDate
        if ($null -ne $created -and $created -lt $NotBefore.AddSeconds(-5)) { continue }
        $found += $p
    }
    return $found
}

function Stop-OwnedProcess {
    param([int]$TargetPid, [int]$ParentProcessId, [datetime]$NotBefore)
    $p = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $TargetPid) -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    if ([int]$p.ParentProcessId -ne $ParentProcessId) { return $false }
    if ($p.Name -notmatch 'powershell') { return $false }
    $created = Convert-CreationDate $p.CreationDate
    if ($null -ne $created -and $created -lt $NotBefore.AddSeconds(-5)) { return $false }
    Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
    return $true
}

function Wait-OwnedChild {
    param([int]$ParentProcessId, [datetime]$NotBefore, [int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $kids = @(Get-OwnedChildren -ParentProcessId $ParentProcessId -NotBefore $NotBefore)
        if ($kids.Count -gt 0) { return $kids[0] }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Clear-OwnedOrphans {
    param([int]$ParentProcessId, [datetime]$NotBefore)
    $killed = @()
    foreach ($p in @(Get-OwnedChildren -ParentProcessId $ParentProcessId -NotBefore $NotBefore)) {
        if (Stop-OwnedProcess -TargetPid ([int]$p.ProcessId) -ParentProcessId $ParentProcessId -NotBefore $NotBefore) {
            $killed += [int]$p.ProcessId
        }
    }
    return $killed
}

function Test-NoOwnedChildren {
    param([int]$ParentProcessId, [datetime]$NotBefore, [int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-OwnedChildren -ParentProcessId $ParentProcessId -NotBefore $NotBefore).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (@(Get-OwnedChildren -ParentProcessId $ParentProcessId -NotBefore $NotBefore).Count -eq 0)
}

function Start-DaemonChild {
    param([string[]]$DaemonArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + $script:Daemon + "`" " + ($DaemonArgs -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    return [PSCustomObject]@{ Proc = $proc; OutTask = $outTask; ErrTask = $errTask; StartedAt = (Get-Date) }
}

function Wait-DaemonChild {
    param($Handle, [int]$TimeoutSeconds = 90)
    if (-not $Handle.Proc.WaitForExit($TimeoutSeconds * 1000)) { return $null }
    $code = -1
    try { $code = [int]$Handle.Proc.ExitCode } catch { $code = -1 }
    $stdout = ""
    $stderr = ""
    try { $stdout = [string]$Handle.OutTask.Result } catch { $stdout = "" }
    try { $stderr = [string]$Handle.ErrTask.Result } catch { $stderr = "" }
    return [PSCustomObject]@{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr }
}

function Stop-DaemonChild {
    param($Handle)
    try {
        if (-not $Handle.Proc.HasExited) { $null = $Handle.Proc.Kill() }
    } catch { }
}

function Save-Env {
    $keys = @("AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "AGENT_HQ_JOB_TIMEOUT", "AGENT_HQ_NO_VAULT",
              "FAKE_OPENCODE_MODE", "FAKE_OPENCODE_DELAY_MS", "FAKE_MODEL_CLI_MODE")
    $map = @{}
    foreach ($k in $keys) { $map[$k] = [Environment]::GetEnvironmentVariable($k, "Process") }
    return $map
}

function Restore-Env {
    param($Map)
    foreach ($k in $Map.Keys) { [Environment]::SetEnvironmentVariable($k, $Map[$k], "Process") }
}

function Set-BaseEnv {
    [Environment]::SetEnvironmentVariable("AGENT_HQ_ROOT", $script:Root, "Process")
    [Environment]::SetEnvironmentVariable("AGENT_HQ_OPENCODE", $script:FakeCli, "Process")
    [Environment]::SetEnvironmentVariable("AGENT_HQ_JOB_TIMEOUT", $null, "Process")
    [Environment]::SetEnvironmentVariable("AGENT_HQ_NO_VAULT", "1", "Process")
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_MODE", "success", "Process")
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_DELAY_MS", $null, "Process")
    [Environment]::SetEnvironmentVariable("FAKE_MODEL_CLI_MODE", $null, "Process")
}

function Invoke-RecoverStaleLeases {
    $claimsDir = Join-Path $script:Root ".memory\claims"
    $aged = 0
    if (Test-Path -LiteralPath $claimsDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $claimsDir -Filter "*.claim.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $obj.heartbeat_at = (Get-Date).AddSeconds(-600).ToString("yyyy-MM-ddTHH:mm:ss.fff")
                [System.IO.File]::WriteAllText($f.FullName, ($obj | ConvertTo-Json -Compress), $script:Utf8NoBom)
                $aged++
            } catch { }
        }
    }
    $revoked = @()
    if (Get-Command Revoke-StaleClaims -ErrorAction SilentlyContinue) {
        try { $revoked = @(Revoke-StaleClaims -TtlSeconds 60 -StateDir $claimsDir) } catch { $revoked = @() }
    }
    return [PSCustomObject]@{ aged = $aged; revoked = $revoked }
}

function Invoke-ScenarioWorkerKill {
    $d = [ordered]@{ injected = $true; observed = ""; workerPid = $null; killed = $false
                     firstExitCode = $null; retryExitCode = $null; inboxAfterKill = 0
                     claimsBefore = 0; claimsAfter = 0; revoked = 0; outbox = 0; deadLetter = 0; inboxFinal = 0 }
    Set-BaseEnv
    $msgId = "chaos-wk-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    New-InboxMessage -Agent "chaos-a" -Id $msgId

    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_MODE", "slow", "Process")
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_DELAY_MS", "20000", "Process")
    $h = Start-DaemonChild -DaemonArgs @("-Once", "-ThrottleLimit", "1")
    $d.daemonPid = [int]$h.Proc.Id

    $claimDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $claimDeadline -and (Get-ClaimCount) -eq 0) { Start-Sleep -Milliseconds 200 }
    $worker = Wait-OwnedChild -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 10

    $killed = $false
    if ($null -ne $worker) {
        $d.workerPid = [int]$worker.ProcessId
        $killed = Stop-OwnedProcess -TargetPid ([int]$worker.ProcessId) -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    }
    $d.killed = $killed

    $r1 = Wait-DaemonChild -Handle $h -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r1) { Stop-DaemonChild -Handle $h }
    $d.firstExitCode = if ($null -ne $r1) { [int]$r1.ExitCode } else { -1 }
    $d.inboxAfterKill = Get-InboxCount

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    $noOrphans1 = Test-NoOwnedChildren -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 5

    $d.claimsBefore = Get-ClaimCount
    $recovery = Invoke-RecoverStaleLeases
    $d.revoked = @($recovery.revoked).Count
    $d.claimsAfter = Get-ClaimCount

    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_MODE", "success", "Process")
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_DELAY_MS", $null, "Process")
    $h2 = Start-DaemonChild -DaemonArgs @("-Once", "-ThrottleLimit", "1")
    $d.retryDaemonPid = [int]$h2.Proc.Id
    $r2 = Wait-DaemonChild -Handle $h2 -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r2) { Stop-DaemonChild -Handle $h2 }
    $d.retryExitCode = if ($null -ne $r2) { [int]$r2.ExitCode } else { -1 }

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h2.Proc.Id) -NotBefore $h2.StartedAt
    $noOrphans2 = Test-NoOwnedChildren -ParentProcessId ([int]$h2.Proc.Id) -NotBefore $h2.StartedAt -TimeoutSeconds 5

    $d.outbox = Get-JsonCount (Join-Path $script:Root ".memory\outbox")
    $d.deadLetter = Get-JsonCount (Join-Path $script:Root ".memory\dead-letter")
    $d.inboxFinal = Get-InboxCount
    $d.observed = "worker " + [string]$d.workerPid + " killed; message kept, stale lease revoked, retry delivered to outbox"

    Add-Check "worker process was killed by its own PID" $killed
    Add-Check "task not lost after worker kill (kept in inbox)" ($d.inboxAfterKill -ge 1)
    Add-Check "stale lease revoked by the sweep" ($d.claimsBefore -ge 1 -and $d.revoked -ge 1 -and $d.claimsAfter -eq 0)
    Add-Check "retry delivered the task to outbox (no loss, no duplicate)" ($d.outbox -eq 1 -and $d.deadLetter -eq 0 -and $d.inboxFinal -eq 0)
    Add-Check "first run exit code reflects the worker failure" ($d.firstExitCode -eq 1)
    Add-Check "retry run exit code clean" ($d.retryExitCode -eq 0)
    Add-Check "no orphaned processes after both runs" ($noOrphans1 -and $noOrphans2)
    return $d
}

function Invoke-ScenarioModelDown {
    $d = [ordered]@{ injected = $true; observed = ""; exitCode = $null; outbox = 0; deadLetter = 0; inboxFinal = 0; evidence = 0 }
    Set-BaseEnv
    [Environment]::SetEnvironmentVariable("AGENT_HQ_OPENCODE", $script:FakeModelCli, "Process")
    [Environment]::SetEnvironmentVariable("FAKE_MODEL_CLI_MODE", "dead", "Process")

    $msgId = "chaos-md-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    New-InboxMessage -Agent "chaos-a" -Id $msgId

    $h = Start-DaemonChild -DaemonArgs @("-Drain", "-ThrottleLimit", "2")
    $d.daemonPid = [int]$h.Proc.Id
    $r = Wait-DaemonChild -Handle $h -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r) { Stop-DaemonChild -Handle $h }
    $d.exitCode = if ($null -ne $r) { [int]$r.ExitCode } else { -1 }

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    $noOrphans = Test-NoOwnedChildren -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 5

    $d.outbox = Get-JsonCount (Join-Path $script:Root ".memory\outbox")
    $d.deadLetter = Get-JsonCount (Join-Path $script:Root ".memory\dead-letter")
    $d.inboxFinal = Get-InboxCount
    $d.evidence = Get-JsonCount (Join-Path $script:Root ".memory\evidence")
    $d.observed = "DEAD model: $($d.outbox) outbox, $($d.deadLetter) dead-letter, exit $($d.exitCode)"

    Add-Check "DEAD model produced a dead-letter (task not lost)" ($d.deadLetter -eq 1 -and $d.inboxFinal -eq 0)
    Add-Check "no false outbox result" ($d.outbox -eq 0)
    Add-Check "run exit code reflects the failure" ($d.exitCode -eq 1)
    Add-Check "engine wrote failure evidence" ($d.evidence -ge 1)
    Add-Check "no orphaned processes after the run" $noOrphans
    return $d
}

function Invoke-ScenarioTimeout {
    $d = [ordered]@{ injected = $true; observed = ""; exitCode = $null; outbox = 0; deadLetter = 0; inboxFinal = 0; timeouts = 0 }
    Set-BaseEnv
    [Environment]::SetEnvironmentVariable("AGENT_HQ_JOB_TIMEOUT", "3", "Process")
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_MODE", "timeout", "Process")

    $msgId = "chaos-to-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    New-InboxMessage -Agent "chaos-a" -Id $msgId

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $h = Start-DaemonChild -DaemonArgs @("-Drain", "-ThrottleLimit", "1")
    $d.daemonPid = [int]$h.Proc.Id
    $r = Wait-DaemonChild -Handle $h -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r) { Stop-DaemonChild -Handle $h }
    $sw.Stop()
    $d.exitCode = if ($null -ne $r) { [int]$r.ExitCode } else { -1 }

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    $noOrphans = Test-NoOwnedChildren -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 5

    $d.outbox = Get-JsonCount (Join-Path $script:Root ".memory\outbox")
    $d.deadLetter = Get-JsonCount (Join-Path $script:Root ".memory\dead-letter")
    $d.inboxFinal = Get-InboxCount
    $dlFile = Join-Path $script:Root (".memory\dead-letter\" + $msgId + ".json")
    if (Test-Path -LiteralPath $dlFile -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($dlFile)
        $d.timeouts = ([regex]::Matches($text, "TIMEOUT")).Count
    }
    $d.elapsedSeconds = [int]$sw.Elapsed.TotalSeconds
    $d.observed = "hung CLI killed by the job timeout; dead-letter=$($d.deadLetter), exit $($d.exitCode), elapsed $($d.elapsedSeconds)s"

    Add-Check "hung CLI dead-lettered the task (not lost)" ($d.deadLetter -eq 1 -and $d.inboxFinal -eq 0)
    Add-Check "no false outbox result" ($d.outbox -eq 0)
    Add-Check "run exit code reflects the failure" ($d.exitCode -eq 1)
    Add-Check "timeout marker recorded in the dead-letter" ($d.timeouts -ge 1)
    Add-Check "run finished inside the bound" ($d.elapsedSeconds -lt 60)
    Add-Check "no orphaned hung processes" $noOrphans
    return $d
}

function Invoke-ScenarioLeaseExpire {
    $d = [ordered]@{ injected = $true; observed = ""; claimBefore = 0; claimAfter = 0; revoked = 0; aged = 0
                     exitCode = $null; outbox = 0; deadLetter = 0; inboxFinal = 0 }
    Set-BaseEnv
    $claimsDir = Join-Path $script:Root ".memory\claims"
    if (-not (Test-Path -LiteralPath $claimsDir -PathType Container)) { New-Item -ItemType Directory -Path $claimsDir -Force | Out-Null }

    $msgId = "chaos-le-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    New-InboxMessage -Agent "chaos-a" -Id $msgId

    $claimed = Claim-Task -TaskId $msgId -Agent "dead-worker" -LeaseSeconds 900 -StateDir $claimsDir
    $d.claimBefore = Get-ClaimCount

    $recovery = Invoke-RecoverStaleLeases
    $d.aged = [int]$recovery.aged
    $d.revoked = @($recovery.revoked).Count
    $d.claimAfter = Get-ClaimCount

    $h = Start-DaemonChild -DaemonArgs @("-Once", "-ThrottleLimit", "1")
    $d.daemonPid = [int]$h.Proc.Id
    $r = Wait-DaemonChild -Handle $h -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r) { Stop-DaemonChild -Handle $h }
    $d.exitCode = if ($null -ne $r) { [int]$r.ExitCode } else { -1 }

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    $noOrphans = Test-NoOwnedChildren -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 5

    $d.outbox = Get-JsonCount (Join-Path $script:Root ".memory\outbox")
    $d.deadLetter = Get-JsonCount (Join-Path $script:Root ".memory\dead-letter")
    $d.inboxFinal = Get-InboxCount
    $d.observed = "foreign lease aged and revoked; task then processed to outbox=$($d.outbox), exit $($d.exitCode)"

    Add-Check "pre-seeded foreign lease existed" ($claimed -and $d.claimBefore -ge 1)
    Add-Check "stale sweep revoked the aged lease" ($d.revoked -ge 1 -and $d.claimAfter -eq 0)
    Add-Check "freed task was processed (no loss)" ($d.outbox -eq 1 -and $d.deadLetter -eq 0 -and $d.inboxFinal -eq 0)
    Add-Check "run exit code clean" ($d.exitCode -eq 0)
    Add-Check "no orphaned processes after the run" $noOrphans
    return $d
}

function Invoke-ScenarioDeadLetterFlood {
    $d = [ordered]@{ injected = $true; observed = ""; messages = 0; exitCode = $null; outbox = 0
                     deadLetter = 0; inboxFinal = 0; evidence = 0 }
    Set-BaseEnv
    [Environment]::SetEnvironmentVariable("FAKE_OPENCODE_MODE", "nomarker", "Process")

    $count = 6
    for ($i = 1; $i -le $count; $i++) {
        $agent = "chaos-a" + ([string]$i)
        $msgId = "chaos-dl-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        New-InboxMessage -Agent $agent -Id $msgId
    }
    $d.messages = $count

    $h = Start-DaemonChild -DaemonArgs @("-Drain", "-ThrottleLimit", "3")
    $d.daemonPid = [int]$h.Proc.Id
    $r = Wait-DaemonChild -Handle $h -TimeoutSeconds $DaemonTimeoutSeconds
    if ($null -eq $r) { Stop-DaemonChild -Handle $h }
    $d.exitCode = if ($null -ne $r) { [int]$r.ExitCode } else { -1 }

    $null = Clear-OwnedOrphans -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt
    $noOrphans = Test-NoOwnedChildren -ParentProcessId ([int]$h.Proc.Id) -NotBefore $h.StartedAt -TimeoutSeconds 5

    $d.outbox = Get-JsonCount (Join-Path $script:Root ".memory\outbox")
    $d.deadLetter = Get-JsonCount (Join-Path $script:Root ".memory\dead-letter")
    $d.inboxFinal = Get-InboxCount
    $d.evidence = Get-JsonCount (Join-Path $script:Root ".memory\evidence")
    $d.observed = "flood of $count failing messages: dead-letter=$($d.deadLetter), inbox=$($d.inboxFinal), exit $($d.exitCode)"

    Add-Check "every flooded message reached dead-letter" ($d.deadLetter -eq $count -and $d.inboxFinal -eq 0)
    Add-Check "no message was lost" (($d.deadLetter + $d.inboxFinal) -eq $count)
    Add-Check "no false outbox result" ($d.outbox -eq 0)
    Add-Check "run exit code reflects the failures" ($d.exitCode -eq 1)
    Add-Check "engine wrote evidence for the flood" ($d.evidence -ge $count)
    Add-Check "no orphaned processes after the run" $noOrphans
    return $d
}

function Invoke-Scenario {
    param([string]$Name)
    switch ($Name) {
        "worker-kill"       { return (Invoke-ScenarioWorkerKill) }
        "model-down"        { return (Invoke-ScenarioModelDown) }
        "timeout"           { return (Invoke-ScenarioTimeout) }
        "lease-expire"      { return (Invoke-ScenarioLeaseExpire) }
        "dead-letter-flood" { return (Invoke-ScenarioDeadLetterFlood) }
        default             { return $null }
    }
}

function Get-ScenarioDef {
    param([string]$Name)
    return ($script:ScenarioTable | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Resolve-Root {
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    return $script:RepoRoot
}

function New-RunId {
    param([string]$Name)
    return ("chaos-" + $Name + "-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
}

function Write-ReportFile {
    param($Report)
    $dir = Join-Path $script:Root ".memory\chaos"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ($script:RunId + ".json")
    [System.IO.File]::WriteAllText($path, ($Report | ConvertTo-Json -Depth 10), $script:Utf8NoBom)
    return $path
}

function Show-Report {
    param($Report)
    Write-Host ("scenario  : " + $Report.scenario)
    Write-Host ("recovered : " + $Report.recovered)
    Write-Host ("injected  : " + $Report.injected)
    Write-Host ("observed  : " + $Report.observed)
    foreach ($c in @($Report.checks)) {
        $mark = "FAIL"
        if ($c.passed) { $mark = "ok" }
        Write-Host ("  " + $mark + " : " + $c.name)
    }
    if (-not $Report.recovered -and -not $Report.dryRun) {
        Write-Host ("NOT RECOVERED: " + $Report.observed)
    }
}

if ($List) {
    $items = @($script:ScenarioTable | ForEach-Object { [PSCustomObject]@{ name = $_.name; description = $_.description } })
    if ($Json) {
        Write-Output ($items | ConvertTo-Json -Depth 4)
    } else {
        Write-Host "chaos scenarios:"
        foreach ($s in $items) { Write-Host ("  " + $s.name + " - " + $s.description) }
    }
    exit 0
}

if (-not $Run) {
    if ($Json) { Write-Output (@{ error = "usage"; exit = 2 } | ConvertTo-Json) } else {
        Write-Host "usage: chaos.ps1 -List | -Scenario <name> -Run [-DryRun] [-Json] [-Root <path>]"
    }
    exit 2
}

if ([string]::IsNullOrWhiteSpace($Scenario)) {
    if ($Json) { Write-Output (@{ error = "scenario required"; exit = 2 } | ConvertTo-Json) } else {
        Write-Host "error: -Scenario is required with -Run"
    }
    exit 2
}

$def = Get-ScenarioDef -Name $Scenario
if ($null -eq $def) {
    if ($Json) { Write-Output (@{ error = "unknown scenario"; scenario = $Scenario; exit = 2 } | ConvertTo-Json) } else {
        Write-Host ("error: unknown scenario '" + $Scenario + "'")
    }
    exit 2
}

$script:Root = Resolve-Root
$script:RunId = New-RunId -Name $Scenario

if ($DryRun) {
    $plan = [ordered]@{
        scenario  = $Scenario
        runId     = $script:RunId
        dryRun    = $true
        injected  = $false
        recovered = $false
        observed  = "dry-run: no fault injected, nothing started, nothing written"
        checks    = @([PSCustomObject]@{ name = "dry-run touches nothing"; passed = $true })
        details   = [ordered]@{
            description   = $def.description
            wouldRun      = "agent-hq-daemon.ps1 on an isolated root, then inject the '" + $Scenario + "' fault"
            wouldKillOwn  = "only powershell children of the daemon PID started by this run"
        }
    }
    if ($Json) { Write-Output ($plan | ConvertTo-Json -Depth 10) } else { Show-Report -Report $plan }
    exit 0
}

$baseEnv = Save-Env
$report = $null
$exitCode = 0

try {
    foreach ($rel in @(".memory\inbox", ".memory\outbox", ".memory\dead-letter",
                       ".memory\archive", ".memory\traces", ".memory\claims", ".memory\evidence",
                       ".memory\chaos", ".agents\tasks")) {
        $full = Join-Path $script:Root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
    }

    $startedAt = (Get-Date).ToString("o")
    Write-Info ("chaos scenario '" + $Scenario + "' started (root=" + $script:Root + ")")
    $details = Invoke-Scenario -Name $Scenario
    $finishedAt = (Get-Date).ToString("o")

    if ($null -eq $details) { throw ("scenario '" + $Scenario + "' produced no result") }

    $failed = @($script:Checks | Where-Object { -not $_.passed })
    $recovered = ($script:Checks.Count -gt 0) -and ($failed.Count -eq 0)

    $report = [ordered]@{
        scenario   = $Scenario
        runId      = $script:RunId
        startedAt  = $startedAt
        finishedAt = $finishedAt
        dryRun     = $false
        injected   = [bool]$details.injected
        observed   = [string]$details.observed
        recovered  = $recovered
        checks     = @($script:Checks)
        details    = $details
    }

    $reportPath = Write-ReportFile -Report $report
    $report.reportPath = $reportPath

    if ($Json) {
        Write-Output ($report | ConvertTo-Json -Depth 10)
    } else {
        Show-Report -Report $report
    }
    if (-not $recovered) { $exitCode = 1 }
} catch {
    $exitCode = 1
    $errReport = [ordered]@{
        scenario   = $Scenario
        runId      = $script:RunId
        dryRun     = $false
        injected   = $false
        observed   = "unhandled error: " + $_.Exception.Message
        recovered  = $false
        checks     = @($script:Checks)
        details    = [ordered]@{ error = $_.Exception.Message }
    }
    if ($Json) { Write-Output ($errReport | ConvertTo-Json -Depth 10) } else { Write-Host ("chaos error: " + $_.Exception.Message) }
} finally {
    Restore-Env -Map $baseEnv
}

exit $exitCode
