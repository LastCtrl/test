# autopilot.ps1 - P3 autonomy levels L0..L3: policy matrix and read-only decision.
param(
    [Alias('Level')][string]$AutopilotLevel = '',
    [Alias('TaskType')][string]$AutopilotTaskType = '',
    [Alias('Confidence')][object]$AutopilotConfidence = $null,
    [Alias('Risk')][string]$AutopilotRisk = '',
    [Alias('Root')][string]$AutopilotRoot = '',
    [Alias('Current')][switch]$AutopilotCurrent,
    [Alias('List')][switch]$AutopilotList,
    [Alias('Policy')][switch]$AutopilotPolicy,
    [Alias('Json')][switch]$AutopilotJson
)

$script:AutopilotScriptRoot = $PSScriptRoot
$script:AutopilotLevels = @('L0', 'L1', 'L2', 'L3')
$script:AutopilotDefaultRisk = @{
    security      = 'high'
    ops           = 'high'
    integration   = 'high'
    code          = 'med'
    data          = 'med'
    review        = 'med'
    test          = 'med'
    '1c'          = 'med'
    orchestration = 'med'
    frontend      = 'med'
    mobile        = 'med'
    docs          = 'low'
    research      = 'low'
    business      = 'low'
}

function Get-AutopilotRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($script:AutopilotScriptRoot) {
        return (Split-Path (Split-Path $script:AutopilotScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function ConvertTo-AutopilotLevel {
    param([string]$Level)
    if ([string]::IsNullOrWhiteSpace($Level)) { return '' }
    $trimmed = $Level.Trim().ToUpperInvariant()
    if ($trimmed -match '^L?([0-3])$') { return ('L' + $Matches[1]) }
    return ''
}

function Get-AutopilotLevelPolicy {
    param([string]$Level)
    $normalized = ConvertTo-AutopilotLevel -Level $Level
    if ([string]::IsNullOrWhiteSpace($normalized)) { $normalized = 'L1' }
    $table = @{
        'L0' = [pscustomobject]@{
            level = 'L0'; name = 'Manual'
            description = 'manual: every step is human driven'
            auto_run = $false; auto_verify = $false; auto_accept = $false
            allow_merge = $false; allow_deploy = $false; human_approval_required = $true
            verification_depth = 'deep'; confidence_floor = 1.0; confidence_threshold = 1.0
        }
        'L1' = [pscustomobject]@{
            level = 'L1'; name = 'Supervised'
            description = 'autonomous run, human acceptance'
            auto_run = $true; auto_verify = $false; auto_accept = $false
            allow_merge = $false; allow_deploy = $false; human_approval_required = $true
            verification_depth = 'standard'; confidence_floor = 0.40; confidence_threshold = 0.75
        }
        'L2' = [pscustomobject]@{
            level = 'L2'; name = 'Assisted'
            description = 'autonomous run and acceptance at high confidence, human otherwise'
            auto_run = $true; auto_verify = $true; auto_accept = $true
            allow_merge = $true; allow_deploy = $false; human_approval_required = $false
            verification_depth = 'standard'; confidence_floor = 0.40; confidence_threshold = 0.75
        }
        'L3' = [pscustomobject]@{
            level = 'L3'; name = 'Autonomous'
            description = 'full autonomy, human only for high risk or low confidence'
            auto_run = $true; auto_verify = $true; auto_accept = $true
            allow_merge = $true; allow_deploy = $true; human_approval_required = $false
            verification_depth = 'light'; confidence_floor = 0.40; confidence_threshold = 0.75
        }
    }
    return $table[$normalized]
}

function Get-AutopilotConfigPath {
    param([string]$Root)
    $resolvedRoot = Get-AutopilotRoot -Root $Root
    return (Join-Path (Join-Path (Join-Path $resolvedRoot '.agents') 'config') 'autopilot.json')
}

function Get-AutopilotCurrentLevel {
    param([string]$Root = '')
    $path = Get-AutopilotConfigPath -Root $Root
    $level = 'L1'
    $source = 'default'
    $configError = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $doc = $null
        try {
            $doc = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $doc = $null
            $configError = 'config-malformed'
            $source = 'default-after-error'
        }
        if ($null -ne $doc) {
            $raw = ''
            foreach ($key in @('default_level', 'defaultLevel', 'current_level', 'currentLevel', 'level')) {
                $candidate = $doc.$key
                if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) { $raw = [string]$candidate; break }
            }
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $source = 'default-no-level'
            } else {
                $normalized = ConvertTo-AutopilotLevel -Level $raw
                if ([string]::IsNullOrWhiteSpace($normalized)) {
                    $source = 'default-invalid-level'
                    $configError = 'config-invalid-level'
                } else {
                    $level = $normalized
                    $source = 'config'
                }
            }
        }
    }
    return [pscustomobject]@{ level = $level; source = $source; config_path = $path; config_error = $configError }
}

