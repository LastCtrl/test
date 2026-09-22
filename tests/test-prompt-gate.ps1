# test-prompt-gate.ps1 - self-test for P1-5 (prompt-gate: scrub + human approval).
#
# Pure PowerShell 5.1 (no Pester). Every case runs against an isolated
# $env:AGENT_HQ_ROOT under %TEMP%, so the repository .memory is never touched.
# Exit code: 0 when every case passes, 1 when at least one case fails.
#
# IMPORTANT: this file contains NO literal secret. The fake credential is
# assembled at runtime by concatenation, so the repo pre-commit scanner
# (sk-/token/password patterns) is not triggered by this fixture.
#
# NOTE: the gate is invoked with EXPLICIT parameter names (never by array
# splatting): in PowerShell 5.1 @array splatting binds positionally, which
# silently maps `-Scrub` onto the first string parameter.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Gate     = Join-Path $RepoRoot ".agents\scripts\prompt-gate.ps1"
$Mq       = Join-Path $RepoRoot ".agents\scripts\message-queue.ps1"
$TestBase = Join-Path $env:TEMP "agent-hq-test-prompt-gate"

$script:Pass = 0
$script:Fail = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- helpers ---------------------------------------------------------------

function Add-Check {
    param([string]$Id, [bool]$Ok, [string]$Note)
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $label = if ($Ok) { "PASS" } else { "FAIL" }
    Write-Host ("[{0}] {1} - {2}" -f $label, $Id, $Note)
}

function New-IsolatedRoot {
    $root = Join-Path $TestBase ([guid]::NewGuid().ToString("N"))
    foreach ($rel in @(".memory\outbox", ".memory\inbox\testagent", ".memory\dead-letter",
                       ".memory\approvals\pending", ".memory\approvals\approved")) {
        New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null
    }
    $env:AGENT_HQ_ROOT = $root
    return $root
}

