# test-capability-passport.ps1 - independent tests for the P3 capability passport
# and for the passport-aware routing in model-router.ps1.
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT plus a fixture traces directory exposed
# through $env:AGENT_HQ_TRACES_DIR, so no repository state is read or written
# and no provider quota is touched. The real scripts are dot-sourced (functions)
# and also invoked as CLIs (exit codes / output).
#
# Covered:
#   a) read     - Get-AgentPassport / Get-ModelPassport, unknown keys -> null
#   b) metrics  - Update-PassportFromMetrics: reliability + measured speed from
#                 fixture ratings/traces, dry-run writes nothing, residue-free
#   c) route    - configured wins, reason + reason_text + candidates are filled
#   d) fallback - OPEN breaker -> next viable candidate + rejected codes
#   e) filters  - capability (agent level and candidate level), cost tier, score
#   f) tolerance- no passport, broken passport, empty ratings, unknown agent
#   g) cli      - -List / -Json / -Agent / -Update / -DryRun / exit codes
#   h) hygiene  - CRLF output, no temp residue, fixtures left byte-identical
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$PassportScript = Join-Path $RepoRoot ".agents\scripts\capability-passport.ps1"
$RouterScript   = Join-Path $RepoRoot ".agents\scripts\model-router.ps1"

$TempBase   = Join-Path $env:TEMP "agent-hq-capability-passport-tests"
$Root       = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$MemoryDir  = Join-Path $Root ".memory"
$ConfigDir  = Join-Path $Root ".agents\config"
$AgentsDir  = Join-Path $Root ".opencode\agents"
$TracesDir  = Join-Path $Root "traces"
$PassportPath = Join-Path $ConfigDir "capability-passport.json"
$RatingsPath  = Join-Path $MemoryDir "ratings.jsonl"
$HealthPath   = Join-Path $MemoryDir "model-health.json"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) { Write-Host ("    ok  : " + $Label) } else { Write-Host ("    FAIL: " + $Label) }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $normalized = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $script:Utf8NoBom)
    return $Path
}

function Write-JsonFile {
    param([string]$Path, $Object)
    return (Write-TextFile -Path $Path -Text (ConvertTo-Json -InputObject $Object -Depth 10))
}

function Write-AgentFile {
    param([string]$Name, [string]$Model)
    return (Write-JsonFile -Path (Join-Path $AgentsDir ($Name + ".json")) -Object ([ordered]@{
        name = $Name; model = $Model; mode = "subagent"
    }))
}

function Write-HealthState {
    param([string]$Model, [string]$Status, [int]$FailCount, [string]$OpenUntil)
    $stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $state = @{}
    if (Test-Path -LiteralPath $HealthPath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($HealthPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($property in @($existing.PSObject.Properties)) { $state[$property.Name] = $property.Value }
    }
    $state[$Model] = [pscustomobject]@{ model = $Model; status = $Status; checked_at = $stamp; fail_count = $FailCount; open_until = $OpenUntil }
    $ordered = [ordered]@{}
    foreach ($key in @($state.Keys | Sort-Object)) { $ordered[$key] = $state[$key] }
    [void](Write-JsonFile -Path $HealthPath -Object $ordered)
}

function Get-FileHashHex {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Fixtures -------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) { New-Item -ItemType Directory -Path $TempBase -Force | Out-Null }
foreach ($rel in @(".memory", ".agents\config", ".opencode\agents", "traces")) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}

