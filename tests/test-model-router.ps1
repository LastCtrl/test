# test-model-router.ps1 - independent tests for .agents\scripts\model-router.ps1
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# exposed through $env:AGENT_HQ_ROOT, and the CLI is the deterministic fixture
# tests\fake-model-cli.ps1 exposed through $env:AGENT_HQ_OPENCODE, so no real
# provider quota is touched and no repository state is modified.
#
# Covered:
#   a) classification - OK / RATE_LIMIT / DEAD (dead + unknown markers) / TIMEOUT
#   b) state file     - one record per model with the documented fields
#   c) breaker        - 2 consecutive failures -> OPEN, router stops selecting it
#   d) fallback       - configured model OPEN -> next healthy model from the SKILL ladder
#   e) cooldown       - an expired open_until releases the model again (half-open)
#   f) apply          - Set-AgentModel writes the agent file + backup, rollback restores it
#   g) cli apply      - `model-router.ps1 -Route -Agent X -Apply` exits 0 and rewrites the file
#   h) runtime config - opencode debug config fallback (fake `debug config` payload)
#   i) dot-source     - dot-sourcing defines functions but never runs the CLI or
#                       clobbers the caller's variables (PS 5.1 gotcha)
#   j) first key only - BUG-023: Set-AgentModel rewrites the first "model" key and
#                       leaves every other model key / the rest of the file intact
#   k) state locking  - BUG-024: lock-guarded read-modify-write, tmp+swap write,
#                       no lost records with concurrent writers, fail-open warning
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Router   = Join-Path $RepoRoot ".agents\scripts\model-router.ps1"
$FakeCli  = Join-Path $Here "fake-model-cli.ps1"

$TempBase  = Join-Path $env:TEMP "agent-hq-model-router-tests"
$Root      = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$MemoryDir = Join-Path $Root ".memory"
$AgentsDir = Join-Path $Root ".opencode\agents"
$StatePath = Join-Path $MemoryDir "model-health.json"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass  = 0
$script:CaseFail  = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
    } else {
        Write-Host ("    FAIL: " + $Label)
    }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Reset-HealthState {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
}

