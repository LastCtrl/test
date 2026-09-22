# test-failure-conf-depth.ps1 - isolated tests for the P3 bundle
# (failure-memory.ps1 + confidence.ps1 + verification-depth.ps1).
#
# Covers: signature dedup/count/hints; KB status -> fixed; evidence attempt dedup;
# confidence on clean/failed/mixed scenarios; depth matrix risk x confidence;
# empty/broken inputs must not throw; CLI -Json validity; file invariants.
# Every case runs in its own temp root passed via -Root; the repo is never written.
# Exit code: 0 - all checks passed, 1 - at least one FAIL.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$TargetFailure  = Join-Path $RepoRoot ".agents\scripts\failure-memory.ps1"
$TargetConf     = Join-Path $RepoRoot ".agents\scripts\confidence.ps1"
$TargetDepth    = Join-Path $RepoRoot ".agents\scripts\verification-depth.ps1"
$TempBase = Join-Path $env:TEMP "agent-hq-failure-conf-depth-tests"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function New-FixtureRoot {
    param([switch]$Bare)
    $fxRoot = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fxRoot -Force | Out-Null
    if (-not $Bare) {
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\evidence") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\dead-letter") -Force | Out-Null
    }
    return $fxRoot
}

function Remove-FixtureRoot {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function New-EvidenceFixture {
    param([string]$TaskId, [string]$AttemptJson)
    return ('{"task_id":"' + $TaskId + '","attempts":[' + $AttemptJson + ']}')
}

function New-Report {
    param([string]$Stamp, [string]$Agent, [string]$Verdict, [string]$TaskTag, [string]$Status = "resolved")
    return @(
        ("[{0}] {1} -> team-lead:" -f $Stamp, $Agent)
        "TYPE: update | PRIORITY: medium"
        ("CONTENT: Review {0}. VERDICT: {1}." -f $TaskTag, $Verdict)
        "STATUS: {0}" -f $Status
        ""
    ) -join "`r`n"
}

function Add-FailureFixtureSources {
    param([string]$Path)
    $attemptDup = '{"attempt_id":"a1","agent":"dev-1","command":"run tests T1","exit_code":1,"status":"failed","reason":"timeout","started_at":"2026-09-17T10:00:00Z","finished_at":"2026-09-17T10:01:00Z"}'
    $attemptT2 = '{"attempt_id":"b1","agent":"dev-2","command":"run tests T2","exit_code":1,"status":"failed","reason":"flaky-harness","started_at":"2026-09-17T11:00:00Z","finished_at":"2026-09-17T11:02:00Z"}'
    $attemptT3 = '{"attempt_id":"c1","agent":"dev-3","command":"run tests T3","exit_code":1,"status":"failed","reason":"timeout","started_at":"2026-09-17T12:00:00Z","finished_at":"2026-09-17T12:02:00Z"}'
    Write-FixtureText (Join-Path $Path ".memory\evidence\T1.json") (New-EvidenceFixture -TaskId 'T1' -AttemptJson ($attemptDup + ',' + $attemptDup))
    Write-FixtureText (Join-Path $Path ".memory\evidence\T2.json") (New-EvidenceFixture -TaskId 'T2' -AttemptJson $attemptT2)
    Write-FixtureText (Join-Path $Path ".memory\evidence\T3.json") (New-EvidenceFixture -TaskId 'T3' -AttemptJson $attemptT3)
    $deadLetter = '{"id":"m1","from":"team-lead","to":"dev-2","type":"failed","priority":"normal","payload":"agent-hq deploy","status":"failed","startedAt":"2026-09-17T13:00:00Z","finishedAt":"2026-09-17T13:01:00Z","response":"REASON: agent-model-unknown"}'
    Write-FixtureText (Join-Path $Path ".memory\dead-letter\m1.json") $deadLetter
    $kb = @(
        "# Knowledge Base"
        "### BUG-010: legacy test harness leaks temp files"
        "- **Date**: 2026-09-10"
        "- **Severity**: major"
        "- **File**: tests/test-legacy.ps1"
        "- **Status**: FIXED (2026-09-16, dev-1) - done."
        "- **Discovered by**: qa-engineer, 2026-09-16."
        "### BUG-011: readme guide links broken"
        "- **Date**: 2026-09-16"
        "- **Severity**: minor"
        "- **File**: docs/readme-guide.md"
        "- **Status**: open (not scheduled)."
        "### BUG-012: model-router read-modify-write race"
        "- **Date**: 2026-09-16"
        "- **Severity**: major"
        "- **File**: .agents/scripts/model-router.ps1:195-236"
        "- **Status**: open (not scheduled)."
    ) -join "`r`n"
    Write-FixtureText (Join-Path $Path "KNOWLEDGE-BASE.md") $kb
    $buffer = (New-Report "2026-09-17 14:00" "qa-engineer"   "PASS"   "TASK-100") +
              (New-Report "2026-09-17 14:10" "code-reviewer" "REJECT" "TASK-100")
    Write-FixtureText (Join-Path $Path "CONTEXT-BUFFER.md") $buffer
}

function Get-EntryBySignature {
    param([object[]]$Entries, [string]$Signature)
    return ,@($Entries | Where-Object { [string]$_.signature -eq $Signature })
}

function Test-FailureMemoryCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-FailureFixtureSources -Path $fxRoot
        $summary = Invoke-FailureRecord -Root $fxRoot
        Write-Check "fm) -Record wrote registry" ($summary.wrote -and (Test-Path -LiteralPath (Join-Path $fxRoot ".memory\failure-memory.jsonl") -PathType Leaf))

        $entries = @(Get-FailureRegistryEntries -Root $fxRoot)
        Write-Check "fm) 7 unique signatures collected" ($entries.Count -eq 7)
        Write-Check "fm) 8 occurrences (duplicate attempt_id deduped)" ([int]$summary.occurrences -eq 8)

        $timeout = Get-EntryBySignature -Entries $entries -Signature 'test|timeout'
        Write-Check "fm) 'test|timeout' present exactly once" ($timeout.Count -eq 1)
        if ($timeout.Count -eq 1) {
            Write-Check "fm) 'test|timeout' count=2 (T1 deduped + T3)" ([int]$timeout[0].count -eq 2)
            Write-Check "fm) 'test|timeout' reason_code normalised without ids" ([string]$timeout[0].reason_code -eq 'timeout')
            Write-Check "fm) sample_task_id is T1" ([string]$timeout[0].sample_task_id -eq 'T1')
            Write-Check "fm) agent aggregated (dev-1 wins tie)" ([string]$timeout[0].agent -eq 'dev-1')
        }

        $dl = Get-EntryBySignature -Entries $entries -Signature 'orchestration|agent-model-unknown'
        Write-Check "fm) dead-letter reason captured" ($dl.Count -eq 1)

        $fixedKb = Get-EntryBySignature -Entries $entries -Signature 'test|kb-test-legacy-major'
        Write-Check "fm) KB FIXED bug -> fixed=true" ($fixedKb.Count -eq 1 -and [bool]$fixedKb[0].fixed -eq $true)
        $openKb = Get-EntryBySignature -Entries $entries -Signature 'docs|kb-readme-guide-minor'
        Write-Check "fm) KB open bug -> fixed=false" ($openKb.Count -eq 1 -and [bool]$openKb[0].fixed -eq $false)
        $lineKb = Get-EntryBySignature -Entries $entries -Signature 'code|kb-model-router-major'
        Write-Check "fm) KB line numbers stripped from signature" ($lineKb.Count -eq 1)
        if ($lineKb.Count -eq 1) {
            Write-Check "fm) reason_code has no digits (no unique ids)" (([string]$lineKb[0].reason_code) -notmatch '\d')
        }

        $review = Get-EntryBySignature -Entries $entries -Signature 'review|reviewer-reject'
        Write-Check "fm) reviewer reject recorded" ($review.Count -eq 1 -and [string]$review[0].sample_task_id -eq 'TASK-100')

        $hints = @(Get-FailureHints -TaskType 'test' -Root $fxRoot)
        Write-Check "fm) hints by task_type filters" ($hints.Count -eq 3 -and @($hints | Where-Object { [string]$_.task_type -ne 'test' }).Count -eq 0)
        Write-Check "fm) hints include test|timeout" (@(Get-EntryBySignature -Entries $hints -Signature 'test|timeout').Count -eq 1)

        $agentHints = @(Get-FailureHints -TaskType 'test' -AgentName 'dev-2' -Root $fxRoot)
        Write-Check "fm) hints filter by agent" ($agentHints.Count -eq 1 -and [string]$agentHints[0].signature -eq 'test|flaky-harness')
        Write-Check "fm) hints exclude other agents" (@($agentHints | Where-Object { [string]$_.agent -ne 'dev-2' }).Count -eq 0)

        $stats = Get-FailureStats -Root $fxRoot
        Write-Check "fm) stats occurrences match registry" ([int]$stats.occurrences -eq 8)
        Write-Check "fm) stats counts fixed/open" ([int]$stats.fixed_signatures -eq 1 -and [int]$stats.open_signatures -eq 6)

        $hashBefore = (Get-FileHash -LiteralPath (Join-Path $fxRoot ".memory\failure-memory.jsonl")).Hash
        Invoke-FailureRecord -Root $fxRoot | Out-Null
        $hashAfter = (Get-FileHash -LiteralPath (Join-Path $fxRoot ".memory\failure-memory.jsonl")).Hash
        Write-Check "fm) -Record is idempotent (same bytes)" ($hashBefore -eq $hashAfter)

        $entriesAfter = @(Get-FailureRegistryEntries -Root $fxRoot)
        Write-Check "fm) registry did not grow (count)" ($entriesAfter.Count -eq 7)
    } finally { Remove-FixtureRoot $fxRoot }
}

