# test-pipeline.ps1 - Independent end-to-end harness for the inbox-poller pipeline.
# Pure PowerShell 5.1 (no Pester). Every case runs inside an isolated temporary root
# and drives .agents\scripts\inbox-poller.ps1 with tests\fake-opencode.ps1 as the CLI,
# so the real `opencode` binary is never executed.
#
# Each case: new temp root -> set AGENT_HQ_ROOT / AGENT_HQ_OPENCODE / FAKE_OPENCODE_MODE
#            -> drop one inbox message -> run poller -Once -> assert -> cleanup.
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

# NOTE: $ErrorActionPreference is deliberately left at its default. The poller is
# invoked in-process and keeps its own error handling; a global 'Stop' here would
# change its semantics and could turn recoverable warnings into terminating errors.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Poller   = Join-Path $RepoRoot ".agents\scripts\inbox-poller.ps1"
$FakeCli  = Join-Path $Here "fake-opencode.ps1"
$TempBase = Join-Path $env:TEMP "agent-hq-tests"

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

# --- environment isolation -------------------------------------------------

function Set-CaseEnv {
    param([string]$Root, [string]$Mode, [string]$JobTimeout)
    $env:AGENT_HQ_ROOT     = $Root
    $env:AGENT_HQ_OPENCODE = $FakeCli
    $env:FAKE_OPENCODE_MODE = $Mode
    if ([string]::IsNullOrEmpty($JobTimeout)) {
        Remove-Item -Path "Env:\AGENT_HQ_JOB_TIMEOUT" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_JOB_TIMEOUT = $JobTimeout
    }
}