$fixturePassport = [ordered]@{
    version    = 1
    updated_at = "2026-09-01T00:00:00"
    agents     = [ordered]@{
        "qa-engineer"      = [ordered]@{ name = "qa-engineer"; model = "opencode/mimo-v2.5-free"; cost_tier = "free"
            capabilities = [ordered]@{ languages = @("python"); task_types = @("test", "review") } }
        "code-reviewer"    = [ordered]@{ name = "code-reviewer"; model = "opencode/big-pickle"; cost_tier = "free"
            capabilities = [ordered]@{ languages = @(); task_types = @("review") } }
        "security-auditor" = [ordered]@{ name = "security-auditor"; model = "opencode/ling-3.0-flash-fin-free"; cost_tier = "free"
            capabilities = [ordered]@{ languages = @(); task_types = @("security") } }
        "dev-1"            = [ordered]@{ name = "dev-1"; model = "opencode-go/deepseek-v4.1-flash"; cost_tier = "paid"
            capabilities = [ordered]@{ languages = @("python"); task_types = @("code") } }
        "auditor-x"        = [ordered]@{ name = "auditor-x"; model = "opencode/big-pickle"; cost_tier = "free"
            capabilities = [ordered]@{ languages = @(); task_types = @("security") } }
        "review-lead"      = [ordered]@{ name = "review-lead"; model = "opencode-go/deepseek-v4.1-flash"; cost_tier = "paid"
            capabilities = [ordered]@{ languages = @(); task_types = @("review", "code") } }
        "ghost-dev"        = [ordered]@{ name = "ghost-dev"; model = "vendor/mystery-model"; cost_tier = "unknown"
            capabilities = [ordered]@{ languages = @(); task_types = @("code") } }
    }
    models     = [ordered]@{
        "opencode-go/deepseek-v4.1-flash"     = [ordered]@{ model = "opencode-go/deepseek-v4.1-flash"; cost_tier = "paid"
            capabilities = [ordered]@{ task_types = @("code", "review") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = 79; latency_s = $null; context = "1M"; p50_ms = $null; sources = @() } }
        "opencode/ling-3.0-flash-fin-free"    = [ordered]@{ model = "opencode/ling-3.0-flash-fin-free"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = 169; latency_s = 1.09; context = "262K"; p50_ms = $null; sources = @() } }
        "opencode/mimo-v2.5-free"             = [ordered]@{ model = "opencode/mimo-v2.5-free"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code", "test", "review") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = $null; latency_s = $null; context = "200K"; p50_ms = $null; sources = @() } }
        "opencode/big-pickle"                 = [ordered]@{ model = "opencode/big-pickle"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code", "review") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = $null; latency_s = $null; context = "200K"; p50_ms = $null; sources = @() } }
        "opencode/nemotron-3.5-lightning-free" = [ordered]@{ model = "opencode/nemotron-3.5-lightning-free"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = 30; latency_s = 1.44; context = "1M"; p50_ms = $null; sources = @() } }
        "aihubmix/coding-glm-5.1-free"        = [ordered]@{ model = "aihubmix/coding-glm-5.1-free"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = $null; latency_s = $null; context = $null; p50_ms = $null; sources = @() } }
        "aihubmix/gpt-5.5-free"               = [ordered]@{ model = "aihubmix/gpt-5.5-free"; cost_tier = "free"
            capabilities = [ordered]@{ task_types = @("code") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = $null; latency_s = $null; context = $null; p50_ms = $null; sources = @() } }
        "opencode-go/qwen3.8-flash"           = [ordered]@{ model = "opencode-go/qwen3.8-flash"; cost_tier = "paid"
            capabilities = [ordered]@{ task_types = @("code") }; reliability = [ordered]@{ samples = 0; avg_grade = $null }; speed = [ordered]@{ tps_p50 = $null; latency_s = $null; context = $null; p50_ms = $null; sources = @() } }
    }
}
[void](Write-JsonFile -Path $PassportPath -Object $fixturePassport)

$fixtureRatings = @(
    '{"model":"opencode/big-pickle","agent":"code-reviewer","task_type":"review","grade":6,"date":"2026-09-01"}',
    '{"model":"opencode/big-pickle","agent":"code-reviewer","task_type":"review","grade":6,"date":"2026-09-02"}',
    '{"model":"opencode/mimo-v2.5-free","agent":"qa-engineer","task_type":"test","grade":9,"date":"2026-09-03","iterations":2}',
    '{"model":"opencode/mimo-v2.5-free","agent":"qa-engineer","task_type":"test","grade":10,"date":"2026-09-04","iterations":4}',
    '{"model":"opencode/ling-3.0-flash-fin-free","agent":"qa-engineer","task_type":"test","grade":8,"date":"2026-09-05"}',
    '{ this line is not json',
    ''
)
[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))

[void](Write-TextFile -Path (Join-Path $TracesDir "traces.jsonl") -Text (@(
    '{"ts":"2026-09-17T10:00:00.000Z","type":"tool","tool":"read","session_id":"ses_a","agent":"qa-engineer"}'
) -join "`n"))
[void](Write-TextFile -Path (Join-Path $TracesDir "performance.jsonl") -Text (@(
    '{"ts":"2026-09-17T10:00:10.000Z","session_id":"ses_a","duration_ms":1000,"score":90}',
    '{"ts":"2026-09-17T10:05:10.000Z","session_id":"ses_b","duration_ms":3000,"score":80}',
    '{"ts":"2026-09-17T10:06:10.000Z","type":"delegation","tool":"task","session_id":"ses_c"}'
) -join "`n"))

