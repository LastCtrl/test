# test-replay.ps1 - independent tests for .agents\scripts\replay.ps1 (P3).
#
# Pure PowerShell 5.1 (no Pester). Every case runs against an ISOLATED temp root
# exposed through $env:AGENT_HQ_ROOT, so the real repository is never written to.
# The -Run case drives replay.ps1 with tests\fake-opencode.ps1 as the CLI, so the
# real `opencode` binary is never executed.
#
# Covered:
#   a) syntax + CRLF of replay.ps1
#   b) replay -TaskId X -DryRun        - agent + payload in the plan, exit 0
#   c) replay -TaskId X -DryRun -Json  - machine output, attempts, self-report, ASCII-only
#   d) replay (no selector)            - latest FAILED task is picked automatically
#   e) replay -Agent override          - the override wins over the evidence agent
#   f) replay -Run                     - new evidence attempt appears, original evidence untouched
#   g) missing payload                 - clear error, exit != 0, no inbox file written
#   h) empty root                      - no crash, clear error, exit != 0
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Replay   = Join-Path $RepoRoot ".agents\scripts\replay.ps1"
$FakeCli  = Join-Path $Here "fake-opencode.ps1"

$TempBase  = Join-Path $env:TEMP "agent-hq-replay-tests"
$Root      = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$NoPayRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$EmptyRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

$TaskId       = "P3-REPLAY"
$PayloadText  = "REPLAY_PAYLOAD_MARKER do the fixture thing"
$AgentName    = "dev-1"

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
    } else {
        $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { "" } else { " -- " + $Detail }
        Write-Host ("    FAIL: " + $Label + $suffix)
    }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Get-NonAsciiCount {
    param([string]$Text)
    return @([regex]::Matches([string]$Text, '[^\x00-\x7F]')).Count
}

function Get-FileHashText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Invoke-Replay {
    param([string]$RootPath, [string[]]$Arguments = @())
    $env:AGENT_HQ_ROOT = $RootPath
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $full = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Replay) + @($Arguments)
    $text = (& $psExe @full 2>$null | Out-String)
    $code = $LASTEXITCODE
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

