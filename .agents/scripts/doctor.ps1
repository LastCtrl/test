<#
.SYNOPSIS
    agent-hq doctor - единая (read-only) самодиагностика здоровья флота.

.DESCRIPTION
    Сводит разрозненные проверки (health-check / verify-phase / model-router /
    bash-policy / review-disagreement / tests) в ОДНУ точку входа с человеко-
    читаемой сводкой ([OK]/[WARN]/[FAIL]) и машинным -Json режимом.

    Секции:
      ENV                   - opencode CLI / git / node доступны, версии, cwd vs root
      CONFIG                - opencode.json парсится и проходит schema-проверку top-level
                              ключей, число агентов/скиллов, repo bash-политика синхронна
                              канону из bash-policy.ps1 (единый источник)
      MODELS                - состояние breaker'ов из .memory\model-health.json (OK vs OPEN)
      QUEUE                 - inbox / outbox / dead-letter / claims counts + stale claims
      TESTS                 - критичные тесты (полный набор или -Fast подмножество)
      EVIDENCE/DISAGREEMENT - расхождения вердиктов проверяющих + записи о нарушениях

    Read-only: doctor НИЧЕГО не пишет под корнем репозитория. Внешние команды
    (opencode/git/node) и тесты запускаются в фоновых job'ах с явным таймаутом,
    поэтому зависший CLI не может подвесить doctor. Job'ы всегда снимаются
    (Stop-Job/Remove-Job), осиротевших процессов не остаётся.

.PARAMETER Fast
    Прогнать только критичное подмножество тестов
    (vault, pipeline, discovery, bash-policy, model-router).
.PARAMETER Json
    Вывести машинный JSON-отчёт вместо человекочитаемой сводки.
.PARAMETER NoTests
    Пропустить секцию TESTS целиком (не помечается WARN).
.PARAMETER TimeoutSec
    Таймаут на одну внешнюю команду (opencode/git/node) в секундах (по умолчанию 20).
.PARAMETER TestTimeoutSec
    Таймаут на один тестовый скрипт в секундах (по умолчанию 180).
.PARAMETER Root
    Явный корень репозитория (иначе $env:AGENT_HQ_ROOT, иначе выводится из
    расположения скрипта <root>\.agents\scripts).

.OUTPUTS
    Exit code: 0 - нет ни WARN, ни FAIL; 2 - только WARN; 1 - есть хотя бы один FAIL.

.EXAMPLE
    .\doctor.ps1 -NoTests
.EXAMPLE
    .\doctor.ps1 -Fast
.EXAMPLE
    .\doctor.ps1 -Fast -Json
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Json,
    [switch]$NoTests,
    [int]$TimeoutSec = 20,
    [int]$TestTimeoutSec = 180,
    [string]$Root = ''
)

$ErrorActionPreference = 'Continue'
# В -Json режиме предупреждения dot-source/ридеров не должны попадать в stdout:
# иначе JSON перестанет парситься. В human-режиме они остаются видимыми.
if ($Json) { $WarningPreference = 'SilentlyContinue' }

$script:DoctorFastTestNames = @(
    'test-vault.ps1',
    'test-pipeline.ps1',
    'test-discovery.ps1',
    'test-bash-policy.ps1',
    'test-model-router.ps1'
)
$script:DoctorRecursionGuard = 'test-doctor.ps1'
$script:DoctorPassportMaxAgeDays = 30

# ===========================================================================
# Helpers
# ===========================================================================

function Get-DoctorRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function New-DoctorSection {
    param([string]$Name)

    return [pscustomobject]@{
        name   = $Name
        checks = (New-Object System.Collections.ArrayList)
    }
}

function Add-DoctorCheck {
    param(
        [Parameter(Mandatory = $true)]$Section,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )

    [void]$Section.checks.Add([pscustomobject]@{
        name   = $Name
        status = $Status
        detail = $Detail
    })
}

function Get-DoctorSectionStatus {
    param($Section)

    $status = 'OK'
    foreach ($check in $Section.checks) {
        if ($check.status -eq 'FAIL') { return 'FAIL' }
        if ($check.status -eq 'WARN') { $status = 'WARN' }
    }
    return $status
}