function Add-ConfidenceFixtures {
    param([string]$Path)
    $okAttempt = '{"attempt_id":"ok1","agent":"dev-1","command":"run tests CLEAN","exit_code":0,"status":"done","started_at":"2026-09-17T10:00:00Z","finished_at":"2026-09-17T10:01:00Z"}'
    $badAttempt = '{"attempt_id":"bad1","agent":"dev-1","command":"run tests FAILED","exit_code":1,"status":"failed","reason":"timeout","started_at":"2026-09-17T10:00:00Z","finished_at":"2026-09-17T10:01:00Z"}'
    Write-FixtureText (Join-Path $Path ".memory\evidence\TASK-200.json") (New-EvidenceFixture -TaskId 'TASK-200' -AttemptJson $okAttempt)
    Write-FixtureText (Join-Path $Path ".memory\evidence\TASK-201.json") (New-EvidenceFixture -TaskId 'TASK-201' -AttemptJson $badAttempt)
    Write-FixtureText (Join-Path $Path ".memory\evidence\TASK-202.json") (New-EvidenceFixture -TaskId 'TASK-202' -AttemptJson $okAttempt)
    Write-FixtureText (Join-Path $Path ".memory\evidence\TASK-204.json") '{ this is not valid json '
    $buffer = (New-Report "2026-09-17 14:00" "qa-engineer"   "PASS"   "TASK-200") +
              (New-Report "2026-09-17 14:10" "qa-engineer"   "PASS"   "TASK-201") +
              (New-Report "2026-09-17 14:20" "code-reviewer" "REJECT" "TASK-201") +
              (New-Report "2026-09-17 14:30" "qa-engineer"   "PASS"   "TASK-202") +
              (New-Report "2026-09-17 14:40" "code-reviewer" "REJECT" "TASK-202")
    Write-FixtureText (Join-Path $Path "CONTEXT-BUFFER.md") $buffer
}

