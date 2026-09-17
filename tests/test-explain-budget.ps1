# test-explain-budget.ps1 - independent tests for .agents\scripts\explain.ps1 and
# .agents\scripts\budget.ps1 (P3-3).
#
# Pure PowerShell 5.1 (no Pester). Everything runs against an ISOLATED temp root,
# exposed through $env:AGENT_HQ_ROOT / $env:AGENT_HQ_TRACES_DIR and also passed
# explicitly as -Root / -TracesDir, so the real repository is only READ.
#
# Fixture timestamps are generated relative to "now" on purpose: budget.ps1 works
# on a rolling window (-SinceHours, default 24h), so static dates would silently
# fall out of it.
#
# Covered:
#   a) syntax + line endings of both scripts
#   b) explain -TaskId        - human chronology, FAILED outcome, failure reason
#   c) explain -TaskId -Json  - machine output, counters, ASCII-only stream
#   d) explain -Agent         - attribution of a single agent
#   e) explain empty root     - no data, no crash, valid JSON
#   f) budget -Json           - run/delegation counters, per-model rollup, OK
#   g) budget -SinceHours / -Agent - window and agent filters
#   h) budget OVER            - fixture limit reached -> warning + exit 2
#   i) budget WARN            - fixture limit approaching -> warning + exit 2
#   j) budget empty root      - no data, no crash, valid JSON
#
# Exit code: 0 when every case passes, 1 when at least one fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Explain  = Join-Path $RepoRoot ".agents\scripts\explain.ps1"
$Budget   = Join-Path $RepoRoot ".agents\scripts\budget.ps1"

$TempBase  = Join-Path $env:TEMP "agent-hq-explain-budget-tests"
$Root      = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$EmptyRoot = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CheckPass = 0
$script:CheckFail = 0
$script:CasePass  = 0
$script:CaseFail  = 0

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:CheckPass++
        Write-Host ("    ok  : " + $Label)
    } else {
        $script:CheckFail++
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

function Invoke-AgentScript {
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $full = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    # stderr is dropped so the JSON on stdout stays parseable; the exit code is
    # read immediately after the pipeline.
    $text = (& $psExe @full 2>$null | Out-String)
    $code = $LASTEXITCODE
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

function Get-NonAsciiCount {
    param([string]$Text)
    return @([regex]::Matches([string]$Text, '[^\x00-\x7F]')).Count
}

function Test-TimelineMonotonic {
    param($Timeline)
    $previous = $null
    foreach ($entry in @($Timeline)) {
        $raw = [string]$entry.time
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            continue
        }
        if (($null -ne $previous) -and ($parsed -lt $previous)) { return $false }
        $previous = $parsed
    }
    return $true
}

function New-JsonLine {
    param($Object)
    return (ConvertTo-Json -InputObject $Object -Compress)
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($rel in @(
    ".memory\evidence",
    ".memory\inbox",
    ".opencode\agents",
    ".agents\config",
    ".agents\scripts",
    "traces"
)) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}
New-Item -ItemType Directory -Path $EmptyRoot -Force | Out-Null

Write-Host "=== agent-hq explain/budget tests ==="
Write-Host ("Explain : " + $Explain)
Write-Host ("Budget  : " + $Budget)
Write-Host ("Root    : " + $Root)

if (-not (Test-Path -LiteralPath $Explain -PathType Leaf)) {
    Write-Host ("FATAL: explain not found: " + $Explain)
    exit 1
}
if (-not (Test-Path -LiteralPath $Budget -PathType Leaf)) {
    Write-Host ("FATAL: budget not found: " + $Budget)
    exit 1
}

$tracesDir = Join-Path $Root "traces"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Fixture timestamps relative to now (local time for buffer/evidence, UTC for traces).
$nowUtc = (Get-Date).ToUniversalTime()
function Format-TraceIso { param([datetime]$Value) return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $invariant) }
function Format-LocalIso { param([datetime]$Value) return $Value.ToString('yyyy-MM-ddTHH:mm:ss', $invariant) }
function Format-LocalStamp { param([datetime]$Value) return $Value.ToString('yyyy-MM-dd HH:mm', $invariant) }