function End-IsolatedRoot {
    param([string]$Root)
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Capture {
    # In-process call of a child script; `exit N` inside it sets $LASTEXITCODE
    # for the caller (Write-Host is stream 6 in PS 5.1, hence *>&1).
    param([scriptblock]$Body)
    $out = & $Body *>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

function Get-OnlyFile {
    param([string]$Dir, [string]$Filter)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return $null }
    return $files[0]
}

function Get-JsonCount {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

function Get-ApprovalId {
    param([string]$Root)
    $f = Get-OnlyFile -Dir (Join-Path $Root ".memory\approvals\pending") -Filter '*.json'
    if ($null -eq $f) { return "" }
    return $f.BaseName
}

# --- fixtures (no literal secrets) ----------------------------------------

$FakeSecret  = "s" + "k-" + "ABCDEFGHIJKLMNOPQRSTUVWX"   # matches sk-[A-Za-z0-9]{16,}
$RiskyPrompt = "rm -rf " + "/tmp/agent-hq-fixture"
$RiskyReg    = "reg add " + "HKLM" + "\Software\AgentHqTest /v X /t REG_SZ /d y"
$Benign      = "just a benign task: read the file and report"

# Secret-shaped assignment whose VALUE is a destructive command. Scrub masks the
# value ("rm" -> [REDACTED]), so the destructive shape disappears from the
# scrubbed text; the risk-scan must therefore also inspect the ORIGINAL text.
# Assembled by concatenation so no literal "password=..." hits the repo scanner.
$SecretMaskedRisky = "pass" + "word=" + "rm" + " -rf " + "/var/tmp/qa-x"

# --- main -----------------------------------------------------------------

Write-Host "=== agent-hq prompt-gate (P1-5) tests ==="
Write-Host ("Gate: " + $Gate)
Write-Host ("Mq  : " + $Mq)

if (-not (Test-Path -LiteralPath $Gate -PathType Leaf)) { Write-Host ("FATAL: not found: " + $Gate); exit 1 }
if (-not (Test-Path -LiteralPath $Mq -PathType Leaf))   { Write-Host ("FATAL: not found: " + $Mq);   exit 1 }
New-Item -ItemType Directory -Path $TestBase -Force | Out-Null

$riskyId = ""

try {

    # --- C1: benign prompt passes through unchanged ------------------------
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Gate -Scrub -Text $Benign }
        $unchanged = ($r.Out.Trim() -eq $Benign)
        # the dot-source guard must also prevent the legacy G1..G6 run
        $noLegacyReport = -not (Test-Path -LiteralPath (Join-Path $root "temp_prompt_gate_report.txt"))
        $noPending = (Get-JsonCount (Join-Path $root ".memory\approvals\pending")) -eq 0
        Add-Check 'C1-benign-passthrough' (($r.Exit -eq 0) -and $unchanged -and $noLegacyReport -and $noPending) `
            ("exit=$($r.Exit) unchanged=$unchanged legacyReportAbsent=$noLegacyReport pending=0:$noPending")
    } finally { End-IsolatedRoot $root }

    # --- C2: secret is redacted, prompt still passes (default policy) ------
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Gate -Scrub -Text ("deploy with credential " + $FakeSecret) }
        $hasRedacted = $r.Out.Contains("[REDACTED]")
        $leaks = $r.Out.Contains($FakeSecret)
        Add-Check 'C2-scrub-redacts-secret' (($r.Exit -eq 0) -and $hasRedacted -and (-not $leaks)) `
            ("exit=$($r.Exit) hasRedacted=$hasRedacted leaksSecret=$leaks")
    } finally { End-IsolatedRoot $root }

    # --- C3: -Path mode ----------------------------------------------------
    $root = New-IsolatedRoot
    try {
        $inFile = Join-Path $root ".memory\scrub-input.txt"
        [System.IO.File]::WriteAllText($inFile, ("token " + $FakeSecret), $script:Utf8NoBom)
        $r = Invoke-Capture { & $Gate -Scrub -Path $inFile }
        $hasRedacted = $r.Out.Contains("[REDACTED]")
        $leaks = $r.Out.Contains($FakeSecret)
        Add-Check 'C3-scrub-from-file' (($r.Exit -eq 0) -and $hasRedacted -and (-not $leaks)) `
            ("exit=$($r.Exit) hasRedacted=$hasRedacted leaksSecret=$leaks")
    } finally { End-IsolatedRoot $root }

    # --- C4: -Strict turns a secret into a hard block (exit 3, no pending) --
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Gate -Scrub -Text ("secret: " + $FakeSecret) -Strict }
        $pending = Get-JsonCount (Join-Path $root ".memory\approvals\pending")
        $leaks = $r.Out.Contains($FakeSecret)
        Add-Check 'C4-strict-blocks-secret' (($r.Exit -eq 3) -and ($pending -eq 0) -and (-not $leaks)) `
            ("exit=$($r.Exit) pending=$pending leaksSecret=$leaks")
    } finally { End-IsolatedRoot $root }

    # --- C5: message-queue send scrubs the payload before it reaches outbox -
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Mq -Action send -From team-lead -To testagent -Type task -Priority normal -Payload ("credential " + $FakeSecret) }
        $f = Get-OnlyFile -Dir (Join-Path $root ".memory\outbox") -Filter '*.json'
        $hasRedacted = $false
        $leaks = $true
        $ok = ($r.Exit -eq 0) -and ($null -ne $f)
        if ($null -ne $f) {
            $raw = [System.IO.File]::ReadAllText($f.FullName, $script:Utf8NoBom)
            $hasRedacted = $raw.Contains("[REDACTED]")
            $leaks = $raw.Contains($FakeSecret)
            $ok = $ok -and $hasRedacted -and (-not $leaks)
        }
        Add-Check 'C5-queue-payload-scrubbed' $ok `
            ("exit=$($r.Exit) outboxJson=$($null -ne $f) hasRedacted=$hasRedacted leaksSecret=$leaks")
    } finally { End-IsolatedRoot $root }

    # --- C6: risky prompt is held for approval (exit 2, pending created) ----
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Gate -Scrub -Text $RiskyPrompt }
        $riskyId = Get-ApprovalId -Root $root
        $ok = ($r.Exit -eq 2) -and ($riskyId -match '^apr-[0-9a-f]{16}$')
        Add-Check 'C6-risky-requires-approval' $ok `
            ("exit=$($r.Exit) pendingId=$riskyId")
    } finally { End-IsolatedRoot $root }

    # --- C7: approval marker file unblocks the same prompt ------------------
    if ($riskyId -ne "") {
        $root = New-IsolatedRoot
        try {
            $r1 = Invoke-Capture { & $Gate -Scrub -Text $RiskyPrompt }
            $id = Get-ApprovalId -Root $root
            # the documented "approved file" contract: an <id> marker in approved/
            [System.IO.File]::WriteAllText((Join-Path $root (".memory\approvals\approved\" + $id)), "", $script:Utf8NoBom)
            $r2 = Invoke-Capture { & $Gate -Scrub -Text $RiskyPrompt }
            $unchanged = ($r2.Out.Trim() -eq $RiskyPrompt)
            $ok = ($id -eq $riskyId) -and ($r1.Exit -eq 2) -and ($r2.Exit -eq 0) -and $unchanged
            Add-Check 'C7-approved-marker-passes' $ok `
                ("firstExit=$($r1.Exit) afterApproveExit=$($r2.Exit) idStable=$($id -eq $riskyId) unchanged=$unchanged")
        } finally { End-IsolatedRoot $root }
    } else {
        Add-Check 'C7-approved-marker-passes' $false 'skipped: no approval id from C6'
    }

    # --- C8: CLI -Approve moves pending -> approved -------------------------
    $root = New-IsolatedRoot
    try {
        $null = Invoke-Capture { & $Gate -Scrub -Text $RiskyReg }
        $id = Get-ApprovalId -Root $root
        $rApprove = Invoke-Capture { & $Gate -Approve $id }
        $approvedFile = Join-Path $root (".memory\approvals\approved\" + $id + ".json")
        $approvedExists = Test-Path -LiteralPath $approvedFile -PathType Leaf
        $rAfter = Invoke-Capture { & $Gate -Scrub -Text $RiskyReg }
        $ok = ($id -ne "") -and ($rApprove.Exit -eq 0) -and $approvedExists -and
              ((Get-JsonCount (Join-Path $root ".memory\approvals\pending")) -eq 0) -and
              ($rAfter.Exit -eq 0) -and ($rAfter.Out.Trim() -eq $RiskyReg)
        Add-Check 'C8-cli-approve' $ok `
            ("id=$id approveExit=$($rApprove.Exit) approvedFile=$approvedExists afterExit=$($rAfter.Exit)")
    } finally { End-IsolatedRoot $root }

    # --- C9: approve rejects unknown / malformed ids ------------------------
    $root = New-IsolatedRoot
    try {
        $rUnknown = Invoke-Capture { & $Gate -Approve 'apr-0000000000000000' }
        $rTraversal = Invoke-Capture { & $Gate -Approve '../../evil' }
        $rShort = Invoke-Capture { & $Gate -Approve 'apr-zz' }
        Add-Check 'C9-approve-rejects-bad-id' (($rUnknown.Exit -eq 1) -and ($rTraversal.Exit -eq 1) -and ($rShort.Exit -eq 1)) `
            ("unknownExit=$($rUnknown.Exit) traversalExit=$($rTraversal.Exit) malformedExit=$($rShort.Exit)")
    } finally { End-IsolatedRoot $root }

    # --- C10: message-queue blocks a risky payload (no outbox artefact) -----
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Mq -Action send -From team-lead -To testagent -Type task -Priority normal -Payload $RiskyPrompt }
        $outboxCount = Get-JsonCount (Join-Path $root ".memory\outbox")
        $pendingId = Get-ApprovalId -Root $root
        Add-Check 'C10-queue-blocks-risky' (($r.Exit -eq 1) -and ($outboxCount -eq 0) -and ($pendingId -ne "")) `
            ("exit=$($r.Exit) outboxJson=$outboxCount pendingId=$pendingId")
    } finally { End-IsolatedRoot $root }

    # --- C11: message-queue keeps a benign payload byte-identical ----------
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Mq -Action send -From team-lead -To testagent -Type task -Priority normal -Payload $Benign }
        $f = Get-OnlyFile -Dir (Join-Path $root ".memory\outbox") -Filter '*.json'
        $payloadOk = $false
        $ok = ($r.Exit -eq 0) -and ($null -ne $f)
        if ($null -ne $f) {
            $obj = [System.IO.File]::ReadAllText($f.FullName, $script:Utf8NoBom) | ConvertFrom-Json
            $payloadOk = ([string]$obj.payload -ceq $Benign)
            $ok = $ok -and $payloadOk
        }
        Add-Check 'C11-queue-benign-untouched' $ok `
            ("exit=$($r.Exit) payloadIdentical=$payloadOk")
    } finally { End-IsolatedRoot $root }

    # --- C12: usage / empty-input edge cases -------------------------------
    $root = New-IsolatedRoot
    try {
        $rUsage = Invoke-Capture { & $Gate -Scrub }
        Add-Check 'C12a-scrub-usage-error' ($rUsage.Exit -eq 1) "exit=$($rUsage.Exit) (no -Text/-Path)"

        $rEmpty = Invoke-Capture { & $Gate -Scrub -Text '' }
        Add-Check 'C12b-scrub-empty-text' (($rEmpty.Exit -eq 0) -and ($rEmpty.Out.Trim() -eq '')) `
            ("exit=$($rEmpty.Exit) emptyOutput=$($rEmpty.Out.Trim() -eq '')")

        $rMissing = Invoke-Capture { & $Gate -Scrub -Path (Join-Path $root "no-such-file.md") }
        Add-Check 'C12c-scrub-missing-file' ($rMissing.Exit -eq 1) "exit=$($rMissing.Exit)"
    } finally { End-IsolatedRoot $root }

    # --- C13: a secret-shaped value must not hide a destructive command ------
    # Regression for the P1-5 minor defect: scrub masks "rm" as the value of
    # "password=...", so a risk-scan over the scrubbed text alone would miss the
    # destructive shape. The gate must scan BOTH texts -> hold for approval.
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Gate -Scrub -Text $SecretMaskedRisky }
        $pendingId = Get-ApprovalId -Root $root
        $pendingFile = Get-OnlyFile -Dir (Join-Path $root ".memory\approvals\pending") -Filter '*.json'
        $reasonsOk = $false
        $noRawSecret = $true
        if ($null -ne $pendingFile) {
            $raw = [System.IO.File]::ReadAllText($pendingFile.FullName, $script:Utf8NoBom)
            $obj = $raw | ConvertFrom-Json
            # pending carries label-only reasons, never the raw destructive text
            $reasonsOk = (@($obj.reasons) -contains 'rm-rf')
            $noRawSecret = (-not $raw.Contains("rm -rf")) -and (-not $r.Out.Contains("rm -rf"))
        } else {
            $noRawSecret = $false
        }
        Add-Check 'C13-secret-masked-risk-still-blocks' `
            (($r.Exit -eq 2) -and ($pendingId -match '^apr-[0-9a-f]{16}$') -and $reasonsOk -and $noRawSecret) `
            ("exit=$($r.Exit) pendingId=$pendingId reasonsHasRmRf=$reasonsOk noRawSecret=$noRawSecret")
    } finally { End-IsolatedRoot $root }

    # --- C14: message-queue send -Strict blocks a secret (no outbox artefact) -
    # Default policy scrubs+warns; with -Strict a secret-shaped payload must be
    # refused: exit != 0 and NOTHING written to outbox.
    $root = New-IsolatedRoot
    try {
        $r = Invoke-Capture { & $Mq -Action send -From team-lead -To testagent -Type task -Priority normal -Payload ("credential " + $FakeSecret) -Strict }
        $outboxCount = Get-JsonCount (Join-Path $root ".memory\outbox")
        $pendingCount = Get-JsonCount (Join-Path $root ".memory\approvals\pending")
        $leaks = $r.Out.Contains($FakeSecret)
        Add-Check 'C14-strict-queue-blocks-secret' (($r.Exit -eq 1) -and ($outboxCount -eq 0) -and (-not $leaks)) `
            ("exit=$($r.Exit) outboxJson=$outboxCount pending=$pendingCount leaksSecret=$leaks")
    } finally { End-IsolatedRoot $root }

} catch {
    Add-Check 'harness' $false ("unhandled exception: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $TestBase) { Remove-Item -LiteralPath $TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