function Test-ConfidenceCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-ConfidenceFixtures -Path $fxRoot

        $clean = Get-TaskConfidence -TaskId 'TASK-200' -Root $fxRoot
        Write-Check "conf) clean task = high" ([double]$clean.confidence -ge 0.75 -and [string]$clean.level -eq 'high')
        Write-Check "conf) clean task has accept factor" (@($clean.factors) -contains 'reviewer-accepted')

        $failed = Get-TaskConfidence -TaskId 'TASK-201' -Root $fxRoot
        Write-Check "conf) failed task = low" ([double]$failed.confidence -lt 0.40 -and [string]$failed.level -eq 'low')
        Write-Check "conf) failed task factors" ((@($failed.factors) -contains 'failed-attempts=1') -or (@($failed.factors) -contains 'all-attempts-failed'))

        $mixed = Get-TaskConfidence -TaskId 'TASK-202' -Root $fxRoot
        Write-Check "conf) mixed verdicts <= 0.74" ([double]$mixed.confidence -le 0.74)
        Write-Check "conf) mixed verdict factor present" (@($mixed.factors) -contains 'mixed-verdicts')
        Write-Check "conf) mixed verdict not high" ([string]$mixed.level -ne 'high')

        $noEvidence = Get-TaskConfidence -TaskId 'TASK-203' -Root $fxRoot
        Write-Check "conf) missing evidence factor" (@($noEvidence.factors) -contains 'evidence-missing')
        Write-Check "conf) missing evidence below 1.0" ([double]$noEvidence.confidence -lt 1.0)

        $malformed = Get-TaskConfidence -TaskId 'TASK-204' -Root $fxRoot
        Write-Check "conf) malformed evidence detected" ([bool]$malformed.evidence_malformed -and (@($malformed.factors) -contains 'evidence-malformed'))

        $noTask = Get-TaskConfidence -TaskId '' -Root $fxRoot
        Write-Check "conf) empty task id -> 0/low" ([double]$noTask.confidence -eq 0.0 -and [string]$noTask.level -eq 'low')

        $badGuard = Get-TaskConfidence -TaskId '..\evil' -Root $fxRoot
        Write-Check "conf) path guard rejects unsafe id" (@($badGuard.factors) -contains 'taskIdRejectedByGuard')
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-DepthMatrixCase {
    $fxRoot = New-FixtureRoot -Bare
    try {
        $cases = @(
            @{ t = 'security'; r = 'high'; c = 0.10; expect = 'deep' },
            @{ t = 'security'; r = 'high'; c = 0.90; expect = 'standard' },
            @{ t = 'code';     r = 'med';  c = 0.90; expect = 'light' },
            @{ t = 'docs';     r = 'low';  c = 0.90; expect = 'light' },
            @{ t = 'docs';     r = 'low';  c = 0.10; expect = 'standard' },
            @{ t = 'code';     r = 'med';  c = 0.50; expect = 'standard' },
            @{ t = 'security'; r = 'medium'; c = 0.10; expect = 'deep' }
        )
        foreach ($case in $cases) {
            $result = Get-VerificationDepth -TaskType $case.t -Risk $case.r -Confidence $case.c -Root $fxRoot
            Write-Check ("depth) " + $case.t + " risk=" + $case.r + " conf=" + $case.c + " -> " + $case.expect) ([string]$result.depth -eq $case.expect)
        }

        $defaultRisk = Get-VerificationDepth -TaskType 'security' -Confidence 0.9 -Root $fxRoot
        Write-Check "depth) security defaults to high risk" ([string]$defaultRisk.risk -eq 'high' -and [string]$defaultRisk.risk_source -eq 'default')
        $docsRisk = Get-VerificationDepth -TaskType 'docs' -Confidence 0.9 -Root $fxRoot
        Write-Check "depth) docs defaults to low risk" ([string]$docsRisk.risk -eq 'low')

        $invalid = Get-VerificationDepth -TaskType 'code' -Risk 'bogus' -Confidence 0.5 -Root $fxRoot
        Write-Check "depth) invalid risk falls back with factor" ([string]$invalid.risk_source -eq 'default-invalid-input' -and (@($invalid.factors) -contains 'riskInvalidFellBackToDefault'))

        $assumed = Get-VerificationDepth -TaskType 'code' -Root $fxRoot
        Write-Check "depth) no confidence -> assumed 0.5" ([double]$assumed.confidence -eq 0.5 -and (@($assumed.factors) -contains 'confidence-assumed-0.5'))

        $clamped = Get-VerificationDepth -TaskType 'code' -Confidence 5 -Root $fxRoot
        Write-Check "depth) confidence clamped to 1.0" ([double]$clamped.confidence -eq 1.0 -and (@($clamped.factors) -contains 'confidence-clamped-high'))
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-DepthFailureBumpCase {
    $fxRoot = New-FixtureRoot
    try {
        $line = '{"signature":"security|kb-hardening-major","task_type":"security","agent":"dev-1","model":"","reason_code":"kb-hardening-major","first_seen":"2026-09-16T00:00:00","last_seen":"2026-09-16T00:00:00","count":1,"sample_task_id":"BUG-099","fixed":false}'
        Write-FixtureText (Join-Path $fxRoot ".memory\failure-memory.jsonl") ($line + "`r`n")
        $result = Get-VerificationDepth -TaskType 'security' -Risk 'high' -Confidence 0.9 -Root $fxRoot
        Write-Check "depth) open failure-memory bumps to deep" ([string]$result.depth -eq 'deep' -and [int]$result.open_failure_hints -eq 1)

        $fixedLine = '{"signature":"security|kb-hardening-major","task_type":"security","agent":"dev-1","model":"","reason_code":"kb-hardening-major","first_seen":"2026-09-16T00:00:00","last_seen":"2026-09-16T00:00:00","count":1,"sample_task_id":"BUG-099","fixed":true}'
        Write-FixtureText (Join-Path $fxRoot ".memory\failure-memory.jsonl") ($fixedLine + "`r`n")
        $resultFixed = Get-VerificationDepth -TaskType 'security' -Risk 'high' -Confidence 0.9 -Root $fxRoot
        Write-Check "depth) fixed failure-memory does not bump" ([string]$resultFixed.depth -eq 'standard' -and [int]$resultFixed.open_failure_hints -eq 0)
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-EmptyAndBrokenCase {
    $fxRoot = New-FixtureRoot -Bare
    try {
        $ok = $true
        $occurrences = $null
        $entries = $null
        $hints = $null
        try {
            $occurrences = @(Get-FailureOccurrences -Root $fxRoot)
            $entries = @(Get-FailureRegistryEntries -Root $fxRoot)
            $hints = @(Get-FailureHints -TaskType 'test' -Root $fxRoot)
            $stats = Get-FailureStats -Root $fxRoot
        } catch { $ok = $false }
        Write-Check "empty) no throw on bare root" $ok
        Write-Check "empty) zero occurrences/entries/hints" ($ok -and $occurrences.Count -eq 0 -and $entries.Count -eq 0 -and $hints.Count -eq 0)

        $recordOk = $true
        $summary = $null
        try { $summary = Invoke-FailureRecord -Root $fxRoot } catch { $recordOk = $false }
        Write-Check "empty) -Record on bare root does not throw" $recordOk
        Write-Check "empty) -Record reports 0 signatures" ($recordOk -and [int]$summary.signatures -eq 0)
    } finally { Remove-FixtureRoot $fxRoot }

    $brokenRoot = New-FixtureRoot
    try {
        Write-FixtureText (Join-Path $brokenRoot ".memory\evidence\bad.json") '{ not json at all '
        Write-FixtureText (Join-Path $brokenRoot ".memory\dead-letter\broken.json") '<<<>>>'
        Write-FixtureText (Join-Path $brokenRoot "KNOWLEDGE-BASE.md") "### BUG-999 broken\n- **Severity**:\n"
        [System.IO.File]::WriteAllBytes((Join-Path $brokenRoot "CONTEXT-BUFFER.md"), (New-Object byte[] 256))
        $ok = $true
        try { $occurrences = @(Get-FailureOccurrences -Root $brokenRoot) } catch { $ok = $false }
        Write-Check "broken) evidence/KB/buffer do not throw" $ok
        Write-Check "broken) malformed evidence yields no fake failures" (@($occurrences | Where-Object { [string]$_.source -eq 'evidence' }).Count -eq 0)

        $recordOk = $true
        try { Invoke-FailureRecord -Root $brokenRoot | Out-Null } catch { $recordOk = $false }
        Write-Check "broken) -Record survives broken inputs" $recordOk

        $result = Get-VerificationDepth -TaskType 'code' -Root $brokenRoot
        Write-Check "broken) depth still returns a recommendation" ([string]$result.depth -ne '')
    } finally { Remove-FixtureRoot $brokenRoot }
}

function Test-CliJsonCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-FailureFixtureSources -Path $fxRoot
        & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetFailure -Record -Root $fxRoot | Out-Null
        Write-Check "cli) -Record exit 0" ($LASTEXITCODE -eq 0)

        $listText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetFailure -List -Json -Root $fxRoot 2>&1 | Out-String
        $listExit = $LASTEXITCODE
        $listParsed = $null
        $listOk = $true
        try { $listParsed = $listText | ConvertFrom-Json } catch { $listOk = $false }
        Write-Check "cli) -List -Json exit 0" ($listExit -eq 0)
        Write-Check "cli) -List -Json valid JSON array" ($listOk -and @($listParsed).Count -eq 7)

        $statsText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetFailure -Stats -Json -Root $fxRoot 2>&1 | Out-String
        $statsParsed = $null
        $statsOk = $true
        try { $statsParsed = $statsText | ConvertFrom-Json } catch { $statsOk = $false }
        Write-Check "cli) -Stats -Json valid JSON" ($statsOk -and [int]$statsParsed.signatures -eq 7)

        $hintsText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetFailure -Hints -TaskType test -Json -Root $fxRoot 2>&1 | Out-String
        $hintsParsed = $null
        $hintsOk = $true
        try { $hintsParsed = $hintsText | ConvertFrom-Json } catch { $hintsOk = $false }
        Write-Check "cli) -Hints -Json valid JSON" ($hintsOk -and @($hintsParsed).Count -ge 1)

        Add-ConfidenceFixtures -Path $fxRoot
        $confText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetConf -TaskId TASK-200 -Json -Root $fxRoot 2>&1 | Out-String
        $confParsed = $null
        $confOk = $true
        try { $confParsed = $confText | ConvertFrom-Json } catch { $confOk = $false }
        Write-Check "cli) confidence -Json valid" ($confOk -and [double]$confParsed.confidence -ge 0.75)

        $depthText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetDepth -TaskType security -Risk high -Confidence 0.1 -Json -Root $fxRoot 2>&1 | Out-String
        $depthParsed = $null
        $depthOk = $true
        try { $depthParsed = $depthText | ConvertFrom-Json } catch { $depthOk = $false }
        Write-Check "cli) depth -Json valid" ($depthOk -and [string]$depthParsed.depth -eq 'deep')

        $depthAutoText = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetDepth -TaskType code -TaskId TASK-200 -Json -Root $fxRoot 2>&1 | Out-String
        $autoExit = $LASTEXITCODE
        $autoParsed = $null
        $autoOk = $true
        try { $autoParsed = $depthAutoText | ConvertFrom-Json } catch { $autoOk = $false }
        Write-Check "cli) depth -TaskId -Json valid, confidence measured" ($autoExit -eq 0 -and $autoOk -and ([string]$autoParsed.confidence_source -eq 'task:TASK-200'))
    } finally { Remove-FixtureRoot $fxRoot }

    $emptyRoot = New-FixtureRoot -Bare
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $TargetFailure -List -Json -Root $emptyRoot 2>&1 | Out-String
        Write-Check "cli) empty registry -List -Json = []" (($out.Trim()) -eq '[]')
        Write-Check "cli) empty registry exit 0" ($LASTEXITCODE -eq 0)
    } finally { Remove-FixtureRoot $emptyRoot }
}

function Test-FileInvariantsCase {
    $targets = @($TargetFailure, $TargetConf, $TargetDepth)
    foreach ($target in $targets) {
        $name = Split-Path -Leaf $target
        Write-Check ("inv) " + $name + " exists") (Test-Path -LiteralPath $target -PathType Leaf)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }

        $bytes = [System.IO.File]::ReadAllBytes($target)
        $nonAscii = 0
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $nonAscii++ }
            if ($bytes[$i] -eq 10) {
                $lf++
                if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
            }
        }
        Write-Check ("inv) " + $name + " CRLF (lone LF = 0)") (($lf - $crlf) -eq 0 -and $crlf -gt 0)
        Write-Check ("inv) " + $name + " ASCII-only (no BOM/AMSI noise)") ($nonAscii -eq 0)

        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $target -Raw), [ref]$errors)
        Write-Check ("inv) " + $name + " PSParser 0 errors") ($errors.Count -eq 0)
    }
}

# --- runner ----------------------------------------------------------------

foreach ($target in @($TargetFailure, $TargetConf, $TargetDepth)) {
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Write-Host ("FATAL: target script not found: " + $target)
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

. $TargetFailure
. $TargetConf
. $TargetDepth

$originalRoot = $env:AGENT_HQ_ROOT
try {
    Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    Write-Host "=== failure-memory + confidence + verification-depth tests ==="

    Test-FailureMemoryCase
    Test-ConfidenceCase
    Test-DepthMatrixCase
    Test-DepthFailureBumpCase
    Test-EmptyAndBrokenCase
    Test-CliJsonCase
    Test-FileInvariantsCase
} finally {
    if ([string]::IsNullOrWhiteSpace($originalRoot)) {
        Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_ROOT = $originalRoot
    }
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