$tSes1  = $nowUtc.AddMinutes(-50)
$tSes4  = $nowUtc.AddHours(-2)
$tSes2  = $nowUtc.AddHours(-3)
$tSes3  = $nowUtc.AddHours(-30)
$tDeleg = $nowUtc.AddMinutes(-45)

$localNow = Get-Date
$tAtt1    = $localNow.AddHours(-5)
$tAtt2    = $localNow.AddHours(-4).AddMinutes(-50)
$tBuff1   = $localNow.AddHours(-4)
$tBuff2   = $localNow.AddHours(-3)
$tBuff3   = $localNow.AddHours(-3).AddMinutes(-30)

# --- fixture: CONTEXT-BUFFER.md (self-reports + one reviewer verdict) -------

$bufferSeparator = '=' * 80
$bufferLines = @(
    ('[' + (Format-LocalStamp $tBuff1) + '] dev-3 -> team-lead:'),
    'TYPE: update | PRIORITY: medium',
    'CONTENT: P3-9 explain fixture; evidence .memory/evidence/P3-9.json',
    'STATUS: resolved',
    $bufferSeparator,
    '',
    ('[' + (Format-LocalStamp $tBuff2) + '] qa-engineer -> team-lead:'),
    'TYPE: review | PRIORITY: high',
    'CONTENT: P3-9 verdict',
    'qa-engineer: REJECT (reason: false done)',
    'STATUS: resolved',
    $bufferSeparator,
    '',
    ('[' + (Format-LocalStamp $tBuff3) + '] dev-9 -> team-lead:'),
    'TYPE: update | PRIORITY: low',
    'CONTENT: PX-1 unrelated fixture',
    'STATUS: resolved',
    $bufferSeparator,
    ''
)
[System.IO.File]::WriteAllText((Join-Path $Root "CONTEXT-BUFFER.md"), (($bufferLines -join "`r`n") + "`r`n"), $Utf8NoBom)

# --- fixture: machine evidence ---------------------------------------------

$evidenceP39 = [ordered]@{
    task_id  = 'P3-9'
    attempts = @(
        [ordered]@{
            task_id = 'P3-9'; attempt_id = 'att-1'; agent = 'dev-3'; command = 'opencode run -m demo'
            exit_code = 0; status = 'ok'; reason = ''
            started_at = (Format-LocalIso $tAtt1); finished_at = (Format-LocalIso ($tAtt1.AddMinutes(1)))
            duration_ms = 60000; stdout_length = 4000; stderr_length = 0
        },
        [ordered]@{
            task_id = 'P3-9'; attempt_id = 'att-2'; agent = 'dev-3'; command = 'opencode run -m demo'
            exit_code = 1; status = 'failed'; reason = 'agent-timeout'
            started_at = (Format-LocalIso $tAtt2); finished_at = (Format-LocalIso ($tAtt2.AddMinutes(2)))
            duration_ms = 90000; stdout_length = 200; stderr_length = 100
        }
    )
}
[System.IO.File]::WriteAllText((Join-Path $Root ".memory\evidence\P3-9.json"),
    (ConvertTo-Json -InputObject $evidenceP39 -Depth 6), $Utf8NoBom)

$evidencePX1 = [ordered]@{
    task_id  = 'PX-1'
    attempts = @(
        [ordered]@{
            task_id = 'PX-1'; attempt_id = 'att-9'; agent = 'dev-9'; command = 'opencode run -m demo'
            exit_code = 0; status = 'ok'; reason = ''
            started_at = (Format-LocalIso ($tBuff3.AddMinutes(-20))); finished_at = (Format-LocalIso ($tBuff3.AddMinutes(-19)))
            duration_ms = 20000; stdout_length = 800; stderr_length = 0
        }
    )
}
[System.IO.File]::WriteAllText((Join-Path $Root ".memory\evidence\PX-1.json"),
    (ConvertTo-Json -InputObject $evidencePX1 -Depth 6), $Utf8NoBom)

# A deliberately broken evidence document: must be reported, never fatal.
[System.IO.File]::WriteAllText((Join-Path $Root ".memory\evidence\P3-BROKEN.json"), '{ not json', $Utf8NoBom)

# --- fixture: traces.jsonl --------------------------------------------------