function Clear-CaseEnv {
    foreach ($name in @("AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "AGENT_HQ_OPENCODE_PATH", "FAKE_OPENCODE_MODE", "AGENT_HQ_JOB_TIMEOUT", "AGENT_HQ_AGENT")) {
        Remove-Item -Path ("Env:\" + $name) -ErrorAction SilentlyContinue
    }
}

function New-EvidenceFile {
    param([string]$RootPath, [string]$Id, [string]$Agent, [int]$ExitCode, [string]$Status, [string]$Reason)
    $startedAt = (Get-Date).AddMinutes(-30)
    $document = [ordered]@{
        task_id  = $Id
        attempts = @(
            [ordered]@{
                task_id       = $Id
                attempt_id    = "attempt-1"
                agent         = $Agent
                command       = "fake-cli run --agent " + $Agent
                exit_code     = $ExitCode
                status        = $Status
                reason        = $Reason
                started_at    = $startedAt.ToString("o")
                finished_at   = $startedAt.AddSeconds(2).ToString("o")
                duration_ms   = 2000
                stdout_length = 4
                stderr_length = 0
            }
        )
    }
    $path = Join-Path $RootPath (".memory\evidence\" + $Id + ".json")
    Write-TextFile -Path $path -Text ($document | ConvertTo-Json -Depth 6)
    return $path
}

function New-ArchiveMessage {
    param([string]$RootPath, [string]$Id, [string]$To, [string]$Payload)
    $message = [ordered]@{
        id       = $Id
        from     = "team-lead"
        to       = $To
        type     = "task"
        priority = "high"
        payload  = $Payload
        created  = "2026-09-17T10:00:00Z"
    }
    $path = Join-Path $RootPath (".memory\archive\" + $To + "-" + $Id + ".json")
    Write-TextFile -Path $path -Text ($message | ConvertTo-Json -Depth 4)
    return $path
}

function New-BufferFile {
    param([string]$RootPath, [string]$Id, [string]$Agent)
    $separator = '=' * 80
    $lines = @(
        $separator,
        ("[2026-09-17 10:00] " + $Agent + " -> team-lead:"),
        "TYPE: update | PRIORITY: medium",
        ("CONTENT: " + $Id + " fixture self-report; evidence .memory/evidence/" + $Id + ".json"),
        "STATUS: resolved",
        $separator
    )
    Write-TextFile -Path (Join-Path $RootPath "CONTEXT-BUFFER.md") -Text ($lines -join "`r`n")
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($caseRoot in @($Root, $NoPayRoot, $EmptyRoot)) {
    foreach ($rel in @(".memory\evidence", ".memory\inbox", ".memory\outbox", ".memory\archive",
                       ".memory\dead-letter", ".memory\traces", ".memory\claims", ".agents\tasks")) {
        New-Item -ItemType Directory -Path (Join-Path $caseRoot $rel) -Force | Out-Null
    }
}

Write-Host "=== agent-hq replay tests ==="
Write-Host ("Replay : " + $Replay)
Write-Host ("Root   : " + $Root)

if (-not (Test-Path -LiteralPath $Replay -PathType Leaf)) {
    Write-Host ("FATAL: replay not found: " + $Replay)
    exit 1
}

$originalEvidence = New-EvidenceFile -RootPath $Root -Id $TaskId -Agent $AgentName -ExitCode 1 -Status "failed" -Reason "exit code 1"
$null = New-ArchiveMessage -RootPath $Root -Id $TaskId -To $AgentName -Payload $PayloadText
New-BufferFile -RootPath $Root -Id $TaskId -Agent $AgentName

$noPayEvidence = New-EvidenceFile -RootPath $NoPayRoot -Id "P3-NOPAY" -Agent "qa-engineer" -ExitCode 1 -Status "failed" -Reason "exit code 1"
New-BufferFile -RootPath $NoPayRoot -Id "P3-NOPAY" -Agent "qa-engineer"

# --- a) syntax + CRLF ------------------------------------------------------

$caseOk = $true
$syntaxErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Replay), [ref]$syntaxErrors)
$caseOk = (Write-Check "replay.ps1 parses with zero syntax errors" ($syntaxErrors.Count -eq 0) ("errors=" + $syntaxErrors.Count)) -and $caseOk

$rawScript = [System.IO.File]::ReadAllText($Replay)
$crlfCount = @([regex]::Matches($rawScript, "`r`n")).Count
$bareLfCount = @([regex]::Matches($rawScript, "(?<!`r)`n")).Count
$caseOk = (Write-Check "replay.ps1 uses CRLF (no bare LF)" (($crlfCount -gt 0) -and ($bareLfCount -eq 0)) ("crlf=" + $crlfCount + " bareLf=" + $bareLfCount)) -and $caseOk
Close-Case "a) syntax + CRLF" $caseOk

# --- b) dry-run ------------------------------------------------------------

$caseOk = $true
$dry = Invoke-Replay -RootPath $Root -Arguments @("-TaskId", $TaskId, "-DryRun")
$caseOk = (Write-Check "dry-run exit code is 0" ($dry.code -eq 0) ("exit=" + $dry.code + " out=" + $dry.text)) -and $caseOk
$caseOk = (Write-Check "dry-run names the agent" ($dry.text -match [regex]::Escape($AgentName))) -and $caseOk
$caseOk = (Write-Check "dry-run shows the original payload" ($dry.text -match [regex]::Escape($PayloadText))) -and $caseOk
$caseOk = (Write-Check "dry-run says dry-run" ($dry.text -match 'dry-run')) -and $caseOk
$caseOk = (Write-Check "dry-run mentions the task id" ($dry.text -match [regex]::Escape($TaskId))) -and $caseOk
$caseOk = (Write-Check "dry-run writes no outbox file" (@(Get-ChildItem -LiteralPath (Join-Path $Root ".memory\outbox") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0)) -and $caseOk
Close-Case "b) dry-run plan" $caseOk

# --- c) dry-run JSON -------------------------------------------------------

$caseOk = $true
$dryJson = Invoke-Replay -RootPath $Root -Arguments @("-TaskId", $TaskId, "-DryRun", "-Json")
$caseOk = (Write-Check "json dry-run exit code is 0" ($dryJson.code -eq 0) ("exit=" + $dryJson.code)) -and $caseOk
$caseOk = (Write-Check "json stream is ASCII-only" ((Get-NonAsciiCount $dryJson.text) -eq 0)) -and $caseOk
$doc = $null
try { $doc = $dryJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
$caseOk = (Write-Check "json parses" ($null -ne $doc)) -and $caseOk
if ($null -ne $doc) {
    $caseOk = (Write-Check "json ok flag" ([bool]$doc.ok -eq $true)) -and $caseOk
    $caseOk = (Write-Check "json mode is dry-run" ([string]$doc.mode -eq "dry-run")) -and $caseOk
    $caseOk = (Write-Check "json agent" ([string]$doc.agent.name -eq $AgentName) ("agent=" + [string]$doc.agent.name)) -and $caseOk
    $caseOk = (Write-Check "json payload found" ([bool]$doc.payload.found -eq $true)) -and $caseOk
    $caseOk = (Write-Check "json payload text" ([string]$doc.payload.text -match [regex]::Escape($PayloadText))) -and $caseOk
    $caseOk = (Write-Check "json payload source is archive" ([string]$doc.payload.source -eq "archive") ("src=" + [string]$doc.payload.source)) -and $caseOk
    $attempts = @($doc.evidence.attempts)
    $caseOk = (Write-Check "json has one evidence attempt" ($attempts.Count -eq 1) ("count=" + $attempts.Count)) -and $caseOk
    if ($attempts.Count -eq 1) {
        $caseOk = (Write-Check "json attempt exit_code" ([int]$attempts[0].exit_code -eq 1)) -and $caseOk
        $caseOk = (Write-Check "json attempt reason" ([string]$attempts[0].reason -eq "exit code 1")) -and $caseOk
        $caseOk = (Write-Check "json attempt agent" ([string]$attempts[0].agent -eq $AgentName)) -and $caseOk
    }
    $caseOk = (Write-Check "json self-report from the buffer" (@($doc.self_reports).Count -ge 1) ("count=" + @($doc.self_reports).Count + " buffer=" + [string]$doc.buffer + " notes=" + (@($doc.last_run.notes) -join "; "))) -and $caseOk
    $caseOk = (Write-Check "json selector source explicit" ([string]$doc.selector.source -eq "explicit")) -and $caseOk
}
Close-Case "c) dry-run JSON" $caseOk

# --- d) default selector (latest failed task) ------------------------------

$caseOk = $true
$auto = Invoke-Replay -RootPath $Root -Arguments @("-DryRun")
$caseOk = (Write-Check "auto-selector exit code is 0" ($auto.code -eq 0) ("exit=" + $auto.code + " out=" + $auto.text)) -and $caseOk
$caseOk = (Write-Check "auto-selector picks the failed task" ($auto.text -match [regex]::Escape($TaskId))) -and $caseOk
$caseOk = (Write-Check "auto-selector reports latest-failed source" ($auto.text -match 'latest-failed')) -and $caseOk
Close-Case "d) latest failed task selector" $caseOk

# --- e) -Agent override ----------------------------------------------------

$caseOk = $true
$override = Invoke-Replay -RootPath $Root -Arguments @("-TaskId", $TaskId, "-DryRun", "-Agent", "qa-engineer")
$caseOk = (Write-Check "override exit code is 0" ($override.code -eq 0) ("exit=" + $override.code)) -and $caseOk
$caseOk = (Write-Check "override agent is used" ($override.text -match 'qa-engineer')) -and $caseOk
$caseOk = (Write-Check "override source is reported" ($override.text -match 'source: override')) -and $caseOk
Close-Case "e) agent override" $caseOk

# --- f) -Run with the fake CLI --------------------------------------------

$caseOk = $true
$hashBefore = Get-FileHashText -Path $originalEvidence
$env:AGENT_HQ_OPENCODE = $FakeCli
$env:FAKE_OPENCODE_MODE = "success"
$env:AGENT_HQ_JOB_TIMEOUT = "60"
$run = Invoke-Replay -RootPath $Root -Arguments @("-TaskId", $TaskId, "-Run", "-Json")
$hashAfter = Get-FileHashText -Path $originalEvidence
$caseOk = (Write-Check "run exit code is 0" ($run.code -eq 0) ("exit=" + $run.code + " out=" + $run.text)) -and $caseOk

$runDoc = $null
try { $runDoc = $run.text | ConvertFrom-Json -ErrorAction Stop } catch { $runDoc = $null }
$caseOk = (Write-Check "run json parses" ($null -ne $runDoc)) -and $caseOk
if ($null -ne $runDoc) {
    $caseOk = (Write-Check "run mode is run" ([string]$runDoc.mode -eq "run")) -and $caseOk
    $caseOk = (Write-Check "run engine status is done" ([string]$runDoc.engine.status -eq "done") ("status=" + [string]$runDoc.engine.status)) -and $caseOk
    $caseOk = (Write-Check "run wrote the inbox message" ([bool]$runDoc.inbox.written -eq $true)) -and $caseOk
    $caseOk = (Write-Check "run produced a new evidence file" ([bool]$runDoc.new_evidence.exists -eq $true)) -and $caseOk
    $caseOk = (Write-Check "run json reports the original untouched" ([bool]$runDoc.integrity.original_untouched -eq $true)) -and $caseOk
    $replayId = [string]$runDoc.replay_id
    $caseOk = (Write-Check "replay id carries the replay suffix" ($replayId -match ('^' + [regex]::Escape($TaskId) + '-r\d{14}-[0-9a-f]{4}$'))) -and $caseOk
    $newAttempts = @($runDoc.new_evidence.attempts)
    $caseOk = (Write-Check "new evidence holds an attempt" ($newAttempts.Count -ge 1)) -and $caseOk
    if ($newAttempts.Count -ge 1) {
        $caseOk = (Write-Check "new attempt succeeded" ([int]$newAttempts[0].exit_code -eq 0)) -and $caseOk
    }
} else {
    $replayId = ""
}

$caseOk = (Write-Check "original evidence hash is unchanged" (($hashBefore -ne "") -and ($hashBefore -eq $hashAfter)) ("before=" + $hashBefore + " after=" + $hashAfter)) -and $caseOk
$evidenceFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root ".memory\evidence") -Filter "*.json" -File -ErrorAction SilentlyContinue)
$caseOk = (Write-Check "a second evidence file appeared" ($evidenceFiles.Count -ge 2) ("count=" + $evidenceFiles.Count)) -and $caseOk
if (-not [string]::IsNullOrWhiteSpace($replayId)) {
    $newEvidencePath = Join-Path $Root (".memory\evidence\" + $replayId + ".json")
    $caseOk = (Write-Check "new evidence file exists on disk" (Test-Path -LiteralPath $newEvidencePath -PathType Leaf)) -and $caseOk
    $caseOk = (Write-Check "new outbox result exists on disk" (Test-Path -LiteralPath (Join-Path $Root (".memory\outbox\" + $replayId + ".json")) -PathType Leaf)) -and $caseOk
}
Close-Case "f) run replay" $caseOk

# --- g) missing payload ----------------------------------------------------

$caseOk = $true
$noPay = Invoke-Replay -RootPath $NoPayRoot -Arguments @("-TaskId", "P3-NOPAY", "-DryRun")
$caseOk = (Write-Check "missing payload exits non-zero" ($noPay.code -ne 0) ("exit=" + $noPay.code)) -and $caseOk
$caseOk = (Write-Check "missing payload message mentions payload" ($noPay.text -match 'payload')) -and $caseOk
$caseOk = (Write-Check "missing payload is not an internal error" ($noPay.text -notmatch 'internal error')) -and $caseOk

$noPayRun = Invoke-Replay -RootPath $NoPayRoot -Arguments @("-TaskId", "P3-NOPAY", "-Run")
$caseOk = (Write-Check "missing payload blocks -Run" ($noPayRun.code -ne 0) ("exit=" + $noPayRun.code)) -and $caseOk
$inboxFiles = @(Get-ChildItem -LiteralPath (Join-Path $NoPayRoot ".memory\inbox") -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue)
$caseOk = (Write-Check "missing payload writes no inbox file" ($inboxFiles.Count -eq 0) ("count=" + $inboxFiles.Count)) -and $caseOk
$caseOk = (Write-Check "no evidence file was created for the aborted run" (@(Get-ChildItem -LiteralPath (Join-Path $NoPayRoot ".memory\evidence") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 1)) -and $caseOk
Close-Case "g) missing payload" $caseOk

# --- h) empty root ---------------------------------------------------------

$caseOk = $true
$emptyTask = Invoke-Replay -RootPath $EmptyRoot -Arguments @("-TaskId", "NOPE", "-DryRun")
$caseOk = (Write-Check "empty root with -TaskId exits non-zero" ($emptyTask.code -ne 0) ("exit=" + $emptyTask.code)) -and $caseOk
$caseOk = (Write-Check "empty root does not crash" (($emptyTask.text -notmatch 'internal error') -and ($emptyTask.text -notmatch 'Exception'))) -and $caseOk
$caseOk = (Write-Check "empty root says payload is missing" ($emptyTask.text -match 'no payload')) -and $caseOk

$emptyAuto = Invoke-Replay -RootPath $EmptyRoot -Arguments @("-DryRun")
$caseOk = (Write-Check "empty root without selector exits non-zero" ($emptyAuto.code -ne 0) ("exit=" + $emptyAuto.code + " out=" + $emptyAuto.text)) -and $caseOk
$caseOk = (Write-Check "empty root without selector explains" ($emptyAuto.text -match 'cannot determine a task')) -and $caseOk

$emptyJson = Invoke-Replay -RootPath $EmptyRoot -Arguments @("-TaskId", "NOPE", "-Json")
$emptyDoc = $null
try { $emptyDoc = $emptyJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $emptyDoc = $null }
$caseOk = (Write-Check "empty root json still parses" ($null -ne $emptyDoc)) -and $caseOk
if ($null -ne $emptyDoc) {
    $caseOk = (Write-Check "empty root json ok=false" ([bool]$emptyDoc.ok -eq $false)) -and $caseOk
    $caseOk = (Write-Check "empty root json has an error" (-not [string]::IsNullOrWhiteSpace([string]$emptyDoc.error))) -and $caseOk
}
Close-Case "h) empty root" $caseOk

# --- cleanup ---------------------------------------------------------------

Clear-CaseEnv
try {
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Host ""
Write-Host ("=== cases: " + $script:CasePass + " passed, " + $script:CaseFail + " failed ===")
if ($script:CaseFail -gt 0) { exit 1 }
exit 0