function Get-AutopilotPolicy {
    param([string]$Level = '', [string]$Root = '')
    $levelSource = 'explicit'
    $normalized = ConvertTo-AutopilotLevel -Level $Level
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $current = Get-AutopilotCurrentLevel -Root $Root
        $normalized = [string]$current.level
        if ([string]::IsNullOrWhiteSpace($Level)) { $levelSource = [string]$current.source } else { $levelSource = 'invalid-fallback' }
    }
    $policy = Get-AutopilotLevelPolicy -Level $normalized
    return [pscustomobject]@{
        level                   = [string]$policy.level
        name                    = [string]$policy.name
        description             = [string]$policy.description
        level_source            = $levelSource
        auto_run                = [bool]$policy.auto_run
        auto_verify             = [bool]$policy.auto_verify
        auto_accept             = [bool]$policy.auto_accept
        allow_merge             = [bool]$policy.allow_merge
        allow_deploy            = [bool]$policy.allow_deploy
        human_approval_required = [bool]$policy.human_approval_required
        verification_depth      = [string]$policy.verification_depth
        confidence_floor        = [double]$policy.confidence_floor
        confidence_threshold    = [double]$policy.confidence_threshold
    }
}

function Resolve-AutopilotRisk {
    param([string]$Risk, [string]$TaskType)
    $value = ''
    if (-not [string]::IsNullOrWhiteSpace($Risk)) { $value = $Risk.Trim().ToLowerInvariant() }
    if ($value -eq 'medium') { $value = 'med' }
    if ($value -eq 'low' -or $value -eq 'med' -or $value -eq 'high') {
        return [pscustomobject]@{ risk = $value; source = 'explicit' }
    }
    $key = $TaskType.Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($key) -and $script:AutopilotDefaultRisk.ContainsKey($key)) {
        $source = 'default'
        if (-not [string]::IsNullOrWhiteSpace($Risk)) { $source = 'default-invalid-input' }
        return [pscustomobject]@{ risk = [string]$script:AutopilotDefaultRisk[$key]; source = $source }
    }
    $source = 'default-unknown-type'
    if (-not [string]::IsNullOrWhiteSpace($Risk)) { $source = 'default-invalid-input' }
    return [pscustomobject]@{ risk = 'med'; source = $source }
}

function Get-AutopilotConfidenceLevel {
    param([double]$Value)
    if ($Value -ge 0.75) { return 'high' }
    if ($Value -ge 0.40) { return 'med' }
    return 'low'
}