$traceLines = @(
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1); type = 'session_start'; session_id = 'ses-1'; agent = 'dev-3'; task_id = 'P3-9' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1.AddSeconds(5)); type = 'tool'; tool = 'bash'; status = 'ok'; duration_ms = 1200; session_id = 'ses-1'; agent = 'dev-3'; task_id = 'P3-9'; call_id = 'c1' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1.AddSeconds(10)); type = 'tool'; tool = 'bash'; status = 'exit:1'; duration_ms = 500; session_id = 'ses-1'; agent = 'dev-3'; task_id = 'P3-9'; call_id = 'c2'; error = '' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1.AddSeconds(20)); type = 'error'; session_id = 'ses-1'; agent = 'dev-3'; task_id = 'P3-9'; message = 'provider timeout' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1.AddSeconds(30)); type = 'session_end'; session_id = 'ses-1'; agent = 'dev-3'; task_id = 'P3-9'; duration_ms = 420000 })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes4); type = 'session_start'; session_id = 'ses-4'; agent = 'dev-3'; task_id = 'P3-9' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes4.AddSeconds(5)); type = 'tool'; tool = 'read'; status = 'ok'; duration_ms = 40; session_id = 'ses-4'; agent = 'dev-3'; task_id = 'P3-9' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes2); type = 'session_start'; session_id = 'ses-2'; agent = 'dev-9'; task_id = 'PX-1' })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes2.AddSeconds(5)); type = 'tool'; tool = 'read'; status = 'ok'; duration_ms = 30; session_id = 'ses-2'; agent = 'dev-9'; task_id = 'PX-1' })),
    'not-json-line'
)
[System.IO.File]::WriteAllText((Join-Path $tracesDir "traces.jsonl"), (($traceLines -join "`n") + "`n"), $Utf8NoBom)

# --- fixture: performance.jsonl --------------------------------------------

$perfLines = @(
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes1); session_id = 'ses-1'; duration_ms = 420000; score = 90 })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes4); session_id = 'ses-4'; duration_ms = 60000; score = 95 })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes2); session_id = 'ses-2'; duration_ms = 30000; score = 100 })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tSes3); session_id = 'ses-3'; duration_ms = 15000; score = 80 })),
    (New-JsonLine ([ordered]@{ ts = (Format-TraceIso $tDeleg); type = 'delegation'; tool = 'task' }))
)
[System.IO.File]::WriteAllText((Join-Path $tracesDir "performance.jsonl"), (($perfLines -join "`n") + "`n"), $Utf8NoBom)

# --- fixture: agents + limits ----------------------------------------------

[System.IO.File]::WriteAllText((Join-Path $Root ".opencode\agents\dev-3.json"),
    (ConvertTo-Json -InputObject ([ordered]@{ name = 'dev-3'; model = 'aihubmix/gpt-5.5-free'; mode = 'subagent' }) -Depth 4), $Utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $Root ".opencode\agents\dev-9.json"),
    (ConvertTo-Json -InputObject ([ordered]@{ name = 'dev-9'; model = 'opencode/big-pickle'; mode = 'subagent' }) -Depth 4), $Utf8NoBom)

$defaultLimits = [ordered]@{
    version = 1
    models  = [ordered]@{
        'aihubmix/gpt-5.5-free' = [ordered]@{ provider = 'aihubmix'; tier = 'free'; requests_per_day = 100; tokens_per_day = 1000000; confidence = 'documented'; source = 'fixture' }
        'opencode/big-pickle'   = [ordered]@{ provider = 'opencode'; tier = 'free'; requests_per_day = 100; tokens_per_day = 1000000; confidence = 'documented'; source = 'fixture' }
    }
}
[System.IO.File]::WriteAllText((Join-Path $Root ".agents\config\model-limits.json"),
    (ConvertTo-Json -InputObject $defaultLimits -Depth 6), $Utf8NoBom)

$overLimitsPath = Join-Path $TempBase "over-limits.json"
[System.IO.File]::WriteAllText($overLimitsPath, (ConvertTo-Json -InputObject ([ordered]@{
    version = 1
    models  = [ordered]@{ 'aihubmix/gpt-5.5-free' = [ordered]@{ provider = 'aihubmix'; tier = 'free'; requests_per_day = 2; tokens_per_day = $null; confidence = 'fixture'; source = 'test fixture' } }
}) -Depth 6), $Utf8NoBom)