function Set-CliMode {
    param([string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        Remove-Item Env:\FAKE_MODEL_CLI_MODE -ErrorAction SilentlyContinue
    } else {
        $env:FAKE_MODEL_CLI_MODE = $Mode
    }
}

function Write-AgentFile {
    param([string]$Name, [string]$Model)
    $path = Join-Path $AgentsDir ($Name + ".json")
    $content = "{`r`n    `"name`":  `"$Name`",`r`n    `"model`":  `"$Model`",`r`n    `"mode`":  `"subagent`"`r`n}`r`n"
    [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
    return $path
}

function Get-AgentFileModel {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($raw, '(?m)^\s*"model"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Read-StateEntry {
    param([string]$Model)
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    $json = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $prop = $json.PSObject.Properties[$Model]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Write-HealthState {
    param([string]$Model, [string]$Status, [int]$FailCount, [string]$OpenUntil)
    $stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $state = @{}
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($property in @($existing.PSObject.Properties)) { $state[$property.Name] = $property.Value }
    }
    $state[$Model] = [pscustomobject]@{
        model      = $Model
        status     = $Status
        checked_at = $stamp
        fail_count = $FailCount
        open_until = $OpenUntil
    }
    $ordered = [ordered]@{}
    foreach ($key in @($state.Keys | Sort-Object)) { $ordered[$key] = $state[$key] }
    [System.IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject $ordered -Depth 6), $script:Utf8NoBom)
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($rel in @(".memory", ".opencode\agents")) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}

$originalRoot       = $env:AGENT_HQ_ROOT
$originalCli        = $env:AGENT_HQ_OPENCODE
$originalMode       = $env:FAKE_MODEL_CLI_MODE
$originalConfigJson = $env:FAKE_MODEL_CLI_CONFIG_JSON

$env:AGENT_HQ_ROOT = $Root
$env:AGENT_HQ_OPENCODE = $FakeCli
Remove-Item Env:\FAKE_MODEL_CLI_CONFIG_JSON -ErrorAction SilentlyContinue

Write-AgentFile -Name "dev-a" -Model "opencode-go/deepseek-v4.1-flash" | Out-Null
Write-AgentFile -Name "code-reviewer" -Model "opencode/big-pickle" | Out-Null
Write-AgentFile -Name "qa-engineer" -Model "opencode/ling-3.0-flash-fin-free" | Out-Null

Write-Host "=== agent-hq model router tests ==="
Write-Host ("Router : " + $Router)
Write-Host ("Fake cli: " + $FakeCli)
Write-Host ("Root   : " + $Root)

if (-not (Test-Path -LiteralPath $Router -PathType Leaf)) {
    Write-Host ("FATAL: router not found: " + $Router)
    exit 1
}

# Syntax gate - a broken router must fail fast instead of producing odd results.
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $Router), [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host ("FATAL: router has " + $parseErrors.Count + " parse error(s)")
    exit 1
}

# --- i) dot-source hygiene --------------------------------------------------

Write-Host ""
Write-Host "CASE: i) dot-source defines functions without running the CLI"
$caseOk = $true
$callerRoot = "SENTINEL-ROOT"

. $Router

$caseOk = (Write-Check "router functions are loaded after dot-sourcing" ($null -ne (Get-Command Test-ModelHealth -ErrorAction SilentlyContinue))) -and $caseOk
$caseOk = (Write-Check "dot-sourcing did not run the command line (no state file)" (-not (Test-Path -LiteralPath $StatePath))) -and $caseOk
$caseOk = (Write-Check "dot-sourcing kept the caller's variable" ($callerRoot -eq "SENTINEL-ROOT")) -and $caseOk
$caseOk = (Write-Check "fallback ladder is populated from the SKILL" (@($script:FallbackLadder).Count -ge 5)) -and $caseOk

Close-Case "i) dot-source" $caseOk

# --- a) classification + b) state file --------------------------------------

Write-Host ""
Write-Host "CASE: a) classification OK / RATE_LIMIT / DEAD / TIMEOUT"
$caseOk = $true
Reset-HealthState

Set-CliMode "pong"
$okResult = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root
$caseOk = (Write-Check "pong -> OK" ($okResult.status -eq "OK")) -and $caseOk
$caseOk = (Write-Check "OK resets fail_count to 0" ([int]$okResult.fail_count -eq 0)) -and $caseOk
$caseOk = (Write-Check "OK leaves the breaker closed" ([string]::IsNullOrEmpty([string]$okResult.open_until))) -and $caseOk

$entry = Read-StateEntry -Model "opencode/big-pickle"
$hasFields = ($null -ne $entry) -and
    ($null -ne $entry.PSObject.Properties["model"]) -and
    ($null -ne $entry.PSObject.Properties["status"]) -and
    ($null -ne $entry.PSObject.Properties["checked_at"]) -and
    ($null -ne $entry.PSObject.Properties["fail_count"]) -and
    ($null -ne $entry.PSObject.Properties["open_until"])
$caseOk = (Write-Check "state file holds model/status/checked_at/fail_count/open_until" $hasFields) -and $caseOk
$caseOk = (Write-Check "state file is written under .memory\model-health.json" (Test-Path -LiteralPath $StatePath -PathType Leaf)) -and $caseOk

Set-CliMode "rate-limit"
$rateResult = Test-ModelHealth -Model "opencode/mimo-v2.5-free" -TimeoutSec 20 -Root $Root
$caseOk = (Write-Check "Free usage exceeded -> RATE_LIMIT" ($rateResult.status -eq "RATE_LIMIT")) -and $caseOk
$caseOk = (Write-Check "RATE_LIMIT counts as a failure" ([int]$rateResult.fail_count -eq 1)) -and $caseOk

Set-CliMode "dead"
$deadResult = Test-ModelHealth -Model "opencode/nemotron-3.5-lightning-free" -TimeoutSec 20 -Root $Root
$caseOk = (Write-Check "No available channel -> DEAD" ($deadResult.status -eq "DEAD")) -and $caseOk

Set-CliMode "unknown"
$unknownResult = Test-ModelHealth -Model "aihubmix/coding-glm-5.1-free" -TimeoutSec 20 -Root $Root
$caseOk = (Write-Check "UnknownError -> DEAD" ($unknownResult.status -eq "DEAD")) -and $caseOk

Set-CliMode "hang"
$hangResult = Test-ModelHealth -Model "aihubmix/gpt-5.5-free" -TimeoutSec 3 -Root $Root
$caseOk = (Write-Check "hung CLI -> TIMEOUT" ($hangResult.status -eq "TIMEOUT")) -and $caseOk

Close-Case "a) classification" $caseOk

# --- c) circuit breaker -----------------------------------------------------

Write-Host ""
Write-Host "CASE: c) 2 consecutive failures open the breaker"
$caseOk = $true
Reset-HealthState
Set-CliMode "dead"

$first = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root -FailThreshold 2 -CooldownMinutes 15
$caseOk = (Write-Check "first failure keeps the breaker closed" ([string]::IsNullOrEmpty([string]$first.open_until))) -and $caseOk
$caseOk = (Write-Check "first failure counts 1" ([int]$first.fail_count -eq 1)) -and $caseOk
$caseOk = (Write-Check "Test-ModelOpen is false after 1 failure" ((Test-ModelOpen -Model "opencode/big-pickle" -Root $Root) -eq $false)) -and $caseOk

$routeBefore = Get-ModelRoute -Agent "code-reviewer" -Root $Root
$caseOk = (Write-Check "healthy configured model is routed unchanged" ($routeBefore.model -eq "opencode/big-pickle")) -and $caseOk
$caseOk = (Write-Check "healthy route is not marked as changed" ($routeBefore.changed -eq $false)) -and $caseOk

$second = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root -FailThreshold 2 -CooldownMinutes 15
$caseOk = (Write-Check "second failure counts 2" ([int]$second.fail_count -eq 2)) -and $caseOk
$caseOk = (Write-Check "second failure sets open_until" (-not [string]::IsNullOrEmpty([string]$second.open_until))) -and $caseOk
$caseOk = (Write-Check "Test-ModelOpen is true after 2 failures" ((Test-ModelOpen -Model "opencode/big-pickle" -Root $Root) -eq $true)) -and $caseOk

$routeAfter = Get-ModelRoute -Agent "code-reviewer" -Root $Root
$caseOk = (Write-Check "router refuses the OPEN model" ($routeAfter.model -ne "opencode/big-pickle")) -and $caseOk
$caseOk = (Write-Check "route reports the configured model" ($routeAfter.configured -eq "opencode/big-pickle")) -and $caseOk
$caseOk = (Write-Check "route is marked as changed" ($routeAfter.changed -eq $true)) -and $caseOk
$caseOk = (Write-Check "route reason is configured-open-fallback" ($routeAfter.reason -eq "configured-open-fallback")) -and $caseOk

$routeOther = Get-ModelRoute -Agent "dev-a" -Root $Root
$caseOk = (Write-Check "another agent's healthy model is untouched" ($routeOther.model -eq "opencode-go/deepseek-v4.1-flash")) -and $caseOk

Close-Case "c) circuit breaker" $caseOk

# --- d) fallback ladder -----------------------------------------------------

Write-Host ""
Write-Host "CASE: d) fallback picks the next healthy model from the SKILL ladder"
$caseOk = $true

$caseOk = (Write-Check "fallback is the first free checker in the ladder" ($routeAfter.model -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

Write-HealthState -Model "opencode/big-pickle" -Status "DEAD" -FailCount 2 -OpenUntil ((Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture))
Write-HealthState -Model "opencode/ling-3.0-flash-fin-free" -Status "DEAD" -FailCount 2 -OpenUntil ((Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture))
$routeSecond = Get-ModelRoute -Agent "code-reviewer" -Root $Root
$caseOk = (Write-Check "second ladder entry used when the first one is OPEN too" ($routeSecond.model -eq "opencode/mimo-v2.5-free")) -and $caseOk

# Ladder for a model the router has never seen still ends at the senior model.
$caseOk = (Write-Check "ladder keeps the configured model first" ((Get-FallbackLadder -Model "custom/model")[0] -eq "custom/model")) -and $caseOk
$ladderTail = Get-FallbackLadder -Model "custom/model"
$caseOk = (Write-Check "ladder ends with the paid senior model" ($ladderTail[$ladderTail.Count - 1] -eq "opencode-go/qwen3.8-flash")) -and $caseOk
$caseOk = (Write-Check "ladder contains the aihubmix free endpoint" (@($ladderTail) -contains "aihubmix/gpt-5.5-free")) -and $caseOk
$caseOk = (Write-Check "ladder has no duplicates" ((@($ladderTail) | Select-Object -Unique).Count -eq $ladderTail.Count)) -and $caseOk

Close-Case "d) fallback ladder" $caseOk

# --- e) cooldown / half-open ------------------------------------------------

Write-Host ""
Write-Host "CASE: e) expired cooldown releases the model (half-open)"
$caseOk = $true

Write-HealthState -Model "opencode/big-pickle" -Status "DEAD" -FailCount 2 -OpenUntil "2020-01-01T00:00:00"
$caseOk = (Write-Check "expired open_until -> breaker closed" ((Test-ModelOpen -Model "opencode/big-pickle" -Root $Root) -eq $false)) -and $caseOk

$routeExpired = Get-ModelRoute -Agent "code-reviewer" -Root $Root
$caseOk = (Write-Check "configured model is routed again" ($routeExpired.model -eq "opencode/big-pickle")) -and $caseOk
$caseOk = (Write-Check "route is not changed after cooldown" ($routeExpired.changed -eq $false)) -and $caseOk
$caseOk = (Write-Check "route reason is configured-healthy" ($routeExpired.reason -eq "configured-healthy")) -and $caseOk

Set-CliMode "dead"
$halfOpen = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root -FailThreshold 2
$caseOk = (Write-Check "half-open failure restarts the counter at 1" ([int]$halfOpen.fail_count -eq 1)) -and $caseOk
$caseOk = (Write-Check "half-open failure keeps the breaker closed" ([string]::IsNullOrEmpty([string]$halfOpen.open_until))) -and $caseOk

$future = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
Write-HealthState -Model "opencode/big-pickle" -Status "DEAD" -FailCount 2 -OpenUntil $future
$caseOk = (Write-Check "future open_until -> breaker open" ((Test-ModelOpen -Model "opencode/big-pickle" -Root $Root) -eq $true)) -and $caseOk

Close-Case "e) cooldown" $caseOk

# --- f) apply / rollback ----------------------------------------------------

Write-Host ""
Write-Host "CASE: f) Set-AgentModel writes the agent file, keeps a backup and rolls back"
$caseOk = $true
$agentFile = Join-Path $AgentsDir "code-reviewer.json"

$caseOk = (Write-Check "agent file starts on big-pickle" ((Get-AgentFileModel -Path $agentFile) -eq "opencode/big-pickle")) -and $caseOk

$applied = Set-AgentModel -Agent "code-reviewer" -Model "opencode/ling-3.0-flash-fin-free" -Root $Root
$caseOk = (Write-Check "Set-AgentModel reports success" ($applied.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "Set-AgentModel reports a change" ($applied.changed -eq $true)) -and $caseOk
$caseOk = (Write-Check "agent file now has the routed model" ((Get-AgentFileModel -Path $agentFile) -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

$backups = @(Get-ChildItem -LiteralPath $AgentsDir -Filter "code-reviewer.json.bak.*" -File)
$caseOk = (Write-Check "a timestamped backup was created" ($backups.Count -eq 1)) -and $caseOk
if ($backups.Count -eq 1) {
    $caseOk = (Write-Check "backup holds the previous model" ((Get-AgentFileModel -Path $backups[0].FullName) -eq "opencode/big-pickle")) -and $caseOk
    Copy-Item -LiteralPath $backups[0].FullName -Destination $agentFile -Force
    $caseOk = (Write-Check "rollback restores the original model" ((Get-AgentFileModel -Path $agentFile) -eq "opencode/big-pickle")) -and $caseOk
}

$noop = Set-AgentModel -Agent "code-reviewer" -Model "opencode/big-pickle" -Root $Root
$caseOk = (Write-Check "same model -> no change, no extra backup" (($noop.ok -eq $true) -and ($noop.changed -eq $false))) -and $caseOk
$caseOk = (Write-Check "missing agent file is reported as an error" ((Set-AgentModel -Agent "no-such-agent" -Model "opencode/big-pickle" -Root $Root).ok -eq $false)) -and $caseOk

Close-Case "f) apply" $caseOk

# --- g) CLI -Route -Apply ---------------------------------------------------

Write-Host ""
Write-Host "CASE: g) model-router.ps1 -Route -Agent code-reviewer -Apply"
$caseOk = $true
Reset-HealthState
Set-CliMode "dead"

$null = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root
$null = Test-ModelHealth -Model "opencode/big-pickle" -TimeoutSec 20 -Root $Root

$textBefore = [System.IO.File]::ReadAllText($agentFile, [System.Text.Encoding]::UTF8)
# Write-Host goes to the information stream, so every stream is merged here.
$cliOutput = (& $Router -Route -Agent "code-reviewer" -Apply -Root $Root -TimeoutSec 20 *>&1 | Out-String)
$cliExit = $LASTEXITCODE
$caseOk = (Write-Check "CLI exits 0" ($cliExit -eq 0)) -and $caseOk
$caseOk = (Write-Check "CLI prints the routed model" ($cliOutput -match 'ROUTE\s*:\s*opencode/ling-3.0-flash-fin-free')) -and $caseOk
$caseOk = (Write-Check "CLI applied the model to the agent file" ((Get-AgentFileModel -Path $agentFile) -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

$cliBackups = @(Get-ChildItem -LiteralPath $AgentsDir -Filter "code-reviewer.json.bak.*" -File)
$caseOk = (Write-Check "CLI created a backup" ($cliBackups.Count -ge 1)) -and $caseOk

[System.IO.File]::WriteAllText($agentFile, $textBefore, $script:Utf8NoBom)
$caseOk = (Write-Check "agent file restored to the pre-apply content" ((Get-AgentFileModel -Path $agentFile) -eq "opencode/big-pickle")) -and $caseOk

Close-Case "g) cli apply" $caseOk

# --- h) runtime config fallback ---------------------------------------------

Write-Host ""
Write-Host "CASE: h) opencode debug config fallback"
$caseOk = $true
Set-CliMode "config-json"

$runtimeModel = Get-RuntimeConfigModel -Agent "qa-engineer" -Root $Root -TimeoutSec 20
$caseOk = (Write-Check "runtime config model is read from debug config JSON" ($runtimeModel -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

$env:FAKE_MODEL_CLI_CONFIG_JSON = '{"agent":{"dev-z":{"model":"opencode/nemotron-3.5-lightning-free"}}}'
$runtimeModel2 = Get-RuntimeConfigModel -Agent "dev-z" -Root $Root -TimeoutSec 20
$caseOk = (Write-Check "custom debug config payload is parsed" ($runtimeModel2 -eq "opencode/nemotron-3.5-lightning-free")) -and $caseOk

$fallbackModel = Get-AgentConfiguredModel -Agent "dev-z" -Root $Root
$caseOk = (Write-Check "Get-AgentConfiguredModel falls back to the runtime config" ($fallbackModel -eq "opencode/nemotron-3.5-lightning-free")) -and $caseOk
Remove-Item Env:\FAKE_MODEL_CLI_CONFIG_JSON -ErrorAction SilentlyContinue

$fileModel = Get-AgentConfiguredModel -Agent "qa-engineer" -Root $Root
$caseOk = (Write-Check "agent file wins over the runtime config" ($fileModel -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk

$badAgent = Get-AgentConfiguredModel -Agent "..\..\evil" -Root $Root
$caseOk = (Write-Check "unsafe agent name resolves to nothing" ([string]::IsNullOrEmpty($badAgent))) -and $caseOk

Close-Case "h) runtime config" $caseOk

# --- j) BUG-023: only the first "model" key is rewritten --------------------

Write-Host ""
Write-Host "CASE: j) Set-AgentModel rewrites only the first model key (BUG-023)"
$caseOk = $true

$multiFile = Join-Path $AgentsDir "multi-model.json"
$multiRaw = "{`r`n" +
    "    `"name`":  `"multi-model`",`r`n" +
    "    `"model`":  `"opencode/big-pickle`",`r`n" +
    "    `"permission`": {`r`n" +
    "        `"bash`": {`r`n" +
    "            `"model`":  `"nested/keep-me`"`r`n" +
    "        }`r`n" +
    "    },`r`n" +
    "    `"model_note`":  `"keep-me-too`"`r`n" +
    "}`r`n"
[System.IO.File]::WriteAllText($multiFile, $multiRaw, $script:Utf8NoBom)

$multiApply = Set-AgentModel -Agent "multi-model" -Model "opencode/ling-3.0-flash-fin-free" -Root $Root
$caseOk = (Write-Check "Set-AgentModel succeeds on a multi-model file" ($multiApply.ok -eq $true)) -and $caseOk
$caseOk = (Write-Check "Set-AgentModel reports the change" ($multiApply.changed -eq $true)) -and $caseOk

$multiAfter = [System.IO.File]::ReadAllText($multiFile, [System.Text.Encoding]::UTF8)
$multiExpected = $multiRaw.Replace('"model":  "opencode/big-pickle"', '"model":  "opencode/ling-3.0-flash-fin-free"')
$caseOk = (Write-Check "first model key gets the routed model" ([regex]::Match($multiAfter, '(?m)^\s*"model"\s*:\s*"([^"]*)"').Groups[1].Value -eq "opencode/ling-3.0-flash-fin-free")) -and $caseOk
$caseOk = (Write-Check "exactly one model key was changed" (([regex]::Matches($multiAfter, '"model"\s*:\s*"opencode/ling-3.0-flash-fin-free"')).Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "the nested model key is untouched" ($multiAfter -match '"model"\s*:\s*"nested/keep-me"')) -and $caseOk
$caseOk = (Write-Check "non-model keys are untouched" (($multiAfter -match '"model_note"') -and ($multiAfter -match '"permission"'))) -and $caseOk
$caseOk = (Write-Check "the file is byte-identical apart from the first key" ($multiAfter -eq $multiExpected)) -and $caseOk

Close-Case "j) first model key only" $caseOk

# --- k) BUG-024: locked, atomic health-state writes --------------------------

Write-Host ""
Write-Host "CASE: k) health state is lock-guarded and swapped in atomically (BUG-024)"
$caseOk = $true
Reset-HealthState

for ($i = 1; $i -le 8; $i++) {
    $null = Set-ModelHealthResult -Model ("seq/model-" + $i) -Status "DEAD" -Root $Root
}
$sequentialMissing = 0
for ($i = 1; $i -le 8; $i++) {
    if ($null -eq (Read-StateEntry -Model ("seq/model-" + $i))) { $sequentialMissing++ }
}
$caseOk = (Write-Check "8 sequential writes keep all 8 records" ($sequentialMissing -eq 0)) -and $caseOk

# A lock held by another writer must not crash this writer: warn and continue.
$lockPath = Get-ModelHealthLockPath -Root $Root
$lockHolder = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$busyOutput = @(Set-ModelHealthResult -Model "busy/model" -Status "OK" -Root $Root -LockTimeoutMs 100 3>&1)
$lockHolder.Dispose()
$busyWarnings = @($busyOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
$caseOk = (Write-Check "a busy lock produces a warning instead of an exception" ($busyWarnings.Count -ge 1)) -and $caseOk
$caseOk = (Write-Check "the record is still written when the lock is unavailable" ($null -ne (Read-StateEntry -Model "busy/model"))) -and $caseOk

$residue = @(Get-ChildItem -LiteralPath $MemoryDir -File -Force | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.bak.*" })
$caseOk = (Write-Check "the tmp+swap write leaves no residue" ($residue.Count -eq 0)) -and $caseOk

$stateParses = $true
try {
    $null = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    $stateParses = $false
}
$caseOk = (Write-Check "state file stays valid JSON after the swap" $stateParses) -and $caseOk

# Separate processes writing different models must not lose each other's record.
$workers = @()
foreach ($worker in 1..4) {
    $workers += Start-Job -ScriptBlock {
        param($RouterPath, $JobRoot, $Worker)
        . $RouterPath
        $null = Set-ModelHealthResult -Model ("job/model-" + $Worker) -Status "DEAD" -Root $JobRoot
    } -ArgumentList $Router, $Root, $worker
}
Wait-Job -Job $workers -Timeout 60 | Out-Null

$jobMissing = 0
foreach ($worker in 1..4) {
    if ($null -eq (Read-StateEntry -Model ("job/model-" + $worker))) { $jobMissing++ }
}
$jobsStillRunning = @($workers | Where-Object { $_.State -eq "Running" }).Count
Remove-Job -Job $workers -Force -ErrorAction SilentlyContinue

$caseOk = (Write-Check "4 concurrent writers all finish" ($jobsStillRunning -eq 0)) -and $caseOk
$caseOk = (Write-Check "4 concurrent writers leave 4 records" ($jobMissing -eq 0)) -and $caseOk
$caseOk = (Write-Check "concurrent writers keep the earlier records" (($null -ne (Read-StateEntry -Model "busy/model")) -and ($null -ne (Read-StateEntry -Model "seq/model-8")))) -and $caseOk

$stateJson = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$recordCount = @($stateJson.PSObject.Properties).Count
$caseOk = (Write-Check "no record was lost (8 sequential + 1 busy + 4 concurrent)" ($recordCount -eq 13)) -and $caseOk

Close-Case "k) state locking" $caseOk

# --- summary + cleanup ------------------------------------------------------

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

if ($null -ne $originalRoot) { $env:AGENT_HQ_ROOT = $originalRoot } else { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
if ($null -ne $originalCli) { $env:AGENT_HQ_OPENCODE = $originalCli } else { Remove-Item Env:\AGENT_HQ_OPENCODE -ErrorAction SilentlyContinue }
if ($null -ne $originalMode) { $env:FAKE_MODEL_CLI_MODE = $originalMode } else { Remove-Item Env:\FAKE_MODEL_CLI_MODE -ErrorAction SilentlyContinue }
if ($null -ne $originalConfigJson) { $env:FAKE_MODEL_CLI_CONFIG_JSON = $originalConfigJson } else { Remove-Item Env:\FAKE_MODEL_CLI_CONFIG_JSON -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