function Get-AutopilotDecision {
    param(
        [string]$TaskType = '',
        [object]$Confidence = $null,
        [string]$Risk = '',
        [string]$Level = '',
        [string]$Root = ''
    )
    $factors = New-Object System.Collections.ArrayList
    $rationale = New-Object System.Collections.ArrayList

    $levelSource = 'explicit'
    $normalizedLevel = ConvertTo-AutopilotLevel -Level $Level
    if ([string]::IsNullOrWhiteSpace($normalizedLevel)) {
        $current = Get-AutopilotCurrentLevel -Root $Root
        $normalizedLevel = [string]$current.level
        if ([string]::IsNullOrWhiteSpace($Level)) {
            $levelSource = [string]$current.source
        } else {
            $levelSource = 'invalid-fallback'
            [void]$factors.Add('levelInvalidFellBackToDefault')
        }
    }
    $policy = Get-AutopilotLevelPolicy -Level $normalizedLevel

    $riskInfo = Resolve-AutopilotRisk -Risk $Risk -TaskType $TaskType
    if ($riskInfo.source -eq 'default') { [void]$factors.Add('riskDefaultForTaskType') }
    if ($riskInfo.source -eq 'default-invalid-input') { [void]$factors.Add('riskInvalidFellBackToDefault') }
    if ($riskInfo.source -eq 'default-unknown-type') { [void]$factors.Add('taskTypeUnknownDefaultMed') }

    $confidenceValue = $null
    $confidenceSource = 'assumed'
    if ($null -ne $Confidence -and -not [string]::IsNullOrWhiteSpace([string]$Confidence)) {
        $parsed = 0.0
        if ([double]::TryParse([string]$Confidence, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            $confidenceValue = $parsed
            $confidenceSource = 'explicit'
            if ($parsed -lt 0.0) { $confidenceValue = 0.0; [void]$factors.Add('confidenceClampedLow') }
            if ($parsed -gt 1.0) { $confidenceValue = 1.0; [void]$factors.Add('confidenceClampedHigh') }
        } else {
            [void]$factors.Add('confidenceInvalidAssumedDefault')
        }
    }
    if ($null -eq $confidenceValue) {
        $confidenceValue = 0.5
        $confidenceSource = 'assumed'
        [void]$factors.Add('confidenceAssumedDefault')
    }
    $confidenceValue = [math]::Round([double]$confidenceValue, 2)
    $confidenceLevel = Get-AutopilotConfidenceLevel -Value $confidenceValue

    $decision = 'needs-human'
    $reasons = New-Object System.Collections.ArrayList
    if ($normalizedLevel -eq 'L0') {
        $decision = 'needs-human'
        [void]$reasons.Add('levelManual')
        [void]$rationale.Add('level L0 keeps every step manual')
    } elseif ($riskInfo.risk -eq 'high') {
        $decision = 'needs-human'
        [void]$reasons.Add('highRisk')
        [void]$rationale.Add('risk high requires a human decision at any level')
    } elseif ($confidenceLevel -eq 'low') {
        $decision = 'needs-human'
        [void]$reasons.Add('lowConfidence')
        [void]$rationale.Add('confidence ' + $confidenceValue + ' is low, a human decision is required')
    } elseif ($normalizedLevel -eq 'L1') {
        $decision = 'run'
        [void]$reasons.Add('autoRunManualAcceptance')
        [void]$rationale.Add('level L1 allows an autonomous run, acceptance stays manual')
    } elseif ($normalizedLevel -eq 'L2') {
        if ($confidenceLevel -eq 'high') {
            $decision = 'promote'
            [void]$reasons.Add('autoAcceptHighConfidence')
            [void]$rationale.Add('level L2 auto accepts at high confidence')
        } else {
            $decision = 'needs-human'
            [void]$reasons.Add('manualAcceptanceBelowThreshold')
            [void]$rationale.Add('level L2 needs a human acceptance below high confidence')
        }
    } elseif ($normalizedLevel -eq 'L3') {
        if ($confidenceLevel -eq 'high') {
            $decision = 'promote'
            [void]$reasons.Add('fullAutoHighConfidence')
            [void]$rationale.Add('level L3 promotes automatically at high confidence')
        } else {
            $decision = 'verify'
            [void]$reasons.Add('autoVerifyMediumConfidence')
            [void]$rationale.Add('level L3 runs deeper automated verification at medium confidence')
        }
    }

    $requiresHuman = $false
    $humanStage = 'none'
    if ($decision -eq 'needs-human') {
        $requiresHuman = $true
        $humanStage = 'before-run'
    } elseif ($decision -eq 'run' -and [bool]$policy.human_approval_required) {
        $requiresHuman = $true
        $humanStage = 'acceptance'
    }

    $verificationDepth = [string]$policy.verification_depth
    if ($decision -eq 'needs-human') { $verificationDepth = 'deep' }
    elseif ($decision -eq 'verify' -and $verificationDepth -eq 'light') { $verificationDepth = 'deep' }

    $autoRun = [bool]$policy.auto_run -and ($decision -eq 'run' -or $decision -eq 'verify' -or $decision -eq 'promote')
    $autoAccept = [bool]$policy.auto_accept -and $decision -eq 'promote'
    $allowMerge = [bool]$policy.allow_merge -and $decision -eq 'promote'
    $allowDeploy = [bool]$policy.allow_deploy -and $decision -eq 'promote'

    [void]$rationale.Add('risk ' + $riskInfo.risk + ' (source ' + $riskInfo.source + ')')
    [void]$rationale.Add('confidence ' + $confidenceValue + ' (' + $confidenceLevel + ', source ' + $confidenceSource + ')')
    [void]$rationale.Add('level ' + $normalizedLevel + ' (source ' + $levelSource + ')')
    [void]$rationale.Add('decision ' + $decision)

    return [pscustomobject]@{
        decision             = $decision
        reasons              = @($reasons)
        task_type            = $TaskType
        level                = $normalizedLevel
        level_source         = $levelSource
        risk                 = $riskInfo.risk
        risk_source          = $riskInfo.source
        confidence           = $confidenceValue
        confidence_level     = $confidenceLevel
        confidence_source    = $confidenceSource
        requires_human       = $requiresHuman
        human_stage          = $humanStage
        auto_run             = $autoRun
        auto_accept          = $autoAccept
        allow_merge          = $allowMerge
        allow_deploy         = $allowDeploy
        verification_depth   = $verificationDepth
        confidence_floor     = [double]$policy.confidence_floor
        confidence_threshold = [double]$policy.confidence_threshold
        rationale            = @($rationale)
        factors              = @($factors)
    }
}

function ConvertTo-AutopilotAsciiJson {
    param([object]$Object)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $Object -Depth 8 } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { return 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $wantsPolicy = [bool]$AutopilotPolicy
        if (-not $wantsPolicy -and $AutopilotCurrent -and [string]::IsNullOrWhiteSpace($AutopilotTaskType)) { $wantsPolicy = $true }
        if ($AutopilotList) {
            $levels = @()
            if (-not [string]::IsNullOrWhiteSpace($AutopilotLevel)) {
                $levels = @(Get-AutopilotLevelPolicy -Level $AutopilotLevel)
            } else {
                foreach ($name in $script:AutopilotLevels) { $levels += (Get-AutopilotLevelPolicy -Level $name) }
            }
            if ($AutopilotJson) {
                Write-Output (ConvertTo-AutopilotAsciiJson -Object ([pscustomobject]@{ mode = 'list'; count = @($levels).Count; levels = @($levels) }))
            } else {
                Write-Host ('=== autopilot levels: ' + @($levels).Count + ' ===') -ForegroundColor Cyan
                foreach ($policy in @($levels)) {
                    Write-Host ('  ' + $policy.level + ' ' + $policy.name + ' - ' + $policy.description)
                    Write-Host ('    run={0} verify={1} accept={2} merge={3} deploy={4} human={5} depth={6} threshold={7}' -f $policy.auto_run, $policy.auto_verify, $policy.auto_accept, $policy.allow_merge, $policy.allow_deploy, $policy.human_approval_required, $policy.verification_depth, $policy.confidence_threshold)
                }
            }
        } elseif ($wantsPolicy) {
            $policy = Get-AutopilotPolicy -Level $AutopilotLevel -Root $AutopilotRoot
            if ($AutopilotJson) {
                Write-Output (ConvertTo-AutopilotAsciiJson -Object $policy)
            } else {
                Write-Host ('=== autopilot policy: ' + $policy.level + ' ' + $policy.name + ' ===') -ForegroundColor Cyan
                Write-Host ('  ' + $policy.description)
                Write-Host ('  auto_run={0} auto_verify={1} auto_accept={2} allow_merge={3} allow_deploy={4}' -f $policy.auto_run, $policy.auto_verify, $policy.auto_accept, $policy.allow_merge, $policy.allow_deploy)
                Write-Host ('  human_approval_required={0} verification_depth={1} confidence_floor={2} confidence_threshold={3}' -f $policy.human_approval_required, $policy.verification_depth, $policy.confidence_floor, $policy.confidence_threshold)
                Write-Host ('  level_source=' + $policy.level_source)
            }
        } else {
            $decision = Get-AutopilotDecision -TaskType $AutopilotTaskType -Confidence $AutopilotConfidence -Risk $AutopilotRisk -Level $AutopilotLevel -Root $AutopilotRoot
            if ($AutopilotJson) {
                Write-Output (ConvertTo-AutopilotAsciiJson -Object $decision)
            } else {
                Write-Host ('=== autopilot decision: ' + $decision.decision + ' ===') -ForegroundColor Cyan
                Write-Host ('  task_type={0} level={1} ({2})' -f $decision.task_type, $decision.level, $decision.level_source)
                Write-Host ('  risk={0} ({1}) confidence={2} ({3})' -f $decision.risk, $decision.risk_source, $decision.confidence, $decision.confidence_level)
                Write-Host ('  requires_human={0} human_stage={1}' -f $decision.requires_human, $decision.human_stage)
                Write-Host ('  auto_run={0} auto_accept={1} allow_merge={2} allow_deploy={3} depth={4}' -f $decision.auto_run, $decision.auto_accept, $decision.allow_merge, $decision.allow_deploy, $decision.verification_depth)
                foreach ($line in @($decision.rationale)) { Write-Host ('  - ' + $line) }
            }
        }
    } catch {
        Write-Error ('autopilot failed: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
