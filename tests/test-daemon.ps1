# test-daemon.ps1 - independent harness for agent-hq-daemon.ps1 (P1-3 worker pool).
# Pure PowerShell 5.1 (no Pester). Every case runs in an isolated temporary root and
# drives .agents\scripts\agent-hq-daemon.ps1 as a CHILD process (so the real exit
# code is asserted and the daemon's own `exit` can never kill this harness), using
# tests\fake-opencode.ps1 as the CLI - the real `opencode` binary is never executed.
#
# Cases:
#   a) 3 agents x 1 message, -Drain        -> 3 outbox + 3 archive, empty dead-letter, exit 0
#   b) nomarker (2 messages)               -> 2 dead-letter, exit 1, shared 2-attempt policy visible
#   c) ThrottleLimit 3 + slow CLI          -> runs really overlap (max concurrency >= 2)
#   d) ThrottleLimit 1 + slow CLI          -> never more than 1 run at a time
#   e) pre-existing foreign claim           -> skipped, no outbox, claim survives (no duplicates)
#   f) -MaxDurationSeconds bound           -> short bounded run, worker stopped, no hang
#   g) broken AGENT_HQ_OPENCODE             -> exit 1 (infrastructure error)
#   h) -Once                                -> single pass processes everything
#   i) -DryRun                              -> exit 0, nothing processed
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

# NOTE: $ErrorActionPreference is deliberately left at its default: the daemon runs
# in a child process with its own error handling.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Daemon   = Join-Path $RepoRoot ".agents\scripts\agent-hq-daemon.ps1"
$Engine   = Join-Path $RepoRoot ".agents\scripts\inbox-engine.ps1"
$Poller   = Join-Path $RepoRoot ".agents\scripts\inbox-poller.ps1"
$TaskState = Join-Path $RepoRoot ".agents\scripts\task-state.ps1"
$FakeCli  = Join-Path $Here "fake-opencode.ps1"
$TempBase = Join-Path $env:TEMP "agent-hq-tests-daemon"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass  = 0
$script:CaseFail  = 0

# --- small helpers ---------------------------------------------------------