# Внешняя команда в отдельном job'е: гарантированный таймаут, никаких
# осиротевших процессов (Stop-Job + Remove-Job на каждом пути).
function Invoke-DoctorCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 20
    )

    $result = [pscustomobject]@{
        started   = $false
        ok        = $false
        exit_code = -1
        output    = ''
        timed_out = $false
        error     = ''
    }

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $result.error = 'empty executable path'
        return $result
    }
    if ($TimeoutSec -le 0) { $TimeoutSec = 20 }

    # Задачу передаём ОДНИМ объектом-спеком: плоский -ArgumentList с [string[]]-
    # параметром связывает лишь первый элемент (остальные молча теряются), из-за
    # чего `git -C <path> ...` приходит с одним "-C" и падает. Спек исключает это.
    $spec = [pscustomobject]@{ exe = $FilePath; args = @($Arguments) }

    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($spec)
            $exe = [string]$spec.exe
            $exeArgs = @($spec.args)
            if ($null -eq $exeArgs) { $exeArgs = @() }
            $text = ''
            $code = -1
            try {
                $text = (& $exe @exeArgs 2>&1 | Out-String)
                $code = $LASTEXITCODE
            } catch {
                $text = $_.Exception.Message
                $code = -1
            }
            [pscustomobject]@{ text = $text; code = $code }
        } -ArgumentList (, $spec)
    } catch {
        $result.error = $_.Exception.Message
        return $result
    }

    $completed = Wait-Job -Job $job -Timeout $TimeoutSec
    if ($null -eq $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $result.timed_out = $true
        $result.error = "timed out after ${TimeoutSec}s"
        return $result
    }

    $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $picked = $null
    foreach ($item in @($received)) {
        if (($null -ne $item) -and ($null -ne $item.PSObject.Properties['code'])) { $picked = $item }
    }
    if ($null -eq $picked) {
        $result.output = (@($received) -join "`n")
        $result.exit_code = 0
        $result.started = $true
        $result.ok = $true
        return $result
    }

    $result.output = [string]$picked.text
    $result.exit_code = [int]$picked.code
    $result.started = $true
    $result.ok = ($result.exit_code -eq 0)
    return $result
}

function Get-DoctorFileCount {
    param([string]$Path, [string]$Filter = '*.json')

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue).Count
}

# -Json должен быть переносимым: кириллица в путях иначе зависит от кодовой
# страницы консоли (PS 5.1 пишет stdout в OEM). Экранируем ВСЁ вне ASCII в
# \uXXXX, чтобы stdout оставался чистым ASCII и парсился любым потребителем.
function ConvertTo-DoctorAsciiJson {
    param([string]$Json)

    if ([string]::IsNullOrEmpty($Json)) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Json.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 128) {
            [void]$builder.Append($character)
        } else {
            [void]$builder.Append('\u' + $code.ToString('x4'))
        }
    }
    return $builder.ToString()
}

function Get-DoctorFirstLine {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    foreach ($line in ($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0) {
            if ($trimmed.Length -gt 120) { return $trimmed.Substring(0, 117) + '...' }
            return $trimmed
        }
    }
    return ''
}