$warnLimitsPath = Join-Path $TempBase "warn-limits.json"
[System.IO.File]::WriteAllText($warnLimitsPath, (ConvertTo-Json -InputObject ([ordered]@{
    version = 1
    models  = [ordered]@{ 'aihubmix/gpt-5.5-free' = [ordered]@{ provider = 'aihubmix'; tier = 'free'; requests_per_day = 3; tokens_per_day = $null; confidence = 'fixture'; source = 'test fixture' } }
}) -Depth 6), $Utf8NoBom)

# --- environment isolation --------------------------------------------------

$originalRoot = $env:AGENT_HQ_ROOT
$originalTraces = $env:AGENT_HQ_TRACES_DIR
$env:AGENT_HQ_ROOT = $Root
$env:AGENT_HQ_TRACES_DIR = $tracesDir

try {
    # --- a) syntax + line endings ------------------------------------------

    Write-Host ""
    Write-Host "CASE: a) syntax and CRLF"
    $caseOk = $true
    foreach ($pair in @(
        @{ Name = 'explain.ps1'; Path = $Explain },
        @{ Name = 'budget.ps1'; Path = $Budget }
    )) {
        $raw = [System.IO.File]::ReadAllText($pair.Path, [System.Text.Encoding]::UTF8)
        $parseErrors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize($raw, [ref]$parseErrors)
        $caseOk = (Write-Check ($pair.Name + " has zero PSParser errors") ($parseErrors.Count -eq 0) ("count=" + $parseErrors.Count)) -and $caseOk
        $bareLf = @([regex]::Matches($raw, "(?<!\r)\n")).Count
        $caseOk = (Write-Check ($pair.Name + " uses CRLF only") ($bareLf -eq 0) ("bareLF=" + $bareLf)) -and $caseOk
    }
    Close-Case "a) syntax + CRLF" $caseOk

    # --- b) explain -TaskId (human) ----------------------------------------

    Write-Host ""
    Write-Host "CASE: b) explain -TaskId P3-9 (human chronology)"
    $caseOk = $true
    $explainHuman = Invoke-AgentScript -ScriptPath $Explain -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-TaskId', 'P3-9')
    $caseOk = (Write-Check "exit code is 0" ($explainHuman.code -eq 0) ("exit=" + $explainHuman.code)) -and $caseOk
    $caseOk = (Write-Check "prints the explain header" ($explainHuman.text -match '===\s*agent-hq explain\s*===')) -and $caseOk
    $caseOk = (Write-Check "outcome is FAILED" ($explainHuman.text -match 'OUTCOME\s*:\s*FAILED')) -and $caseOk
    $caseOk = (Write-Check "has a chronology section" ($explainHuman.text -match '---\s*chronology\s*\(')) -and $caseOk
    $caseOk = (Write-Check "has a 'what went wrong' section" ($explainHuman.text -match '---\s*what went wrong\s*\(')) -and $caseOk
    $caseOk = (Write-Check "carries the machine failure reason" ($explainHuman.text -match 'agent-timeout')) -and $caseOk
    $caseOk = (Write-Check "carries the trace error event" ($explainHuman.text -match 'provider timeout')) -and $caseOk
    $caseOk = (Write-Check "carries the reviewer verdict" ($explainHuman.text -match 'qa-engineer') -and ($explainHuman.text -match 'reject')) -and $caseOk
    $caseOk = (Write-Check "points at the evidence artifact" ($explainHuman.text -match 'P3-9\.json')) -and $caseOk
    $caseOk = (Write-Check "does not leak the unrelated task" (-not ($explainHuman.text -match 'PX-1'))) -and $caseOk
    Close-Case "b) explain human" $caseOk

    # --- c) explain -Json ---------------------------------------------------

    Write-Host ""
    Write-Host "CASE: c) explain -TaskId P3-9 -Json"
    $caseOk = $true
    $explainJson = Invoke-AgentScript -ScriptPath $Explain -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-TaskId', 'P3-9', '-Json')
    $caseOk = (Write-Check "exit code is 0" ($explainJson.code -eq 0) ("exit=" + $explainJson.code)) -and $caseOk
    $parsed = $null
    try { $parsed = $explainJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    $caseOk = (Write-Check "stdout is valid JSON" ($null -ne $parsed)) -and $caseOk
    $nonAscii = Get-NonAsciiCount -Text $explainJson.text
    $caseOk = (Write-Check "json stdout is pure ASCII" ($nonAscii -eq 0) ("nonAscii=" + $nonAscii)) -and $caseOk

    if ($null -ne $parsed) {
        $caseOk = (Write-Check "selector echoes the task id" ([string]$parsed.selectors.task_id -eq 'P3-9')) -and $caseOk
        $caseOk = (Write-Check "outcome is FAILED" ([string]$parsed.outcome -eq 'FAILED')) -and $caseOk
        $caseOk = (Write-Check "evidence attempts = 2" ([int]$parsed.counts.evidence_attempts -eq 2) ("got=" + $parsed.counts.evidence_attempts)) -and $caseOk
        $caseOk = (Write-Check "evidence failures = 1" ([int]$parsed.counts.evidence_failed -eq 1) ("got=" + $parsed.counts.evidence_failed)) -and $caseOk
        $caseOk = (Write-Check "self reports matched = 2" ([int]$parsed.counts.self_reports -eq 2) ("got=" + $parsed.counts.self_reports)) -and $caseOk
        $caseOk = (Write-Check "trace spans >= 6" ([int]$parsed.counts.trace_spans -ge 6) ("got=" + $parsed.counts.trace_spans)) -and $caseOk
        $caseOk = (Write-Check "verdicts = 1" ([int]$parsed.counts.verdicts -eq 1) ("got=" + $parsed.counts.verdicts)) -and $caseOk
        $caseOk = (Write-Check "timeline is non-empty" (@($parsed.timeline).Count -gt 0)) -and $caseOk
        $caseOk = (Write-Check "timeline starts with the oldest evidence attempt" (@($parsed.timeline)[0].kind -eq 'evidence') ("kind=" + @($parsed.timeline)[0].kind)) -and $caseOk
        $caseOk = (Write-Check "timeline is chronological" (Test-TimelineMonotonic -Timeline $parsed.timeline)) -and $caseOk
        $failed = @($parsed.failures | Where-Object { $_.level -eq 'FAILED' })
        $caseOk = (Write-Check "failures contain a FAILED evidence entry" (@($failed).Count -ge 1)) -and $caseOk
        $caseOk = (Write-Check "the FAILED detail carries the reason" (@($failed | Where-Object { $_.detail -match 'agent-timeout' }).Count -ge 1)) -and $caseOk
        $caseOk = (Write-Check "evidence file is reported" ([string]$parsed.evidence.file -match 'P3-9\.json')) -and $caseOk
    } else {
        $caseOk = (Write-Check "json structure could not be checked (parse failed)" $false) -and $caseOk
    }
    Close-Case "c) explain json" $caseOk

    # --- d) explain -Agent --------------------------------------------------

    Write-Host ""
    Write-Host "CASE: d) explain -Agent dev-9"
    $caseOk = $true
    $agentJson = Invoke-AgentScript -ScriptPath $Explain -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-Agent', 'dev-9', '-Json')
    $caseOk = (Write-Check "exit code is 0" ($agentJson.code -eq 0) ("exit=" + $agentJson.code)) -and $caseOk
    $agentParsed = $null
    try { $agentParsed = $agentJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $agentParsed = $null }
    $caseOk = (Write-Check "stdout is valid JSON" ($null -ne $agentParsed)) -and $caseOk
    if ($null -ne $agentParsed) {
        $caseOk = (Write-Check "selector echoes the agent" ([string]$agentParsed.selectors.agent -eq 'dev-9')) -and $caseOk
        $caseOk = (Write-Check "self reports matched = 1" ([int]$agentParsed.counts.self_reports -eq 1) ("got=" + $agentParsed.counts.self_reports)) -and $caseOk
        $caseOk = (Write-Check "evidence attempts matched = 1" ([int]$agentParsed.counts.evidence_attempts -eq 1) ("got=" + $agentParsed.counts.evidence_attempts)) -and $caseOk
        $caseOk = (Write-Check "outcome is PASSED for a clean attempt" ([string]$agentParsed.outcome -eq 'PASSED') ("got=" + $agentParsed.outcome)) -and $caseOk
    }
    Close-Case "d) explain agent" $caseOk

    # --- e) explain empty root ---------------------------------------------

    Write-Host ""
    Write-Host "CASE: e) explain on an empty root"
    $caseOk = $true
    $emptyHuman = Invoke-AgentScript -ScriptPath $Explain -Arguments @('-Root', $EmptyRoot, '-TracesDir', (Join-Path $EmptyRoot 'traces'))
    $caseOk = (Write-Check "human mode exits 0" ($emptyHuman.code -eq 0) ("exit=" + $emptyHuman.code)) -and $caseOk
    $caseOk = (Write-Check "human mode does not crash" ($emptyHuman.text -match 'agent-hq explain')) -and $caseOk
    $emptyJson = Invoke-AgentScript -ScriptPath $Explain -Arguments @('-Root', $EmptyRoot, '-TracesDir', (Join-Path $EmptyRoot 'traces'), '-Json')
    $caseOk = (Write-Check "json mode exits 0" ($emptyJson.code -eq 0) ("exit=" + $emptyJson.code)) -and $caseOk
    $emptyParsed = $null
    try { $emptyParsed = $emptyJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $emptyParsed = $null }
    $caseOk = (Write-Check "json mode stays valid" ($null -ne $emptyParsed)) -and $caseOk
    if ($null -ne $emptyParsed) {
        $caseOk = (Write-Check "outcome is NO_DATA" ([string]$emptyParsed.outcome -eq 'NO_DATA') ("got=" + $emptyParsed.outcome)) -and $caseOk
        $caseOk = (Write-Check "counts are zero" ([int]$emptyParsed.counts.evidence_attempts -eq 0 -and [int]$emptyParsed.counts.self_reports -eq 0)) -and $caseOk
    }
    Close-Case "e) explain empty root" $caseOk

    # --- f) budget -Json ----------------------------------------------------

    Write-Host ""
    Write-Host "CASE: f) budget -Json (default window and limits)"
    $caseOk = $true
    $budgetJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-Json')
    $caseOk = (Write-Check "exit code is 0 (within limits)" ($budgetJson.code -eq 0) ("exit=" + $budgetJson.code)) -and $caseOk
    $budgetParsed = $null
    try { $budgetParsed = $budgetJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $budgetParsed = $null }
    $caseOk = (Write-Check "stdout is valid JSON" ($null -ne $budgetParsed)) -and $caseOk
    $nonAscii = Get-NonAsciiCount -Text $budgetJson.text
    $caseOk = (Write-Check "json stdout is pure ASCII" ($nonAscii -eq 0) ("nonAscii=" + $nonAscii)) -and $caseOk
    if ($null -ne $budgetParsed) {
        $caseOk = (Write-Check "counts 3 runs in the 24h window" ([int]$budgetParsed.totals.runs -eq 3) ("got=" + $budgetParsed.totals.runs)) -and $caseOk
        $caseOk = (Write-Check "counts 1 delegation" ([int]$budgetParsed.totals.delegations -eq 1) ("got=" + $budgetParsed.totals.delegations)) -and $caseOk
        $caseOk = (Write-Check "reads the limits config" ([string]$budgetParsed.limits_source -eq 'config') ("got=" + $budgetParsed.limits_source)) -and $caseOk
        $caseOk = (Write-Check "no warnings" (@($budgetParsed.warnings).Count -eq 0)) -and $caseOk
        $caseOk = (Write-Check "overall level OK" ([string]$budgetParsed.overall_level -eq 'OK') ("got=" + $budgetParsed.overall_level)) -and $caseOk

        $dev3 = @($budgetParsed.by_agent | Where-Object { $_.agent -eq 'dev-3' })
        $caseOk = (Write-Check "dev-3 has 2 runs" (@($dev3).Count -eq 1 -and [int]$dev3[0].runs -eq 2)) -and $caseOk
        if (@($dev3).Count -eq 1) {
            $caseOk = (Write-Check "dev-3 maps to its configured model" ([string]$dev3[0].model -eq 'aihubmix/gpt-5.5-free') ("got=" + $dev3[0].model)) -and $caseOk
            $caseOk = (Write-Check "dev-3 token estimate is flagged and non-zero" ([bool]$dev3[0].tokens_estimated -and [int]$dev3[0].tokens -gt 0) ("tokens=" + $dev3[0].tokens)) -and $caseOk
        }
        $modelRow = @($budgetParsed.by_model | Where-Object { $_.model -eq 'aihubmix/gpt-5.5-free' })
        $caseOk = (Write-Check "model rollup has 2 requests against a 100/day limit" (@($modelRow).Count -eq 1 -and [int]$modelRow[0].runs -eq 2 -and [int]$modelRow[0].requests_per_day -eq 100)) -and $caseOk
    } else {
        $caseOk = (Write-Check "json structure could not be checked (parse failed)" $false) -and $caseOk
    }
    Close-Case "f) budget json" $caseOk

    # --- g) budget filters --------------------------------------------------

    Write-Host ""
    Write-Host "CASE: g) budget -SinceHours 1 and -Agent"
    $caseOk = $true
    $windowJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-SinceHours', '1', '-Json')
    $windowParsed = $null
    try { $windowParsed = $windowJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $windowParsed = $null }
    $caseOk = (Write-Check "-SinceHours 1 exits 0" ($windowJson.code -eq 0) ("exit=" + $windowJson.code)) -and $caseOk
    if ($null -ne $windowParsed) {
        $caseOk = (Write-Check "-SinceHours 1 keeps only 1 run" ([int]$windowParsed.totals.runs -eq 1) ("got=" + $windowParsed.totals.runs)) -and $caseOk
    } else {
        $caseOk = (Write-Check "-SinceHours 1 json parses" $false) -and $caseOk
    }

    $agentBudgetJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-Agent', 'dev-9', '-Json')
    $agentBudgetParsed = $null
    try { $agentBudgetParsed = $agentBudgetJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $agentBudgetParsed = $null }
    $caseOk = (Write-Check "-Agent exits 0" ($agentBudgetJson.code -eq 0) ("exit=" + $agentBudgetJson.code)) -and $caseOk
    if ($null -ne $agentBudgetParsed) {
        $caseOk = (Write-Check "-Agent keeps only dev-9" (@($agentBudgetParsed.by_agent).Count -eq 1 -and [string]@($agentBudgetParsed.by_agent)[0].agent -eq 'dev-9')) -and $caseOk
        $caseOk = (Write-Check "-Agent counts 1 run" ([int]$agentBudgetParsed.totals.runs -eq 1) ("got=" + $agentBudgetParsed.totals.runs)) -and $caseOk
    } else {
        $caseOk = (Write-Check "-Agent json parses" $false) -and $caseOk
    }
    Close-Case "g) budget filters" $caseOk

    # --- h) budget OVER -----------------------------------------------------

    Write-Host ""
    Write-Host "CASE: h) budget OVER warning (fixture limit 2/day, 2 runs)"
    $caseOk = $true
    $overHuman = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-LimitsPath', $overLimitsPath)
    $caseOk = (Write-Check "exit code is 2 on OVER" ($overHuman.code -eq 2) ("exit=" + $overHuman.code)) -and $caseOk
    $caseOk = (Write-Check "human output carries an OVER warning" ($overHuman.text -match 'OVER:')) -and $caseOk
    $overJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-LimitsPath', $overLimitsPath, '-Json')
    $overParsed = $null
    try { $overParsed = $overJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $overParsed = $null }
    if ($null -ne $overParsed) {
        $overWarnings = @($overParsed.warnings | Where-Object { $_.level -eq 'OVER' -and $_.scope -eq 'requests' })
        $caseOk = (Write-Check "json reports an OVER requests warning" (@($overWarnings).Count -eq 1) ("count=" + @($overWarnings).Count)) -and $caseOk
        $caseOk = (Write-Check "overall level is OVER and exit_code is 2" ([string]$overParsed.overall_level -eq 'OVER' -and [int]$overParsed.exit_code -eq 2)) -and $caseOk
    } else {
        $caseOk = (Write-Check "OVER json parses" $false) -and $caseOk
    }
    Close-Case "h) budget OVER" $caseOk

    # --- i) budget WARN -----------------------------------------------------

    Write-Host ""
    Write-Host "CASE: i) budget WARN warning (fixture limit 3/day, 2 runs, -WarnAt 0.6)"
    $caseOk = $true
    $warnHuman = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-LimitsPath', $warnLimitsPath, '-WarnAt', '0.6')
    $caseOk = (Write-Check "exit code is 2 on WARN" ($warnHuman.code -eq 2) ("exit=" + $warnHuman.code)) -and $caseOk
    $caseOk = (Write-Check "human output carries a WARN warning" ($warnHuman.text -match 'WARN:')) -and $caseOk
    $caseOk = (Write-Check "human output does not claim OVER" (-not ($warnHuman.text -match 'OVER:'))) -and $caseOk
    $warnJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $Root, '-TracesDir', $tracesDir, '-LimitsPath', $warnLimitsPath, '-WarnAt', '0.6', '-Json')
    $warnParsed = $null
    try { $warnParsed = $warnJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $warnParsed = $null }
    if ($null -ne $warnParsed) {
        $warnWarnings = @($warnParsed.warnings | Where-Object { $_.level -eq 'WARN' -and $_.scope -eq 'requests' })
        $caseOk = (Write-Check "json reports a WARN requests warning" (@($warnWarnings).Count -eq 1) ("count=" + @($warnWarnings).Count)) -and $caseOk
        $caseOk = (Write-Check "overall level is WARN and exit_code is 2" ([string]$warnParsed.overall_level -eq 'WARN' -and [int]$warnParsed.exit_code -eq 2)) -and $caseOk
    } else {
        $caseOk = (Write-Check "WARN json parses" $false) -and $caseOk
    }
    Close-Case "i) budget WARN" $caseOk

    # --- j) budget empty root ----------------------------------------------

    Write-Host ""
    Write-Host "CASE: j) budget on an empty root"
    $caseOk = $true
    $emptyBudgetHuman = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $EmptyRoot, '-TracesDir', (Join-Path $EmptyRoot 'traces'))
    $caseOk = (Write-Check "human mode exits 0" ($emptyBudgetHuman.code -eq 0) ("exit=" + $emptyBudgetHuman.code)) -and $caseOk
    $caseOk = (Write-Check "human mode reports a BUDGET verdict" ($emptyBudgetHuman.text -match 'BUDGET:\s*(OK|WARN|OVER)')) -and $caseOk
    $emptyBudgetJson = Invoke-AgentScript -ScriptPath $Budget -Arguments @('-Root', $EmptyRoot, '-TracesDir', (Join-Path $EmptyRoot 'traces'), '-Json')
    $caseOk = (Write-Check "json mode exits 0" ($emptyBudgetJson.code -eq 0) ("exit=" + $emptyBudgetJson.code)) -and $caseOk
    $emptyBudgetParsed = $null
    try { $emptyBudgetParsed = $emptyBudgetJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $emptyBudgetParsed = $null }
    $caseOk = (Write-Check "json mode stays valid" ($null -ne $emptyBudgetParsed)) -and $caseOk
    if ($null -ne $emptyBudgetParsed) {
        $caseOk = (Write-Check "zero runs on empty data" ([int]$emptyBudgetParsed.totals.runs -eq 0) ("got=" + $emptyBudgetParsed.totals.runs)) -and $caseOk
        $caseOk = (Write-Check "no warnings on empty data" (@($emptyBudgetParsed.warnings).Count -eq 0)) -and $caseOk
        $caseOk = (Write-Check "falls back to the built-in limits" ([string]$emptyBudgetParsed.limits_source -eq 'built-in') ("got=" + $emptyBudgetParsed.limits_source)) -and $caseOk
    }
    Close-Case "j) budget empty root" $caseOk
} finally {
    if ([string]::IsNullOrWhiteSpace($originalRoot)) {
        Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_ROOT = $originalRoot
    }
    if ([string]::IsNullOrWhiteSpace($originalTraces)) {
        Remove-Item -Path "Env:\AGENT_HQ_TRACES_DIR" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_TRACES_DIR = $originalTraces
    }
    Remove-Item -LiteralPath $EmptyRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

$totalChecks = $script:CheckPass + $script:CheckFail
$totalCases  = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: cases passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $totalCases)
Write-Host ("         checks passed=" + $script:CheckPass + " failed=" + $script:CheckFail + " total=" + $totalChecks)
Write-Host "=================================================="

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