[void](Write-AgentFile -Name "qa-engineer" -Model "opencode/mimo-v2.5-free")
[void](Write-AgentFile -Name "code-reviewer" -Model "opencode/big-pickle")
[void](Write-AgentFile -Name "security-auditor" -Model "opencode/ling-3.0-flash-fin-free")
[void](Write-AgentFile -Name "dev-1" -Model "opencode-go/deepseek-v4.1-flash")
[void](Write-AgentFile -Name "auditor-x" -Model "opencode/big-pickle")
[void](Write-AgentFile -Name "review-lead" -Model "opencode-go/deepseek-v4.1-flash")
[void](Write-AgentFile -Name "ghost-dev" -Model "vendor/mystery-model")

$originalRoot      = $env:AGENT_HQ_ROOT
$originalTracesDir = $env:AGENT_HQ_TRACES_DIR
$env:AGENT_HQ_ROOT = $Root
$env:AGENT_HQ_TRACES_DIR = $TracesDir

Write-Host "=== agent-hq capability passport tests ==="
Write-Host ("Passport script: " + $PassportScript)
Write-Host ("Router script  : " + $RouterScript)
Write-Host ("Root           : " + $Root)

foreach ($script in @($PassportScript, $RouterScript)) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        Write-Host ("FATAL: script not found: " + $script)
        exit 1
    }
    $parseErrors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $script), [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-Host ("FATAL: " + $script + " has " + $parseErrors.Count + " parse error(s)")
        exit 1
    }
}

. $PassportScript
. $RouterScript

# --- a) reading the passport -------------------------------------------------

Write-Host ""
Write-Host "CASE: a) the passport is read per agent and per model"
$caseOk = $true