# Свежесть паспорта: updated_at разбирается в инвариантной культуре; пустое или
# нечитаемое значение -> WARN, а не исключение (read-only диагностика).
function Get-DoctorPassportFreshness {
    param([string]$UpdatedAt)

    if ([string]::IsNullOrWhiteSpace($UpdatedAt)) {
        return [pscustomobject]@{ ok = $false; detail = 'updated_at is absent' }
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::None
    if (-not [datetime]::TryParse($UpdatedAt, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [pscustomobject]@{ ok = $false; detail = ("updated_at is not parseable: " + $UpdatedAt) }
    }
    $ageDays = [math]::Round(((Get-Date) - $parsed).TotalDays, 1)
    if ($ageDays -lt 0) { $ageDays = 0 }
    if ($ageDays -le $script:DoctorPassportMaxAgeDays) {
        return [pscustomobject]@{ ok = $true; detail = ("updated " + $UpdatedAt + " (" + $ageDays + " day(s) old)") }
    }
    return [pscustomobject]@{ ok = $false; detail = ("stale: updated " + $UpdatedAt + " (" + $ageDays + " day(s) old > " + $script:DoctorPassportMaxAgeDays + ")") }
}

# ===========================================================================
# Root + модули (единственный источник проверок; dot-source только определения)
# ===========================================================================

$doctorRoot = Get-DoctorRoot -Root $Root
$doctorScriptsDir = Join-Path $doctorRoot '.agents\scripts'
$doctorConfigPath = Join-Path $doctorRoot 'opencode.json'
$doctorSchemaPath = Join-Path $doctorRoot 'schemas\opencode.config.schema.json'

$bashPolicyLoaded = $false
$bashPolicyError = ''
$bashPolicyPath = Join-Path $doctorScriptsDir 'bash-policy.ps1'
if (Test-Path -LiteralPath $bashPolicyPath -PathType Leaf) {
    try { . $bashPolicyPath; $bashPolicyLoaded = $true }
    catch { $bashPolicyError = $_.Exception.Message }
} else {
    $bashPolicyError = "missing: $bashPolicyPath"
}

$taskStateLoaded = $false
$taskStateError = ''
$taskStatePath = Join-Path $doctorScriptsDir 'task-state.ps1'
if (Test-Path -LiteralPath $taskStatePath -PathType Leaf) {
    try { . $taskStatePath; $taskStateLoaded = $true }
    catch { $taskStateError = $_.Exception.Message }
} else {
    $taskStateError = "missing: $taskStatePath"
}

$modelRouterLoaded = $false
$modelRouterError = ''
$modelRouterPath = Join-Path $doctorScriptsDir 'model-router.ps1'
if (Test-Path -LiteralPath $modelRouterPath -PathType Leaf) {
    try { . $modelRouterPath; $modelRouterLoaded = $true }
    catch { $modelRouterError = $_.Exception.Message }
} else {
    $modelRouterError = "missing: $modelRouterPath"
}

$reviewLoaded = $false
$reviewError = ''
$reviewPath = Join-Path $doctorScriptsDir 'review-disagreement.ps1'
if (Test-Path -LiteralPath $reviewPath -PathType Leaf) {
    try { . $reviewPath; $reviewLoaded = $true }
    catch { $reviewError = $_.Exception.Message }
} else {
    $reviewError = "missing: $reviewPath"
}

$passportLoaded = $false
$passportLoadError = ''
$passportPath = Join-Path $doctorScriptsDir 'capability-passport.ps1'
if (Test-Path -LiteralPath $passportPath -PathType Leaf) {
    try { . $passportPath; $passportLoaded = $true }
    catch { $passportLoadError = $_.Exception.Message }
} else {
    $passportLoadError = "missing: $passportPath"
}

$sections = New-Object System.Collections.ArrayList

# ===========================================================================
# ENV
# ===========================================================================

$envSection = New-DoctorSection -Name 'ENV'

if (Test-Path -LiteralPath $doctorRoot -PathType Container) {
    Add-DoctorCheck -Section $envSection -Name 'root exists' -Status 'OK' -Detail $doctorRoot
} else {
    Add-DoctorCheck -Section $envSection -Name 'root exists' -Status 'FAIL' -Detail "not a directory: $doctorRoot"
}

$doctorCwd = (Get-Location).Path
if ($doctorCwd -eq $doctorRoot) {
    Add-DoctorCheck -Section $envSection -Name 'cwd equals root' -Status 'OK' -Detail $doctorCwd
} else {
    Add-DoctorCheck -Section $envSection -Name 'cwd equals root' -Status 'WARN' -Detail "cwd=$doctorCwd root=$doctorRoot"
}

Add-DoctorCheck -Section $envSection -Name 'PowerShell version' -Status 'OK' -Detail $PSVersionTable.PSVersion.ToString()

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    Add-DoctorCheck -Section $envSection -Name 'git available' -Status 'FAIL' -Detail 'git not found in PATH'
} else {
    $gitVersion = Invoke-DoctorCommand -FilePath $gitCommand.Source -Arguments @('--version') -TimeoutSec $TimeoutSec
    if ($gitVersion.timed_out) {
        Add-DoctorCheck -Section $envSection -Name 'git available' -Status 'WARN' -Detail "version probe timed out after ${TimeoutSec}s"
    } elseif ($gitVersion.ok) {
        Add-DoctorCheck -Section $envSection -Name 'git available' -Status 'OK' -Detail (Get-DoctorFirstLine $gitVersion.output)
    } else {
        Add-DoctorCheck -Section $envSection -Name 'git available' -Status 'FAIL' -Detail "git --version exit=$($gitVersion.exit_code)"
    }

    $gitRepo = Invoke-DoctorCommand -FilePath $gitCommand.Source -Arguments @('-C', $doctorRoot, 'rev-parse', '--is-inside-work-tree') -TimeoutSec $TimeoutSec
    if ($gitRepo.timed_out) {
        Add-DoctorCheck -Section $envSection -Name 'git repository' -Status 'WARN' -Detail "probe timed out after ${TimeoutSec}s"
    } elseif ($gitRepo.ok -and ((Get-DoctorFirstLine $gitRepo.output) -eq 'true')) {
        Add-DoctorCheck -Section $envSection -Name 'git repository' -Status 'OK' -Detail 'work tree detected'
    } else {
        Add-DoctorCheck -Section $envSection -Name 'git repository' -Status 'WARN' -Detail 'root is not inside a git work tree'
    }
}

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $nodeCommand) {
    Add-DoctorCheck -Section $envSection -Name 'node available' -Status 'WARN' -Detail 'node not found in PATH (optional)'
} else {
    $nodeVersion = Invoke-DoctorCommand -FilePath $nodeCommand.Source -Arguments @('--version') -TimeoutSec $TimeoutSec
    if ($nodeVersion.timed_out) {
        Add-DoctorCheck -Section $envSection -Name 'node available' -Status 'WARN' -Detail "version probe timed out after ${TimeoutSec}s"
    } elseif ($nodeVersion.ok) {
        Add-DoctorCheck -Section $envSection -Name 'node available' -Status 'OK' -Detail (Get-DoctorFirstLine $nodeVersion.output)
    } else {
        Add-DoctorCheck -Section $envSection -Name 'node available' -Status 'WARN' -Detail "node --version exit=$($nodeVersion.exit_code)"
    }
}