function Clear-CaseEnv {
    foreach ($name in @("AGENT_HQ_ROOT", "AGENT_HQ_OPENCODE", "FAKE_OPENCODE_MODE", "AGENT_HQ_JOB_TIMEOUT")) {
        Remove-Item -Path ("Env:\" + $name) -ErrorAction SilentlyContinue
    }
}

function New-CaseRoot {
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
    foreach ($rel in @(".memory\inbox\testagent", ".memory\outbox", ".memory\dead-letter",
                       ".memory\archive", ".memory\traces", ".agents\tasks")) {
        New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null
    }
    return $root
}

function New-InboxMessage {
    param([string]$Root)
    $id = "test-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $message = [ordered]@{
        id       = $id
        from     = "team-lead"
        to       = "testagent"
        type     = "task"
        priority = "normal"
        payload  = "do stuff"
    }
    $json = $message | ConvertTo-Json -Compress
    $inboxFile = Join-Path $Root (".memory\inbox\testagent\" + $id + ".json")
    [System.IO.File]::WriteAllText($inboxFile, $json, $script:Utf8NoBom)
    return $id
}

function Invoke-PollerOnce {
    # Capture every stream (Write-Host is stream 6 in PS 5.1) so case output stays clean.
    $null = & $Poller -Once *>&1
}

# --- cases -----------------------------------------------------------------

function Test-CaseSuccess {
    param([string]$Root)
    Set-CaseEnv -Root $Root -Mode "success"
    $id = New-InboxMessage -Root $Root
    Invoke-PollerOnce

    $all = $true

    $outboxFile = Join-Path $Root (".memory\outbox\" + $id + ".json")
    $outboxExists = Test-PathLeaf $outboxFile
    $all = (Write-Check ("outbox\" + $id + ".json created") $outboxExists) -and $all
    if ($outboxExists) {
        $msg = Read-JsonFile $outboxFile
        $all = (Write-Check "outbox status = done" ($msg.status -eq "done")) -and $all
        $all = (Write-Check "outbox id matches inbox id" ($msg.id -eq $id)) -and $all
        $evField = [string]$msg.evidence
        $evExpected = ".memory/evidence/" + $id + ".json"
        $evFieldOk = ($evField -eq $evExpected -and (Test-PathLeaf (Join-Path $Root ($evField -replace '/', '\'))))
        $all = (Write-Check "outbox evidence points at evidence file" $evFieldOk) -and $all
    }

    $archiveCount = Get-JsonFileCount (Join-Path $Root ".memory\archive")
    $all = (Write-Check "archive holds the consumed message (>=1 file)" ($archiveCount -ge 1)) -and $all

    $dlCount = Get-JsonFileCount (Join-Path $Root ".memory\dead-letter")
    $all = (Write-Check "dead-letter is empty" ($dlCount -eq 0)) -and $all

    # P0-C: machine-generated evidence assertions
    $evidenceFile = Join-Path $Root (".memory\evidence\" + $id + ".json")
    $evExists = Test-PathLeaf $evidenceFile
    $all = (Write-Check ("evidence\" + $id + ".json created") $evExists) -and $all
    if ($evExists) {
        $ev = Read-JsonFile $evidenceFile
        $attempts = @($ev.attempts)
        $all = (Write-Check "evidence task_id matches" ($ev.task_id -eq $id)) -and $all
        $successList = @($attempts | Where-Object { $_.status -eq "success" })
        $all = (Write-Check "evidence has a success attempt" ($successList.Count -ge 1)) -and $all
        if ($successList.Count -ge 1) {
            $sa = $successList[0]
            $all = (Write-Check "success attempt exit_code = 0" ($sa.exit_code -eq 0)) -and $all
            $all = (Write-Check "success attempt stdout_sha256 is 64-hex" ($sa.stdout_sha256 -match '^[0-9a-f]{64}$')) -and $all
            $all = (Write-Check "success attempt stdout_length > 0" ($sa.stdout_length -gt 0)) -and $all
        }
        $firstAttempt = @($attempts)[0]
        $all = (Write-Check "evidence git_head is a string" ($null -ne $firstAttempt.git_head -and $firstAttempt.git_head -is [string])) -and $all
        $all = (Write-Check "evidence git_diff_sha256 is a string" ($null -ne $firstAttempt.git_diff_sha256 -and $firstAttempt.git_diff_sha256 -is [string])) -and $all
    }

    return $all
}

function Test-FailureCase {
    param([string]$Root, [string]$Mode, [string]$ReasonPattern, [string]$JobTimeout)
    Set-CaseEnv -Root $Root -Mode $Mode -JobTimeout $JobTimeout
    $id = New-InboxMessage -Root $Root
    Invoke-PollerOnce

    $all = $true

    $outboxCount = Get-JsonFileCount (Join-Path $Root ".memory\outbox")
    $all = (Write-Check "outbox contains no done result" ($outboxCount -eq 0)) -and $all

    $dlFile = Join-Path $Root (".memory\dead-letter\" + $id + ".json")
    $dlExists = Test-PathLeaf $dlFile
    $all = (Write-Check ("dead-letter\" + $id + ".json created") $dlExists) -and $all
    if ($dlExists) {
        $msg = Read-JsonFile $dlFile
        $all = (Write-Check "dead-letter status = failed" ($msg.status -eq "failed")) -and $all
        $reasonOk = ([string]$msg.response -match $ReasonPattern)
        $all = (Write-Check ("reason matches /" + $ReasonPattern + "/") $reasonOk) -and $all
        $all = (Write-Check "dead-letter evidence field present" (-not [string]::IsNullOrWhiteSpace([string]$msg.evidence))) -and $all
    }

    # P0-C: machine-generated evidence assertions
    $evidenceFile = Join-Path $Root (".memory\evidence\" + $id + ".json")
    $evExists = Test-PathLeaf $evidenceFile
    $all = (Write-Check ("evidence\" + $id + ".json created") $evExists) -and $all
    $failedAttempt = $null
    if ($evExists) {
        $ev = Read-JsonFile $evidenceFile
        $attempts = @($ev.attempts)
        $all = (Write-Check "evidence task_id matches" ($ev.task_id -eq $id)) -and $all
        $failedList = @($attempts | Where-Object { $_.status -eq "failed" })
        $all = (Write-Check "evidence has a failed attempt" ($failedList.Count -ge 1)) -and $all
        if ($failedList.Count -ge 1) { $failedAttempt = $failedList[0] }
        if ($null -ne $failedAttempt) {
            $all = (Write-Check "failed attempt has a reason" (-not [string]::IsNullOrWhiteSpace([string]$failedAttempt.reason))) -and $all
        }
        $firstAttempt = @($attempts)[0]
        $all = (Write-Check "evidence git_head is a string" ($null -ne $firstAttempt.git_head -and $firstAttempt.git_head -is [string])) -and $all
        $all = (Write-Check "evidence git_diff_sha256 is a string" ($null -ne $firstAttempt.git_diff_sha256 -and $firstAttempt.git_diff_sha256 -is [string])) -and $all
    }

    if ($null -ne $failedAttempt -and $Mode -eq "exit1") {
        $all = (Write-Check "exit1 failed attempt exit_code = 1" ($failedAttempt.exit_code -eq 1)) -and $all
    }

    return $all
}

# P0-D: agent output containing secrets must be redacted before it reaches the bus.
function Test-RedactionCase {
    param([string]$Root)
    Set-CaseEnv -Root $Root -Mode "leak"
    $id = New-InboxMessage -Root $Root
    Invoke-PollerOnce

    $all = $true

    $outboxCount = Get-JsonFileCount (Join-Path $Root ".memory\outbox")
    $all = (Write-Check "outbox contains no done result" ($outboxCount -eq 0)) -and $all

    $dlFile = Join-Path $Root (".memory\dead-letter\" + $id + ".json")
    $dlExists = Test-PathLeaf $dlFile
    $all = (Write-Check ("dead-letter\" + $id + ".json created") $dlExists) -and $all
    if ($dlExists) {
        $raw = Get-Content -LiteralPath $dlFile -Raw -Encoding UTF8
        # Expected raw values are rebuilt at runtime (no literal secret in this file).
        $fakeToken = "dummy" + "_token_" + "ABCDEFGHIJKLMNOP"
        $fakeSk    = "s" + "k-" + "ABCDEFGHIJKLMNOPQRSTUVWX"
        $all = (Write-Check "dead-letter has no raw key=value secret" (-not ($raw.Contains($fakeToken)))) -and $all
        $all = (Write-Check "dead-letter has no raw sk- key" (-not ($raw.Contains($fakeSk)))) -and $all
        $all = (Write-Check "dead-letter contains [REDACTED]" ($raw.Contains("[REDACTED]"))) -and $all
        $msg = Read-JsonFile $dlFile
        $all = (Write-Check "dead-letter status = failed" ($msg.status -eq "failed")) -and $all
    }

    return $all
}

# P0-D (regex refine): Redact-Secrets is a pure function, so it is exercised
# directly instead of through the poller. It must leave ordinary go-to-code
# alone while still masking real key=value credentials.
function Test-RedactionRegexCase {
    $all = $true
    $redactPath = Join-Path $RepoRoot ".agents\scripts\redact.ps1"
    $redactExists = Test-PathLeaf $redactPath
    $all = (Write-Check "redact.ps1 exists" $redactExists) -and $all
    if (-not $redactExists) { return $all }

    . $redactPath

    # False positive: the value is a call expression -> must stay untouched.
    # The string is assembled at runtime so this file holds no literal secret.
    $goTo = "const " + "api" + "Key = get" + "Api" + "Key();"
    $goToOut = Redact-Secrets $goTo
    $all = (Write-Check "go-to code 'apiKey = getApiKey()' is NOT redacted" ($goToOut -eq $goTo)) -and $all

    # True positive: a real key=value credential must still be masked.
    $secret = "abc" + "123" + "def456"
    $rawKey = "api" + "_" + "key=" + $secret
    $keyOut = Redact-Secrets $rawKey
    $keyMasked = ((-not $keyOut.Contains($secret)) -and $keyOut.Contains("[REDACTED]"))
    $all = (Write-Check "api_key=<secret> IS redacted" $keyMasked) -and $all

    # Well-known shapes must not be weakened by the refinement.
    $rawSk = "s" + "k-" + "ABCDEFGHIJKLMNOPQRSTUVWX"
    $skOut = Redact-Secrets $rawSk
    $all = (Write-Check "sk- key is still redacted" (-not $skOut.Contains($rawSk))) -and $all

    # Idempotence: redacting an already redacted string changes nothing.
    $all = (Write-Check "Redact-Secrets is idempotent" ((Redact-Secrets $keyOut) -eq $keyOut)) -and $all

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

Write-Host "=== agent-hq inbox-poller pipeline tests ==="
Write-Host ("Poller : " + $Poller)
Write-Host ("FakeCLI: " + $FakeCli)

if (-not (Test-PathLeaf $Poller))  { Write-Host ("FATAL: poller not found: " + $Poller);  exit 1 }
if (-not (Test-PathLeaf $FakeCli)) { Write-Host ("FATAL: fake CLI not found: " + $FakeCli); exit 1 }

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

Invoke-Case "a) success -> outbox done + archive, empty dead-letter" { param($r) Test-CaseSuccess -Root $r }
Invoke-Case "b) nomarker -> dead-letter (missing success marker)"    { param($r) Test-FailureCase -Root $r -Mode "nomarker"    -ReasonPattern "success marker" }
Invoke-Case "c) exit1 -> dead-letter (exit code)"                    { param($r) Test-FailureCase -Root $r -Mode "exit1"       -ReasonPattern "exit code 1(?![0-9])" }
Invoke-Case "d) empty -> dead-letter (empty stdout)"                 { param($r) Test-FailureCase -Root $r -Mode "empty"       -ReasonPattern "empty stdout" }
Invoke-Case "e) stderr-only -> dead-letter (empty stdout)"           { param($r) Test-FailureCase -Root $r -Mode "stderr-only" -ReasonPattern "empty stdout" }
Invoke-Case "f) errormarker -> dead-letter (error marker)"           { param($r) Test-FailureCase -Root $r -Mode "errormarker" -ReasonPattern "error marker" }
Invoke-Case "g) timeout -> dead-letter (timeout/124)"                { param($r) Test-FailureCase -Root $r -Mode "timeout"     -ReasonPattern "124|TIMEOUT" -JobTimeout "3" }
Invoke-Case "h) leak -> redacted in dead-letter"                     { param($r) Test-RedactionCase -Root $r }
Invoke-Case "i) redaction regex -> go-to code kept, secrets masked"  { Test-RedactionRegexCase }

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

# Best-effort cleanup of the shared temp base (cases already removed their own roots).
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