function Test-PathLeaf {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Read-JsonFile {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-JsonFileCount {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
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

# Max number of CLI runs whose [start,finish] windows intersect. 1 means strictly
# sequential execution.
function Get-MaxConcurrency {
    param([string]$TrackDir)

    if (-not (Test-Path -LiteralPath $TrackDir -PathType Container)) { return 0 }
    $windows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $TrackDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $windows += [PSCustomObject]@{
                Start  = [datetime]::Parse([string]$r.startedAt, [System.Globalization.CultureInfo]::InvariantCulture)
                Finish = [datetime]::Parse([string]$r.finishedAt, [System.Globalization.CultureInfo]::InvariantCulture)
            }
        } catch {
            # Ignore a half-written probe record.
        }
    }
    $max = 0
    foreach ($w in $windows) {
        $n = @($windows | Where-Object { $_.Start -lt $w.Finish -and $_.Finish -gt $w.Start }).Count
        if ($n -gt $max) { $max = $n }
    }
    return $max
}

# --- environment isolation -------------------------------------------------

$script:CaseEnvKeys = @(
    "AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "FAKE_OPENCODE_MODE",
    "FAKE_OPENCODE_DELAY_MS", "FAKE_OPENCODE_TRACK_DIR", "AGENT_HQ_JOB_TIMEOUT"
)

function Clear-CaseEnv {
    foreach ($name in $script:CaseEnvKeys) {
        Remove-Item -Path ("Env:\" + $name) -ErrorAction SilentlyContinue
    }
}

function New-CaseRoot {
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
    foreach ($rel in @(".memory\inbox", ".memory\outbox", ".memory\dead-letter",
                       ".memory\archive", ".memory\traces", ".memory\claims",
                       ".agents\tasks", "track")) {
        New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null
    }
    return $root
}

function New-InboxMessage {
    param([string]$Root, [string]$Agent, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        $Id = "dmn-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    }
    $message = [ordered]@{
        id       = $Id
        from     = "team-lead"
        to       = $Agent
        type     = "task"
        priority = "normal"
        payload  = "do stuff for " + $Agent
    }
    $agentDir = Join-Path $Root (".memory\inbox\" + $Agent)
    if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    }
    $inboxFile = Join-Path $agentDir ($Id + ".json")
    [System.IO.File]::WriteAllText($inboxFile, ($message | ConvertTo-Json -Compress), $script:Utf8NoBom)
    return $Id
}

# Run the daemon in a CHILD PowerShell process and return a result object.
function Invoke-DaemonProcess {
    param([string[]]$DaemonArgs = @())

    $stdoutFile = Join-Path $env:TEMP ("daemon-out-" + [guid]::NewGuid().ToString("N") + ".txt")
    $stderrFile = Join-Path $env:TEMP ("daemon-err-" + [guid]::NewGuid().ToString("N") + ".txt")

    $argList = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ("`"" + $Daemon + "`""))
    $argList += $DaemonArgs

    $started = Get-Date
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    $elapsed = ((Get-Date) - $started).TotalSeconds

    $stdout = ""
    $stderr = ""
    if (Test-PathLeaf $stdoutFile) { $stdout = [System.IO.File]::ReadAllText($stdoutFile) }
    if (Test-PathLeaf $stderrFile) { $stderr = [System.IO.File]::ReadAllText($stderrFile) }
    Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Elapsed  = $elapsed
    }
}

function Get-DaemonReport {
    param([string]$Root)
    $path = Join-Path $Root ".memory\traces\daemon-last-run.json"
    if (-not (Test-PathLeaf $path)) { return $null }
    return (Read-JsonFile $path)
}

# The inbox holds one subdirectory per agent, so this one must recurse.
function Get-InboxJsonCount {
    param([string]$Root)
    $inbox = Join-Path $Root ".memory\inbox"
    if (-not (Test-Path -LiteralPath $inbox -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $inbox -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
}

# --- cases -----------------------------------------------------------------

function Test-CaseDrainAllAgents {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "success"

    $ids = @()
    foreach ($agent in @("dev-a", "dev-b", "dev-c")) {
        $ids += New-InboxMessage -Root $Root -Agent $agent
    }

    $run = Invoke-DaemonProcess -DaemonArgs @("-Drain", "-ThrottleLimit", "3")

    $all = $true
    $all = (Write-Check "daemon exit code 0" ($run.ExitCode -eq 0)) -and $all
    foreach ($id in $ids) {
        $outboxFile = Join-Path $Root (".memory\outbox\" + $id + ".json")
        $exists = Test-PathLeaf $outboxFile
        $all = (Write-Check ("outbox\" + $id + ".json created") $exists) -and $all
        if ($exists) {
            $msg = Read-JsonFile $outboxFile
            $all = (Write-Check ($id + " status = done") ($msg.status -eq "done")) -and $all
        }
    }
    $all = (Write-Check "3 outbox files" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 3)) -and $all
    $all = (Write-Check "3 archived inbox files" ((Get-JsonFileCount (Join-Path $Root ".memory\archive")) -eq 3)) -and $all
    $all = (Write-Check "dead-letter is empty" ((Get-JsonFileCount (Join-Path $Root ".memory\dead-letter")) -eq 0)) -and $all
    $all = (Write-Check "inbox drained" ((Get-InboxJsonCount -Root $Root) -eq 0)) -and $all

    # Engine reuse must be visible: one evidence record per message with a success attempt.
    $evCount = Get-JsonFileCount (Join-Path $Root ".memory\evidence")
    $all = (Write-Check "evidence records written by the engine (>=3)" ($evCount -ge 3)) -and $all

    $report = Get-DaemonReport -Root $Root
    $all = (Write-Check "report exists" ($null -ne $report)) -and $all
    if ($null -ne $report) {
        $all = (Write-Check "report.processed = 3" ([int]$report.processed -eq 3)) -and $all
        $all = (Write-Check "report.deadLettered = 0" ([int]$report.deadLettered -eq 0)) -and $all
        $all = (Write-Check "report.mode = drain" ([string]$report.mode -eq "drain")) -and $all
    }
    return $all
}

function Test-CaseFailureDeadLetter {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "nomarker"

    $id1 = New-InboxMessage -Root $Root -Agent "dev-a"
    $id2 = New-InboxMessage -Root $Root -Agent "dev-b"

    $run = Invoke-DaemonProcess -DaemonArgs @("-Drain", "-ThrottleLimit", "2")

    $all = $true
    $all = (Write-Check "daemon exit code 1 (dead-letter happened)" ($run.ExitCode -eq 1)) -and $all
    $all = (Write-Check "no outbox result" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 0)) -and $all
    $all = (Write-Check "dead-letter has both messages" ((Get-JsonFileCount (Join-Path $Root ".memory\dead-letter")) -eq 2)) -and $all

    $dlFile = Join-Path $Root (".memory\dead-letter\" + $id1 + ".json")
    $dlExists = Test-PathLeaf $dlFile
    $all = (Write-Check "dead-letter file for the first message exists" $dlExists) -and $all
    if ($dlExists) {
        $msg = Read-JsonFile $dlFile
        $resp = [string]$msg.response
        $all = (Write-Check "dead-letter status = failed" ($msg.status -eq "failed")) -and $all
        # Proves the shared engine retry policy: attempt 1 failed, the retry failed too.
        $all = (Write-Check "reason shows attempt 1 failure" ($resp -match "First attempt failed")) -and $all
        $all = (Write-Check "reason shows the retry failure" ($resp -match "Retry failed")) -and $all
        $all = (Write-Check "reason shows missing success marker" ($resp -match "success marker")) -and $all
    }

    $evFile = Join-Path $Root (".memory\evidence\" + $id1 + ".json")
    if (Test-PathLeaf $evFile) {
        $ev = Read-JsonFile $evFile
        $attempts = @($ev.attempts)
        $failed = @($attempts | Where-Object { $_.status -eq "failed" })
        $all = (Write-Check "evidence has exactly 2 failed attempts (no extra retry)" ($failed.Count -eq 2)) -and $all
    } else {
        $all = (Write-Check "evidence file written for failed message" $false) -and $all
    }

    $all = (Write-Check "inbox empty (all files consumed)" ((Get-InboxJsonCount -Root $Root) -eq 0)) -and $all
    return $all
}

function Test-CaseParallelOverlap {
    param([string]$Root)

    Clear-CaseEnv
    $trackDir = Join-Path $Root "track"
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "slow"
    $env:FAKE_OPENCODE_DELAY_MS = "2500"
    $env:FAKE_OPENCODE_TRACK_DIR = $trackDir

    foreach ($agent in @("dev-a", "dev-b", "dev-c")) {
        $null = New-InboxMessage -Root $Root -Agent $agent
    }

    $run = Invoke-DaemonProcess -DaemonArgs @("-Once", "-ThrottleLimit", "3")

    $all = $true
    $all = (Write-Check "daemon exit code 0" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "3 messages processed" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 3)) -and $all
    $runs = Get-JsonFileCount $trackDir
    $all = (Write-Check "3 CLI runs recorded" ($runs -eq 3)) -and $all
    $maxConcurrency = Get-MaxConcurrency -TrackDir $trackDir
    $all = (Write-Check ("runs overlapped (max concurrency " + $maxConcurrency + " >= 2)") ($maxConcurrency -ge 2)) -and $all
    # 3 x 2.5s sequential would need >= 7.5s of CLI time alone.
    $all = (Write-Check ("bounded wall clock (" + [int]$run.Elapsed + "s)") ($run.Elapsed -lt 30)) -and $all

    $report = Get-DaemonReport -Root $Root
    if ($null -ne $report) {
        $all = (Write-Check "report.throttleLimit = 3" ([int]$report.throttleLimit -eq 3)) -and $all
        $all = (Write-Check "report.mode = once" ([string]$report.mode -eq "once")) -and $all
    }
    return $all
}

function Test-CaseThrottleLimitRespected {
    param([string]$Root)

    Clear-CaseEnv
    $trackDir = Join-Path $Root "track"
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "slow"
    $env:FAKE_OPENCODE_DELAY_MS = "1200"
    $env:FAKE_OPENCODE_TRACK_DIR = $trackDir

    $null = New-InboxMessage -Root $Root -Agent "dev-a"
    $null = New-InboxMessage -Root $Root -Agent "dev-b"

    $run = Invoke-DaemonProcess -DaemonArgs @("-Once", "-ThrottleLimit", "1")

    $all = $true
    $all = (Write-Check "daemon exit code 0" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "2 messages processed" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 2)) -and $all
    $all = (Write-Check "2 CLI runs recorded" ((Get-JsonFileCount $trackDir) -eq 2)) -and $all
    $maxConcurrency = Get-MaxConcurrency -TrackDir $trackDir
    $all = (Write-Check ("ThrottleLimit 1 kept runs sequential (max concurrency " + $maxConcurrency + ")") ($maxConcurrency -eq 1)) -and $all
    return $all
}

function Test-CaseNoDuplicateProcessing {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "success"

    $id = New-InboxMessage -Root $Root -Agent "dev-a"

    # A foreign worker already owns the task (fresh lease, so the stale sweep must
    # NOT revoke it). The daemon has to skip it instead of running the task twice.
    . $TaskState
    $claimsDir = Join-Path $Root ".memory\claims"
    $claimed = Claim-Task -TaskId $id -Agent "other-worker" -LeaseSeconds 900 -StateDir $claimsDir

    $run = Invoke-DaemonProcess -DaemonArgs @("-Drain", "-ThrottleLimit", "2")

    $all = $true
    $all = (Write-Check "pre-seeded foreign claim created" $claimed) -and $all
    $all = (Write-Check "daemon exit code 0 (skip is not an error)" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "no outbox result (task was not run twice)" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 0)) -and $all
    $all = (Write-Check "no dead-letter" ((Get-JsonFileCount (Join-Path $Root ".memory\dead-letter")) -eq 0)) -and $all
    $all = (Write-Check "no archive entry" ((Get-JsonFileCount (Join-Path $Root ".memory\archive")) -eq 0)) -and $all
    $all = (Write-Check "message still waiting in the inbox" ((Get-InboxJsonCount -Root $Root) -eq 1)) -and $all
    $all = (Write-Check "foreign lease survived (owner-guarded release)" (Test-PathLeaf (Join-Path $claimsDir ($id + ".claim.json")))) -and $all

    $report = Get-DaemonReport -Root $Root
    if ($null -ne $report) {
        $all = (Write-Check "report.skipped >= 1" ([int]$report.skipped -ge 1)) -and $all
        $all = (Write-Check "report.processed = 0" ([int]$report.processed -eq 0)) -and $all
    } else {
        $all = (Write-Check "run report exists" $false) -and $all
    }
    return $all
}

function Test-CaseMaxDurationBound {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "slow"
    $env:FAKE_OPENCODE_DELAY_MS = "20000"

    $null = New-InboxMessage -Root $Root -Agent "dev-a"

    # The daemon must give up after the bound instead of waiting for the 20s CLI run.
    $run = Invoke-DaemonProcess -DaemonArgs @("-Once", "-MaxDurationSeconds", "5", "-ThrottleLimit", "2")

    $all = $true
    $all = (Write-Check ("daemon respected the duration bound (" + [int]$run.Elapsed + "s < 25s)") ($run.Elapsed -lt 25)) -and $all
    $all = (Write-Check "daemon exit code 0 (bounded stop is not an error)" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "no outbox result" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 0)) -and $all
    $all = (Write-Check "no dead-letter" ((Get-JsonFileCount (Join-Path $Root ".memory\dead-letter")) -eq 0)) -and $all
    $all = (Write-Check "unfinished message stays in the inbox" ((Get-InboxJsonCount -Root $Root) -eq 1)) -and $all

    $report = Get-DaemonReport -Root $Root
    if ($null -ne $report) {
        $all = (Write-Check "report.stopped >= 1" ([int]$report.stopped -ge 1)) -and $all
        $all = (Write-Check "report.maxDurationSeconds = 5" ([int]$report.maxDurationSeconds -eq 5)) -and $all
    } else {
        $all = (Write-Check "run report exists" $false) -and $all
    }
    return $all
}

function Test-CaseBadCli {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = Join-Path $Root "no-such-opencode.ps1"
    $env:FAKE_OPENCODE_MODE = "success"

    $null = New-InboxMessage -Root $Root -Agent "dev-a"
    $run = Invoke-DaemonProcess -DaemonArgs @("-Once")

    $all = $true
    $all = (Write-Check "daemon exit code 1 (infrastructure error)" ($run.ExitCode -eq 1)) -and $all
    $all = (Write-Check "no outbox result" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 0)) -and $all
    $all = (Write-Check "message untouched in the inbox" ((Get-InboxJsonCount -Root $Root) -eq 1)) -and $all
    $report = Get-DaemonReport -Root $Root
    if ($null -ne $report) {
        $all = (Write-Check "report.fatalErrors >= 1" ([int]$report.fatalErrors -ge 1)) -and $all
    }
    return $all
}

function Test-CaseOnceSinglePass {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "success"

    $null = New-InboxMessage -Root $Root -Agent "dev-a"
    $null = New-InboxMessage -Root $Root -Agent "dev-b"

    $run = Invoke-DaemonProcess -DaemonArgs @("-Once", "-ThrottleLimit", "2")

    $all = $true
    $all = (Write-Check "daemon exit code 0" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "2 outbox files" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 2)) -and $all
    $all = (Write-Check "inbox drained in a single pass" ((Get-InboxJsonCount -Root $Root) -eq 0)) -and $all
    $report = Get-DaemonReport -Root $Root
    if ($null -ne $report) {
        $all = (Write-Check "report.passes = 1" ([int]$report.passes -eq 1)) -and $all
        $all = (Write-Check "report.mode = once" ([string]$report.mode -eq "once")) -and $all
    }
    return $all
}

function Test-CaseDryRun {
    param([string]$Root)

    Clear-CaseEnv
    $env:AGENT_HQ_ROOT = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = "success"

    $null = New-InboxMessage -Root $Root -Agent "dev-a"
    $run = Invoke-DaemonProcess -DaemonArgs @("-Once", "-DryRun")

    $all = $true
    $all = (Write-Check "daemon exit code 0" ($run.ExitCode -eq 0)) -and $all
    $all = (Write-Check "no outbox result" ((Get-JsonFileCount (Join-Path $Root ".memory\outbox")) -eq 0)) -and $all
    $all = (Write-Check "no archive entry" ((Get-JsonFileCount (Join-Path $Root ".memory\archive")) -eq 0)) -and $all
    $all = (Write-Check "message untouched in the inbox" ((Get-InboxJsonCount -Root $Root) -eq 1)) -and $all
    return $all
}

# --- runner ----------------------------------------------------------------

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host ("CASE: " + $Name)

    $root = $null
    $ok = $false
    try {
        $root = New-CaseRoot
        $result = @(& $Body $root)
        if ($result.Count -ge 1) {
            $ok = [bool]$result[$result.Count - 1]
        }
    } catch {
        Write-Host ("    FAIL: unhandled exception -> " + $_.Exception.Message)
        $ok = $false
    } finally {
        Clear-CaseEnv
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($ok) {
        $script:CasePass++
        Write-Host ("PASS " + $Name)
    } else {
        $script:CaseFail++
        Write-Host ("FAIL " + $Name)
    }
}

# --- main ------------------------------------------------------------------

Write-Host "=== agent-hq daemon (worker pool) tests ==="
Write-Host ("Daemon : " + $Daemon)
Write-Host ("Engine : " + $Engine)
Write-Host ("FakeCLI: " + $FakeCli)

foreach ($required in @($Daemon, $Engine, $Poller, $TaskState, $FakeCli)) {
    if (-not (Test-PathLeaf $required)) {
        Write-Host ("FATAL: required file not found: " + $required)
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

Invoke-Case "a) -Drain processes every agent inbox -> outbox + archive, exit 0" { param($r) Test-CaseDrainAllAgents -Root $r }
Invoke-Case "b) failures -> dead-letter (2 attempts), exit 1"                   { param($r) Test-CaseFailureDeadLetter -Root $r }
Invoke-Case "c) worker pool really overlaps (ThrottleLimit 3)"                 { param($r) Test-CaseParallelOverlap -Root $r }
Invoke-Case "d) ThrottleLimit 1 keeps runs sequential"                        { param($r) Test-CaseThrottleLimitRespected -Root $r }
Invoke-Case "e) existing claim -> skip, no duplicate run"                     { param($r) Test-CaseNoDuplicateProcessing -Root $r }
Invoke-Case "f) -MaxDurationSeconds bounds the run (no hang)"                 { param($r) Test-CaseMaxDurationBound -Root $r }
Invoke-Case "g) broken AGENT_HQ_OPENCODE -> exit 1"                           { param($r) Test-CaseBadCli -Root $r }
Invoke-Case "h) -Once processes everything in one pass"                       { param($r) Test-CaseOnceSinglePass -Root $r }
Invoke-Case "i) -DryRun processes nothing, exit 0"                            { param($r) Test-CaseDryRun -Root $r }

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

# Best-effort cleanup of the shared temp base (cases already removed their own roots).
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