$opencodeCli = $null
if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_OPENCODE)) {
    $opencodeCli = $env:AGENT_HQ_OPENCODE
} else {
    $opencodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
    if ($null -ne $opencodeCommand) { $opencodeCli = $opencodeCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($opencodeCli)) {
    Add-DoctorCheck -Section $envSection -Name 'opencode CLI available' -Status 'FAIL' -Detail 'opencode not found in PATH (and AGENT_HQ_OPENCODE is empty)'
} else {
    $opencodeVersion = Invoke-DoctorCommand -FilePath $opencodeCli -Arguments @('--version') -TimeoutSec $TimeoutSec
    if ($opencodeVersion.timed_out) {
        Add-DoctorCheck -Section $envSection -Name 'opencode CLI available' -Status 'WARN' -Detail "version probe timed out after ${TimeoutSec}s"
    } elseif ($opencodeVersion.ok) {
        Add-DoctorCheck -Section $envSection -Name 'opencode CLI available' -Status 'OK' -Detail ((Get-DoctorFirstLine $opencodeVersion.output) + ' [' + $opencodeCli + ']')
    } else {
        Add-DoctorCheck -Section $envSection -Name 'opencode CLI available' -Status 'WARN' -Detail "opencode --version exit=$($opencodeVersion.exit_code)"
    }
}

[void]$sections.Add($envSection)

# ===========================================================================
# CONFIG - opencode.json + schema + counts + bash policy sync
# ===========================================================================

$configSection = New-DoctorSection -Name 'CONFIG'
$configObject = $null
$configParsed = $false

if (Test-Path -LiteralPath $doctorConfigPath -PathType Leaf) {
    Add-DoctorCheck -Section $configSection -Name 'opencode.json exists' -Status 'OK' -Detail $doctorConfigPath
    try {
        $configRaw = [System.IO.File]::ReadAllText($doctorConfigPath, [System.Text.Encoding]::UTF8)
        $configObject = $configRaw | ConvertFrom-Json
        $configParsed = $true
        Add-DoctorCheck -Section $configSection -Name 'opencode.json parses' -Status 'OK' -Detail ("$($configRaw.Length) bytes")
    } catch {
        Add-DoctorCheck -Section $configSection -Name 'opencode.json parses' -Status 'FAIL' -Detail $_.Exception.Message
    }
} else {
    Add-DoctorCheck -Section $configSection -Name 'opencode.json exists' -Status 'FAIL' -Detail "not found: $doctorConfigPath"
    Add-DoctorCheck -Section $configSection -Name 'opencode.json parses' -Status 'FAIL' -Detail 'file missing'
}

# Schema-проверка: top-level ключи opencode.json должны быть в $defs.Config.properties
# (та же fail-closed логика, что и Assert-ConfigSchemaKeys в sync-agents.ps1, но read-only).
$schemaOk = $false
if (-not (Test-Path -LiteralPath $doctorSchemaPath -PathType Leaf)) {
    Add-DoctorCheck -Section $configSection -Name 'config schema present' -Status 'FAIL' -Detail "not found: $doctorSchemaPath"
} else {
    Add-DoctorCheck -Section $configSection -Name 'config schema present' -Status 'OK' -Detail $doctorSchemaPath
    if ($configParsed) {
        try {
            $schemaRaw = [System.IO.File]::ReadAllText($doctorSchemaPath, [System.Text.Encoding]::UTF8)
            $schemaObject = $schemaRaw | ConvertFrom-Json
            $configDefProperty = $schemaObject.PSObject.Properties['$defs']
            $allowedKeys = @()
            if (($null -ne $configDefProperty) -and ($null -ne $configDefProperty.Value.Config)) {
                $allowedKeys = @($configDefProperty.Value.Config.properties.PSObject.Properties.Name)
            }
            if ($allowedKeys.Count -eq 0) {
                Add-DoctorCheck -Section $configSection -Name 'config schema top-level keys' -Status 'FAIL' -Detail 'schema has no $defs.Config.properties'
            } else {
                $actualKeys = @($configObject.PSObject.Properties.Name)
                $unknownKeys = @($actualKeys | Where-Object { $allowedKeys -cnotcontains $_ })
                if ($unknownKeys.Count -eq 0) {
                    Add-DoctorCheck -Section $configSection -Name 'config schema top-level keys' -Status 'OK' -Detail "$($actualKeys.Count) key(s) checked"
                    $schemaOk = $true
                } else {
                    Add-DoctorCheck -Section $configSection -Name 'config schema top-level keys' -Status 'FAIL' -Detail ('unknown: ' + ($unknownKeys -join ', '))
                }
            }
        } catch {
            Add-DoctorCheck -Section $configSection -Name 'config schema top-level keys' -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

# Число агентов (opencode.json .agent), fallback на файлы .opencode\agents\*.json
$agentCount = 0
if ($configParsed) {
    $agentProperty = $configObject.PSObject.Properties['agent']
    if ($null -ne $agentProperty) { $agentCount = @($agentProperty.Value.PSObject.Properties.Name).Count }
}
if ($agentCount -eq 0) {
    $agentsDir = Join-Path $doctorRoot '.opencode\agents'
    $agentCount = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'registry.json' }).Count
    if ($agentCount -gt 0) {
        Add-DoctorCheck -Section $configSection -Name 'agents registered' -Status 'WARN' -Detail "$agentCount agent file(s), opencode.json .agent is empty"
    } else {
        Add-DoctorCheck -Section $configSection -Name 'agents registered' -Status 'FAIL' -Detail 'no agents in opencode.json or .opencode\agents'
    }
} elseif ($agentCount -lt 30) {
    Add-DoctorCheck -Section $configSection -Name 'agents registered' -Status 'WARN' -Detail "$agentCount agent(s) (< 30)"
} else {
    Add-DoctorCheck -Section $configSection -Name 'agents registered' -Status 'OK' -Detail "$agentCount agent(s)"
}

# Число скиллов (SKILL.md рекурсивно, включая superpowers\*\)
$skillsCount = 0
$skillsDir = Join-Path $doctorRoot '.agents\skills'
if (Test-Path -LiteralPath $skillsDir -PathType Container) {
    $skillsCount = @(Get-ChildItem -LiteralPath $skillsDir -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count
}
if ($skillsCount -eq 0) {
    Add-DoctorCheck -Section $configSection -Name 'skills discovered' -Status 'FAIL' -Detail "no SKILL.md under $skillsDir"
} else {
    Add-DoctorCheck -Section $configSection -Name 'skills discovered' -Status 'OK' -Detail "$skillsCount SKILL.md"
}

# Bash policy: канон из bash-policy.ps1 должен байт-в-байт совпадать
# с repo top-level permission.bash (единый источник, как в sync-agents.ps1).
if (-not $bashPolicyLoaded) {
    Add-DoctorCheck -Section $configSection -Name 'bash policy in sync' -Status 'FAIL' -Detail ("bash-policy.ps1 unavailable: " + $bashPolicyError)
} else {
    $canonRules = Get-BashPermissionRules
    $canonValidation = Test-BashPolicyObject -Rules $canonRules
    if (-not $canonValidation.Ok) {
        Add-DoctorCheck -Section $configSection -Name 'bash policy in sync' -Status 'FAIL' -Detail ('canon invalid: ' + ($canonValidation.Errors -join '; '))
    } else {
        $repoRules = $null
        try { $repoRules = Get-BashPolicyFromFile -Path $doctorConfigPath } catch { $repoRules = $null }
        if ($null -eq $repoRules) {
            Add-DoctorCheck -Section $configSection -Name 'bash policy in sync' -Status 'FAIL' -Detail 'no top-level permission.bash in opencode.json'
        } elseif (Compare-BashPolicyRules -A $canonRules -B $repoRules) {
            Add-DoctorCheck -Section $configSection -Name 'bash policy in sync' -Status 'OK' -Detail "$($canonRules.Count) rule(s) identical to canon"
        } else {
            Add-DoctorCheck -Section $configSection -Name 'bash policy in sync' -Status 'FAIL' -Detail 'repo permission.bash differs from bash-policy.ps1 canon'
        }
    }
}

[void]$sections.Add($configSection)

# ===========================================================================
# MODELS - breaker state from .memory\model-health.json (model-router logic)
# ===========================================================================

$modelsSection = New-DoctorSection -Name 'MODELS'

if (-not $modelRouterLoaded) {
    Add-DoctorCheck -Section $modelsSection -Name 'model-router available' -Status 'WARN' -Detail ("model-router.ps1 unavailable: " + $modelRouterError)
} else {
    Add-DoctorCheck -Section $modelsSection -Name 'model-router available' -Status 'OK' -Detail $modelRouterPath
    $modelHealthPath = Join-Path $doctorRoot '.memory\model-health.json'
    if (-not (Test-Path -LiteralPath $modelHealthPath -PathType Leaf)) {
        Add-DoctorCheck -Section $modelsSection -Name 'model health state' -Status 'WARN' -Detail 'no .memory\model-health.json yet (run model-router.ps1 -Probe)'
    } else {
        try {
            $modelState = Read-ModelHealthState -Root $doctorRoot
            if ($modelState.Count -eq 0) {
                Add-DoctorCheck -Section $modelsSection -Name 'model health state' -Status 'WARN' -Detail 'state file is empty'
            } else {
                $openModels = New-Object System.Collections.ArrayList
                $healthyCount = 0
                foreach ($modelName in @($modelState.Keys)) {
                    if (Test-ModelOpen -Model $modelName -Root $doctorRoot) {
                        [void]$openModels.Add($modelName)
                    } else {
                        $healthyCount++
                    }
                }
                if ($openModels.Count -gt 0) {
                    Add-DoctorCheck -Section $modelsSection -Name 'breaker state' -Status 'WARN' -Detail ("OPEN: " + ($openModels -join ', ') + " (healthy=$healthyCount)")
                } else {
                    Add-DoctorCheck -Section $modelsSection -Name 'breaker state' -Status 'OK' -Detail "$healthyCount model(s) healthy, 0 OPEN"
                }
            }
        } catch {
            Add-DoctorCheck -Section $modelsSection -Name 'model health state' -Status 'FAIL' -Detail $_.Exception.Message
        }
    }
}

[void]$sections.Add($modelsSection)

# ===========================================================================
# PASSPORT - capability passport: availability, counts, freshness (read-only)
# ===========================================================================

$passportSection = New-DoctorSection -Name 'PASSPORT'

if ((-not $passportLoaded) -and ($null -eq (Get-Command -Name 'Read-PassportDocument' -ErrorAction SilentlyContinue))) {
    Add-DoctorCheck -Section $passportSection -Name 'passport module' -Status 'WARN' -Detail ("capability-passport.ps1 unavailable: " + $passportLoadError)
} else {
    Add-DoctorCheck -Section $passportSection -Name 'passport module' -Status 'OK' -Detail $passportPath
    try {
        $passportDoc = Read-PassportDocument -Root $doctorRoot
        if (-not $passportDoc.ok) {
            Add-DoctorCheck -Section $passportSection -Name 'passport document' -Status 'WARN' -Detail ([string]$passportDoc.error)
        } else {
            $passportAgentCount = @($passportDoc.agents.Keys).Count
            $passportModelCount = @($passportDoc.models.Keys).Count
            if ($passportAgentCount -gt 0 -and $passportModelCount -gt 0) {
                Add-DoctorCheck -Section $passportSection -Name 'passport document' -Status 'OK' -Detail ("$passportAgentCount agent(s), $passportModelCount model(s)")
            } else {
                Add-DoctorCheck -Section $passportSection -Name 'passport document' -Status 'WARN' -Detail ("agents=$passportAgentCount models=$passportModelCount")
            }
            $freshness = Get-DoctorPassportFreshness -UpdatedAt ([string]$passportDoc.updated_at)
            if ($freshness.ok) {
                Add-DoctorCheck -Section $passportSection -Name 'passport freshness' -Status 'OK' -Detail $freshness.detail
            } else {
                Add-DoctorCheck -Section $passportSection -Name 'passport freshness' -Status 'WARN' -Detail $freshness.detail
            }
        }
    } catch {
        Add-DoctorCheck -Section $passportSection -Name 'passport document' -Status 'WARN' -Detail $_.Exception.Message
    }
}

[void]$sections.Add($passportSection)

# ===========================================================================
# QUEUE - inbox / outbox / dead-letter / claims (+ stale)
# ===========================================================================

$queueSection = New-DoctorSection -Name 'QUEUE'

$inboxDir = Join-Path $doctorRoot '.memory\inbox'
$inboxCount = Get-DoctorFileCount -Path $inboxDir -Filter '*.json'
if ($inboxCount -gt 50) {
    Add-DoctorCheck -Section $queueSection -Name 'inbox backlog' -Status 'FAIL' -Detail "$inboxCount message(s) (> 50)"
} elseif ($inboxCount -gt 20) {
    Add-DoctorCheck -Section $queueSection -Name 'inbox backlog' -Status 'WARN' -Detail "$inboxCount message(s) (> 20)"
} else {
    Add-DoctorCheck -Section $queueSection -Name 'inbox backlog' -Status 'OK' -Detail "$inboxCount message(s)"
}

$outboxDir = Join-Path $doctorRoot '.memory\outbox'
$outboxCount = Get-DoctorFileCount -Path $outboxDir -Filter '*.json'
Add-DoctorCheck -Section $queueSection -Name 'outbox messages' -Status 'OK' -Detail "$outboxCount file(s)"

$deadLetterDir = Join-Path $doctorRoot '.memory\dead-letter'
$deadLetterCount = Get-DoctorFileCount -Path $deadLetterDir -Filter '*.json'
if ($deadLetterCount -gt 0) {
    Add-DoctorCheck -Section $queueSection -Name 'dead-letter' -Status 'WARN' -Detail "$deadLetterCount message(s) need triage"
} else {
    Add-DoctorCheck -Section $queueSection -Name 'dead-letter' -Status 'OK' -Detail 'empty'
}

# Claims: корневые шинные lease'ы + per-project lease'ы projects\*\.memory\claims.
$claimsTotal = 0
$staleTotal = 0
$claimScopes = New-Object System.Collections.ArrayList

$rootClaimsDir = Join-Path $doctorRoot '.memory\claims'
[void]$claimScopes.Add($rootClaimsDir)

$projectsDir = Join-Path $doctorRoot 'projects'
if (Test-Path -LiteralPath $projectsDir -PathType Container) {
    foreach ($projectDir in @(Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)) {
        [void]$claimScopes.Add((Join-Path $projectDir.FullName '.memory\claims'))
    }
}

foreach ($scopeDir in $claimScopes) {
    $claimsTotal += Get-DoctorFileCount -Path $scopeDir -Filter '*.claim.json'
    if ($taskStateLoaded) {
        try {
            $staleInScope = @(Get-StaleClaims -StateDir $scopeDir)
            $staleTotal += $staleInScope.Count
        } catch {
            # один нечитаемый scope не должен рушить секцию
        }
    }
}

if ($claimsTotal -gt 0) {
    Add-DoctorCheck -Section $queueSection -Name 'active claims' -Status 'OK' -Detail "$claimsTotal lease(s) across $($claimScopes.Count) scope(s)"
} else {
    Add-DoctorCheck -Section $queueSection -Name 'active claims' -Status 'OK' -Detail 'no active leases'
}

if (-not $taskStateLoaded) {
    Add-DoctorCheck -Section $queueSection -Name 'stale claims' -Status 'WARN' -Detail ("task-state.ps1 unavailable: " + $taskStateError)
} elseif ($staleTotal -gt 0) {
    Add-DoctorCheck -Section $queueSection -Name 'stale claims' -Status 'WARN' -Detail "$staleTotal lease(s) older than TTL"
} else {
    Add-DoctorCheck -Section $queueSection -Name 'stale claims' -Status 'OK' -Detail 'none'
}

[void]$sections.Add($queueSection)

# ===========================================================================
# TESTS - критичные тесты (job + таймаут; test-doctor исключён от рекурсии)
# ===========================================================================

$testsSection = New-DoctorSection -Name 'TESTS'

if ($NoTests) {
    Add-DoctorCheck -Section $testsSection -Name 'test run' -Status 'OK' -Detail 'skipped (-NoTests)'
} else {
    $testsDir = Join-Path $doctorRoot 'tests'
    if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
        Add-DoctorCheck -Section $testsSection -Name 'test run' -Status 'WARN' -Detail "tests directory missing: $testsDir"
    } else {
        $allTests = @(Get-ChildItem -LiteralPath $testsDir -Filter 'test-*.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $script:DoctorRecursionGuard } |
            Sort-Object Name)

        $selectedTests = $allTests
        if ($Fast) {
            $selectedTests = @($allTests | Where-Object { $script:DoctorFastTestNames -contains $_.Name })
        }

        if ($selectedTests.Count -eq 0) {
            Add-DoctorCheck -Section $testsSection -Name 'test run' -Status 'WARN' -Detail 'no matching test-*.ps1 found'
        } else {
            $psExe = Join-Path $PSHOME 'powershell.exe'
            if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

            foreach ($testFile in $selectedTests) {
                $testResult = Invoke-DoctorCommand -FilePath $psExe `
                    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testFile.FullName) `
                    -TimeoutSec $TestTimeoutSec

                if ($testResult.timed_out) {
                    Add-DoctorCheck -Section $testsSection -Name $testFile.Name -Status 'FAIL' -Detail "timed out after ${TestTimeoutSec}s"
                } elseif ($testResult.exit_code -eq 0) {
                    Add-DoctorCheck -Section $testsSection -Name $testFile.Name -Status 'OK' -Detail 'passed'
                } else {
                    $lastLine = Get-DoctorFirstLine $testResult.output
                    Add-DoctorCheck -Section $testsSection -Name $testFile.Name -Status 'FAIL' -Detail ("exit=$($testResult.exit_code) " + $lastLine)
                }
            }
        }
    }
}

[void]$sections.Add($testsSection)

# ===========================================================================
# EVIDENCE/DISAGREEMENT - review-disagreement + violation records
# ===========================================================================

$evidenceSection = New-DoctorSection -Name 'EVIDENCE/DISAGREEMENT'

$bufferPath = Join-Path $doctorRoot 'CONTEXT-BUFFER.md'
if (Test-Path -LiteralPath $bufferPath -PathType Leaf) {
    Add-DoctorCheck -Section $evidenceSection -Name 'context buffer' -Status 'OK' -Detail $bufferPath
} else {
    Add-DoctorCheck -Section $evidenceSection -Name 'context buffer' -Status 'FAIL' -Detail "not found: $bufferPath"
}

if (-not $reviewLoaded) {
    Add-DoctorCheck -Section $evidenceSection -Name 'review disagreements' -Status 'WARN' -Detail ("review-disagreement.ps1 unavailable: " + $reviewError)
} else {
    try {
        $disagreements = @(Find-ReviewDisagreement -Root $doctorRoot)
        if ($disagreements.Count -eq 0) {
            Add-DoctorCheck -Section $evidenceSection -Name 'review disagreements' -Status 'OK' -Detail 'none'
        } else {
            $keys = @($disagreements | ForEach-Object { $_.task_key } | Select-Object -First 8) -join ', '
            Add-DoctorCheck -Section $evidenceSection -Name 'review disagreements' -Status 'WARN' -Detail "$($disagreements.Count) task(s): $keys"
        }
    } catch {
        Add-DoctorCheck -Section $evidenceSection -Name 'review disagreements' -Status 'WARN' -Detail $_.Exception.Message
    }
}

$violationsPath = Join-Path $doctorRoot '.memory\tool-usage-violations.jsonl'
if (Test-Path -LiteralPath $violationsPath -PathType Leaf) {
    $violationCount = @(Get-Content -LiteralPath $violationsPath -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($violationCount -gt 0) {
        Add-DoctorCheck -Section $evidenceSection -Name 'compliance violations' -Status 'WARN' -Detail "$violationCount record(s) in tool-usage-violations.jsonl"
    } else {
        Add-DoctorCheck -Section $evidenceSection -Name 'compliance violations' -Status 'OK' -Detail 'no records'
    }
} else {
    Add-DoctorCheck -Section $evidenceSection -Name 'compliance violations' -Status 'OK' -Detail 'no violation log'
}

[void]$sections.Add($evidenceSection)

# ===========================================================================
# Tally + output
# ===========================================================================

$okCount = 0
$warnCount = 0
$failCount = 0
foreach ($section in $sections) {
    foreach ($check in $section.checks) {
        switch ($check.status) {
            'OK' { $okCount++ }
            'WARN' { $warnCount++ }
            'FAIL' { $failCount++ }
        }
    }
}

if ($failCount -gt 0) {
    $overallStatus = 'FAIL'
    $exitCode = 1
} elseif ($warnCount -gt 0) {
    $overallStatus = 'WARN'
    $exitCode = 2
} else {
    $overallStatus = 'OK'
    $exitCode = 0
}

$modeLabel = 'FULL'
if ($NoTests) { $modeLabel = 'NO-TESTS' }
elseif ($Fast) { $modeLabel = 'FAST (critical tests)' }

if ($Json) {
    $sectionsJson = @()
    foreach ($section in $sections) {
        $checksJson = @()
        foreach ($check in $section.checks) {
            $checksJson += [pscustomobject]@{
                name   = $check.name
                status = $check.status
                detail = $check.detail
            }
        }
        $sectionsJson += [pscustomobject]@{
            name   = $section.name
            status = (Get-DoctorSectionStatus -Section $section)
            checks = $checksJson
        }
    }

    $report = [ordered]@{
        tool       = 'agent-hq-doctor'
        root       = $doctorRoot
        timestamp  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        fast       = [bool]$Fast
        tests_run  = (-not $NoTests)
        sections   = $sectionsJson
        summary    = [ordered]@{
            ok        = $okCount
            warn      = $warnCount
            fail      = $failCount
            status    = $overallStatus
            exit_code = $exitCode
        }
    }
    Write-Output (ConvertTo-DoctorAsciiJson -Json ($report | ConvertTo-Json -Depth 8))
} else {
    Write-Host ''
    Write-Host '=== agent-hq doctor ===' -ForegroundColor Cyan
    Write-Host ("root : " + $doctorRoot)
    Write-Host ("mode : " + $modeLabel)
    Write-Host ("time : " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

    foreach ($section in $sections) {
        $sectionStatus = Get-DoctorSectionStatus -Section $section
        Write-Host ''
        Write-Host ("--- " + $section.name + " [" + $sectionStatus + "] ---") -ForegroundColor Cyan
        foreach ($check in $section.checks) {
            $color = 'Gray'
            if ($check.status -eq 'OK') { $color = 'Green' }
            elseif ($check.status -eq 'WARN') { $color = 'Yellow' }
            elseif ($check.status -eq 'FAIL') { $color = 'Red' }
            $line = '  [' + $check.status + '] ' + $check.name
            if (-not [string]::IsNullOrWhiteSpace($check.detail)) { $line += ' - ' + $check.detail }
            Write-Host $line -ForegroundColor $color
        }
    }

    Write-Host ''
    Write-Host '--- SUMMARY ---' -ForegroundColor Cyan
    Write-Host ("checks: ok=$okCount warn=$warnCount fail=$failCount")
    $summaryColor = 'Green'
    if ($overallStatus -eq 'WARN') { $summaryColor = 'Yellow' }
    elseif ($overallStatus -eq 'FAIL') { $summaryColor = 'Red' }
    Write-Host ("DOCTOR: " + $overallStatus) -ForegroundColor $summaryColor
}

exit $exitCode