$agentPassport = Get-AgentPassport -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "agent passport is returned" ($null -ne $agentPassport)) -and $caseOk
$caseOk = (Write-Check "agent passport carries the configured model" ($agentPassport["model"] -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "agent task types are exposed" ((Get-PassportTaskTypes -Passport $agentPassport) -contains "test")) -and $caseOk
$caseOk = (Write-Check "unknown agent resolves to null" ($null -eq (Get-AgentPassport -Agent "no-such-agent" -Root $Root))) -and $caseOk

$modelPassport = Get-ModelPassport -Model "opencode/ling-3.0-flash-fin-free" -Root $Root
$caseOk = (Write-Check "model passport is returned" ($null -ne $modelPassport)) -and $caseOk
$caseOk = (Write-Check "model passport carries the cost tier" ($modelPassport["cost_tier"] -eq "free")) -and $caseOk
$caseOk = (Write-Check "unknown model resolves to null" ($null -eq (Get-ModelPassport -Model "no/such-model" -Root $Root))) -and $caseOk

$emptyAgent = Get-AgentPassport -Agent "" -Root $Root
$caseOk = (Write-Check "empty agent name is handled" ($null -eq $emptyAgent)) -and $caseOk

$matchTest = Test-CapabilityMatch -Declared @("test", "review") -Requested "qa-acceptance"
$caseOk = (Write-Check "qa-acceptance matches a declared test capability" ($matchTest.matched -eq $true)) -and $caseOk
$matchSecurity = Test-CapabilityMatch -Declared @("code") -Requested "security"
$caseOk = (Write-Check "security does not match a code-only entry" ($matchSecurity.matched -eq $false)) -and $caseOk
$matchUnknown = Test-CapabilityMatch -Declared @() -Requested "security"
$caseOk = (Write-Check "no declared capabilities never filter" ($matchUnknown.matched -eq $true)) -and $caseOk

Close-Case "a) passport read" $caseOk

# --- b) metrics refresh ------------------------------------------------------

Write-Host ""
Write-Host "CASE: b) Update-PassportFromMetrics rebuilds reliability and speed"
$caseOk = $true

$ratingsHashBefore = Get-FileHashHex -Path $RatingsPath

$dryRun = Update-PassportFromMetrics -Root $Root -DryRun
$caseOk = (Write-Check "dry run reports ok" ($dryRun.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "dry run writes nothing" ($dryRun.written -eq $false)) -and $caseOk
$afterDryRun = [System.IO.File]::ReadAllText($PassportPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$caseOk = (Write-Check "dry run left the file unchanged" ($afterDryRun.updated_at -eq "2026-09-01T00:00:00")) -and $caseOk

$updated = Update-PassportFromMetrics -Root $Root
$caseOk = (Write-Check "update reports ok" ($updated.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "update wrote the file" ($updated.written -eq $true)) -and $caseOk
$caseOk = (Write-Check "5 valid ratings lines were parsed" ($updated.ratings_parsed -eq 5)) -and $caseOk
$caseOk = (Write-Check "1 malformed ratings line was skipped" ($updated.ratings_skipped -eq 1)) -and $caseOk
$caseOk = (Write-Check "one session was attributed to its agent" ($updated.sessions_attributed -eq 1)) -and $caseOk
$caseOk = (Write-Check "every fixture agent was updated" ($updated.agents_updated -eq 7)) -and $caseOk
$caseOk = (Write-Check "8 fixture models were updated" ($updated.models_updated -eq 8)) -and $caseOk

$doc = Read-PassportDocument -Root $Root
$caseOk = (Write-Check "written passport parses" ($doc.ok -eq $true)) -and $caseOk

$mimoReliability = $doc.models["opencode/mimo-v2.5-free"]["reliability"]
$caseOk = (Write-Check "mimo samples = 2" ([int]$mimoReliability["samples"] -eq 2)) -and $caseOk
$caseOk = (Write-Check "mimo average grade = 9.5" ([double]$mimoReliability["avg_grade"] -eq 9.5)) -and $caseOk
$caseOk = (Write-Check "mimo iterations average = 3" ([double]$mimoReliability["iterations_avg"] -eq 3)) -and $caseOk
$caseOk = (Write-Check "mimo grade range is filled" (([double]$mimoReliability["grade_min"] -eq 9) -and ([double]$mimoReliability["grade_max"] -eq 10))) -and $caseOk

$bigPickleReliability = $doc.models["opencode/big-pickle"]["reliability"]
$caseOk = (Write-Check "big-pickle average grade = 6" ([double]$bigPickleReliability["avg_grade"] -eq 6)) -and $caseOk
$caseOk = (Write-Check "big-pickle has no iterations recorded" ($null -eq $bigPickleReliability["iterations_avg"])) -and $caseOk

$qaReliability = $doc.agents["qa-engineer"]["reliability"]
$caseOk = (Write-Check "qa-engineer samples = 3" ([int]$qaReliability["samples"] -eq 3)) -and $caseOk
$caseOk = (Write-Check "qa-engineer average grade = 9" ([double]$qaReliability["avg_grade"] -eq 9)) -and $caseOk
$caseOk = (Write-Check "qa-engineer iterations average = 3" ([double]$qaReliability["iterations_avg"] -eq 3)) -and $caseOk

$qaSpeed = $doc.agents["qa-engineer"]["speed"]
$caseOk = (Write-Check "qa-engineer measured sessions = 1" ([int]$qaSpeed["sessions"] -eq 1)) -and $caseOk
$caseOk = (Write-Check "qa-engineer measured p50 = 1000 ms" ([double]$qaSpeed["p50_ms"] -eq 1000)) -and $caseOk
$caseOk = (Write-Check "reported model facts survive the refresh" ([double]$doc.models["opencode/ling-3.0-flash-fin-free"]["speed"]["tps_p50"] -eq 169)) -and $caseOk
$caseOk = (Write-Check "measured speed source is labelled" ((@($qaSpeed["sources"]) -contains "performance.jsonl + traces.jsonl"))) -and $caseOk

$caseOk = (Write-Check "ratings file was not modified" ((Get-FileHashHex -Path $RatingsPath) -eq $ratingsHashBefore)) -and $caseOk

$residue = @(Get-ChildItem -LiteralPath $ConfigDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "the atomic write leaves no residue" ($residue.Count -eq 0)) -and $caseOk

Close-Case "b) metrics refresh" $caseOk

# --- c) stable routing -------------------------------------------------------

Write-Host ""
Write-Host "CASE: c) a viable configured model wins and the decision explains itself"
$caseOk = $true
Remove-Item -LiteralPath $HealthPath -Force -ErrorAction SilentlyContinue

$route = Get-RouteDecision -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "configured model wins" ($route.model -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "configured field is reported" ($route.configured -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "nothing changed" ($route.changed -eq $false)) -and $caseOk
$caseOk = (Write-Check "reason is configured-healthy" ($route.reason -eq "configured-healthy")) -and $caseOk
$caseOk = (Write-Check "decision mode is stable" ($route.decision_mode -eq "stable")) -and $caseOk
$caseOk = (Write-Check "passport is reported as ok" ($route.passport -eq "ok")) -and $caseOk
$caseOk = (Write-Check "the full ladder is listed" (@($route.candidates).Count -ge 7)) -and $caseOk
$caseOk = (Write-Check "reason_text names the chosen model" ($route.reason_text -match "chosen=opencode/mimo-v2\.5-free")) -and $caseOk
$caseOk = (Write-Check "reason_text carries the passport metrics" ($route.reason_text -match "mode=stable") -and ($route.reason_text -match "passport=ok")) -and $caseOk
$chosenCandidate = @($route.candidates | Where-Object { $_.decision -eq "chosen" })[0]
$caseOk = (Write-Check "exactly one candidate is chosen" (@($route.candidates | Where-Object { $_.decision -eq "chosen" }).Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "candidate metrics are attached" (($chosenCandidate.cost_tier -eq "free") -and ([int]$chosenCandidate.samples -eq 2) -and ([double]$chosenCandidate.avg_grade -eq 9.5))) -and $caseOk

$legacyRoute = Get-ModelRoute -Agent "code-reviewer" -Root $Root
$caseOk = (Write-Check "Get-ModelRoute keeps the pre-P3 fields" (($legacyRoute.agent -eq "code-reviewer") -and ($legacyRoute.model -eq "opencode/big-pickle") -and ($legacyRoute.reason -eq "configured-healthy") -and ($legacyRoute.changed -eq $false))) -and $caseOk

Close-Case "c) stable routing" $caseOk

# --- d) breaker fallback ------------------------------------------------------

Write-Host ""
Write-Host "CASE: d) an OPEN configured model falls back with an explained reason"
$caseOk = $true
$openUntil = (Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
Write-HealthState -Model "opencode/mimo-v2.5-free" -Status "DEAD" -FailCount 2 -OpenUntil $openUntil

$fallbackRoute = Get-RouteDecision -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "the router refuses the OPEN model" ($fallbackRoute.model -ne "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "the next ladder candidate is used" ($fallbackRoute.model -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk
$caseOk = (Write-Check "the route is marked as changed" ($fallbackRoute.changed -eq $true)) -and $caseOk
$caseOk = (Write-Check "reason is configured-open-fallback" ($fallbackRoute.reason -eq "configured-open-fallback")) -and $caseOk
$repelledCandidate = @($fallbackRoute.candidates | Where-Object { $_.model -eq "opencode/mimo-v2.5-free" })[0]
$caseOk = (Write-Check "the rejected candidate carries the breaker code" ($repelledCandidate.code -match "breaker-open")) -and $caseOk
$caseOk = (Write-Check "the rejection is spelled out in reason_text" ($fallbackRoute.reason_text -match "rejected opencode/mimo-v2\.5-free \[breaker-open\]")) -and $caseOk

$applyRoute = Get-RouteDecision -Agent "qa-engineer" -TaskType "" -MaxCostTier "any" -Root $Root
$caseOk = (Write-Check "a healthy fallback target is chosen deterministically" ($applyRoute.model -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

Remove-Item -LiteralPath $HealthPath -Force -ErrorAction SilentlyContinue

Close-Case "d) breaker fallback" $caseOk

# --- e) capability / cost / score filters ------------------------------------

Write-Host ""
Write-Host "CASE: e) capability, cost tier and score decide the route"
$caseOk = $true

$agentMismatch = Get-RouteDecision -Agent "dev-1" -TaskType "security" -Root $Root
$caseOk = (Write-Check "a task the agent does not declare is refused" ($agentMismatch.model -eq "")) -and $caseOk
$caseOk = (Write-Check "reason is agent-capability-mismatch" ($agentMismatch.reason -eq "agent-capability-mismatch")) -and $caseOk
$caseOk = (Write-Check "no model is proposed" ($agentMismatch.changed -eq $false)) -and $caseOk
$caseOk = (Write-Check "reason_text names the declared task types" ($agentMismatch.reason_text -match "dev-1 declares \[code\]")) -and $caseOk

$agentOk = Get-RouteDecision -Agent "dev-1" -TaskType "code" -Root $Root
$caseOk = (Write-Check "a matching task type routes normally" ($agentOk.model -eq "opencode-go/deepseek-v4.1-flash")) -and $caseOk
$caseOk = (Write-Check "code task stays stable" ($agentOk.reason -eq "configured-healthy")) -and $caseOk

$costRoute = Get-RouteDecision -Agent "review-lead" -TaskType "review" -MaxCostTier "free" -Root $Root
$caseOk = (Write-Check "the paid configured model is dropped" ($costRoute.model -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "reason is cost-tier-fallback" ($costRoute.reason -eq "cost-tier-fallback")) -and $caseOk
$paidCandidate = @($costRoute.candidates | Where-Object { $_.model -eq "opencode-go/deepseek-v4.1-flash" })[0]
$caseOk = (Write-Check "cost rejects the paid model" ($paidCandidate.code -match "cost-tier-above-max")) -and $caseOk
$lingCandidate = @($costRoute.candidates | Where-Object { $_.model -eq "opencode/ling-3.0-flash-fin-free" })[0]
$caseOk = (Write-Check "capability rejects a code-only model for a review" ($lingCandidate.code -match "capability-mismatch")) -and $caseOk

$allRejected = Get-RouteDecision -Agent "auditor-x" -TaskType "security" -Root $Root
$caseOk = (Write-Check "every candidate can be rejected" ($allRejected.reason -eq "all-candidates-rejected")) -and $caseOk
$caseOk = (Write-Check "the last ladder entry is forced and flagged" ($allRejected.model -eq "opencode-go/qwen3.8-flash")) -and $caseOk
$forcedCandidate = @($allRejected.candidates | Where-Object { $_.model -eq $allRejected.model })[0]
$caseOk = (Write-Check "the forced candidate is labelled" ($forcedCandidate.code -eq "forced-last-resort")) -and $caseOk

$scored = Get-RouteDecision -Agent "code-reviewer" -Optimize -Root $Root
$caseOk = (Write-Check "scoring prefers the better graded model" ($scored.model -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "scoring changes the mode" ($scored.decision_mode -eq "scored")) -and $caseOk
$caseOk = (Write-Check "reason is scored-preferred" ($scored.reason -eq "scored-preferred")) -and $caseOk
$scoredChosen = @($scored.candidates | Where-Object { $_.decision -eq "chosen" })[0]
$caseOk = (Write-Check "the winning candidate has a score" ([double]$scoredChosen.score -gt 0.8)) -and $caseOk

Close-Case "e) filters and score" $caseOk

# --- f) tolerance ------------------------------------------------------------

Write-Host ""
Write-Host "CASE: f) missing, broken and empty data never break routing"
$caseOk = $true

$passportBackup = [System.IO.File]::ReadAllText($PassportPath, [System.Text.Encoding]::UTF8)

Remove-Item -LiteralPath $PassportPath -Force
$noPassport = Get-RouteDecision -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "a missing passport is reported" ($noPassport.passport -eq "missing")) -and $caseOk
$caseOk = (Write-Check "routing still answers on health only" ($noPassport.model -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "no passport leaves no metrics" (@($noPassport.candidates)[0].avg_grade -eq $null)) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text "{ this is not valid json")
$brokenPassport = Get-RouteDecision -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "a broken passport is reported" ($brokenPassport.passport -eq "broken")) -and $caseOk
$caseOk = (Write-Check "routing survives a broken passport" ($brokenPassport.model -eq "opencode/mimo-v2.5-free")) -and $caseOk
$caseOk = (Write-Check "the parse error is surfaced in the note" ($brokenPassport.passport_note -match "not valid JSON")) -and $caseOk
$caseOk = (Write-Check "a broken passport yields no capability filter" ($brokenPassport.reason -eq "configured-healthy")) -and $caseOk

$caseOk = (Write-Check "reading a broken document does not throw" ((Read-PassportDocument -Root $Root).ok -eq $false)) -and $caseOk
$caseOk = (Write-Check "unknown agent passport on broken data is null" ($null -eq (Get-AgentPassport -Agent "qa-engineer" -Root $Root))) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text $passportBackup)
[void](Write-TextFile -Path $RatingsPath -Text "")

$emptyRatings = Update-PassportFromMetrics -Root $Root
$caseOk = (Write-Check "an empty ratings file is tolerated" ($emptyRatings.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "no ratings means no samples" ($emptyRatings.ratings_parsed -eq 0)) -and $caseOk
$emptyDoc = Read-PassportDocument -Root $Root
$caseOk = (Write-Check "reliability stays null without ratings" ($null -eq $emptyDoc.agents["qa-engineer"]["reliability"]["avg_grade"])) -and $caseOk
$caseOk = (Write-Check "the empty source is labelled" ([string]$emptyDoc.agents["qa-engineer"]["reliability"]["source"] -match "no records")) -and $caseOk

[void](Write-TextFile -Path $RatingsPath -Text ($fixtureRatings -join "`n"))

$unknownAgent = Get-RouteDecision -Agent "no-such-agent" -Root $Root
$caseOk = (Write-Check "an unknown agent is reported instead of guessed" ($unknownAgent.reason -eq "agent-model-unknown")) -and $caseOk
$caseOk = (Write-Check "an unknown agent has no model" ($unknownAgent.model -eq "")) -and $caseOk
$caseOk = (Write-Check "an unknown agent lists no candidates" (@($unknownAgent.candidates).Count -eq 0)) -and $caseOk

$badTier = Get-RouteDecision -Agent "ghost-dev" -MaxCostTier "free" -Root $Root
$caseOk = (Write-Check "a model without cost data counts as paid" ($badTier.model -ne "vendor/mystery-model")) -and $caseOk
$ghostCandidate = @($badTier.candidates | Where-Object { $_.model -eq "vendor/mystery-model" })[0]
$caseOk = (Write-Check "the unknown tier is rejected against a free ceiling" ($ghostCandidate.code -match "cost-tier-above-max")) -and $caseOk
$noCeiling = Get-RouteDecision -Agent "ghost-dev" -Root $Root
$caseOk = (Write-Check "the default policy does not filter the unknown tier" ($noCeiling.model -eq "vendor/mystery-model")) -and $caseOk

Close-Case "f) tolerance" $caseOk

# --- g) command line ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: g) the command line of both scripts"
$caseOk = $true

$listOutput = (& $PassportScript -List -Root $Root *>&1 | Out-String)
$listExit = $LASTEXITCODE
$caseOk = (Write-Check "-List exits 0" ($listExit -eq 0)) -and $caseOk
$caseOk = (Write-Check "-List prints the passport path" ($listOutput -match "CAPABILITY PASSPORT")) -and $caseOk
$caseOk = (Write-Check "-List shows an agent row" ($listOutput -match "qa-engineer")) -and $caseOk
$caseOk = (Write-Check "-List shows a model row" ($listOutput -match "opencode/mimo-v2\.5-free")) -and $caseOk

$jsonOutput = (& $PassportScript -Json -Root $Root *>&1 | Out-String)
$jsonExit = $LASTEXITCODE
$caseOk = (Write-Check "-Json exits 0" ($jsonExit -eq 0)) -and $caseOk
$jsonParses = $true
$parsedJson = $null
try { $parsedJson = $jsonOutput | ConvertFrom-Json } catch { $jsonParses = $false }
$caseOk = (Write-Check "-Json emits valid JSON" $jsonParses) -and $caseOk
$caseOk = (Write-Check "-Json carries the agents section" ($null -ne $parsedJson.agents)) -and $caseOk
$caseOk = (Write-Check "-Json carries the models section" ($null -ne $parsedJson.models)) -and $caseOk

$agentJson = (& $PassportScript -Agent "qa-engineer" -Json -Root $Root *>&1 | Out-String)
$agentJsonExit = $LASTEXITCODE
$agentJsonParses = $true
$parsedAgent = $null
try { $parsedAgent = $agentJson | ConvertFrom-Json } catch { $agentJsonParses = $false }
$caseOk = (Write-Check "-Agent -Json exits 0" ($agentJsonExit -eq 0)) -and $caseOk
$caseOk = (Write-Check "-Agent -Json is valid and correct" ($agentJsonParses -and ($parsedAgent.name -eq "qa-engineer"))) -and $caseOk

$missingAgent = (& $PassportScript -Agent "no-such-agent" -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Agent on an unknown agent exits 2" ($LASTEXITCODE -eq 2)) -and $caseOk
$missingParses = $true
$parsedMissing = $null
try { $parsedMissing = $missingAgent | ConvertFrom-Json } catch { $missingParses = $false }
$caseOk = (Write-Check "-Agent error output stays valid JSON" ($missingParses -and ($parsedMissing.ok -eq $false))) -and $caseOk

$updateOutput = (& $PassportScript -Update -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Update exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-Update prints the summary" ($updateOutput -match "PASSPORT METRICS UPDATED")) -and $caseOk

$dryOutput = (& $PassportScript -Update -DryRun -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Update -DryRun exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-DryRun reports that nothing was written" ($dryOutput -match "written     : False")) -and $caseOk

[void](Write-TextFile -Path $PassportPath -Text "{ broken again")
$brokenJson = (& $PassportScript -Json -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Json on a broken passport exits 2" ($LASTEXITCODE -eq 2)) -and $caseOk
$brokenParses = $true
$parsedBroken = $null
try { $parsedBroken = $brokenJson | ConvertFrom-Json } catch { $brokenParses = $false }
$caseOk = (Write-Check "-Json on a broken passport is valid JSON" ($brokenParses -and ($parsedBroken.ok -eq $false))) -and $caseOk
[void](Write-TextFile -Path $PassportPath -Text $passportBackup)

$routeOutput = (& $RouterScript -Route -Agent "qa-engineer" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Route exits 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-Route prints ROUTE" ($routeOutput -match "ROUTE\s*:\s*opencode/mimo-v2\.5-free")) -and $caseOk
$caseOk = (Write-Check "-Route prints the WHY explanation" ($routeOutput -match "WHY\s*:.*reason=configured-healthy")) -and $caseOk
$caseOk = (Write-Check "-Route prints the candidate table" ($routeOutput -match "CANDIDATES\s*:") -and ($routeOutput -match "CHOSEN")) -and $caseOk

$capOutput = (& $RouterScript -Route -Agent "dev-1" -TaskType "security" -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "-Route refuses a capability mismatch with exit 0" ($LASTEXITCODE -eq 0)) -and $caseOk
$caseOk = (Write-Check "-Route prints the mismatch reason" ($capOutput -match "REASON\s*:\s*agent-capability-mismatch")) -and $caseOk

$applyOutput = (& $RouterScript -Route -Agent "dev-1" -TaskType "security" -Apply -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "apply is refused when no model is viable" ($LASTEXITCODE -eq 1)) -and $caseOk
$caseOk = (Write-Check "the refusal is explained" ($applyOutput -match "APPLY\s*:\s*refused")) -and $caseOk

$badArg = (& $PassportScript -NoSuchFlag -Root $Root *>&1 | Out-String)
$caseOk = (Write-Check "an unknown argument exits 1" ($LASTEXITCODE -eq 1)) -and $caseOk

Close-Case "g) command line" $caseOk

# --- h) hygiene --------------------------------------------------------------

Write-Host ""
Write-Host "CASE: h) CRLF output and a clean working tree"
$caseOk = $true

[void](Update-PassportFromMetrics -Root $Root)
$rawPassport = [System.IO.File]::ReadAllText($PassportPath, [System.Text.Encoding]::UTF8)
$caseOk = (Write-Check "the passport uses CRLF" ($rawPassport.Contains("`r`n"))) -and $caseOk
$caseOk = (Write-Check "the passport has no bare LF" ($rawPassport.Replace("`r`n", "") -notmatch "`n")) -and $caseOk
$caseOk = (Write-Check "the passport has no BOM" (-not ($rawPassport.Length -gt 0 -and [int][char]$rawPassport[0] -eq 0xFEFF))) -and $caseOk
$caseOk = (Write-Check "the written passport parses" ((Read-PassportDocument -Root $Root).ok -eq $true)) -and $caseOk

$residue = @(Get-ChildItem -LiteralPath $ConfigDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "no temp residue next to the passport" ($residue.Count -eq 0)) -and $caseOk
$memoryResidue = @(Get-ChildItem -LiteralPath $MemoryDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "no temp residue in .memory" ($memoryResidue.Count -eq 0)) -and $caseOk

Close-Case "h) hygiene" $caseOk

# --- summary + cleanup -------------------------------------------------------

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

if ($null -ne $originalRoot) { $env:AGENT_HQ_ROOT = $originalRoot } else { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
if ($null -ne $originalTracesDir) { $env:AGENT_HQ_TRACES_DIR = $originalTracesDir } else { Remove-Item Env:\AGENT_HQ_TRACES_DIR -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
if (@(Get-ChildItem -LiteralPath $TempBase -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
