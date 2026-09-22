# verification-depth.ps1 - P3 dynamic verification depth: light | standard | deep.
param(
    [Alias('TaskType')][string]$DepthTaskType = '',
    [Alias('Risk')][string]$DepthRisk = '',
    [Alias('Confidence')][object]$DepthConfidence = $null,
    [Alias('Agent')][string]$DepthAgent = '',
    [Alias('TaskId')][string]$DepthTaskId = '',
    [Alias('Root')][string]$DepthRoot = '',
    [Alias('Json')][switch]$DepthJson
)

$script:DepthScriptRoot = $PSScriptRoot
$script:DepthDefaultRisk = @{
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
$script:DepthConfidenceScript = Join-Path $script:DepthScriptRoot 'confidence.ps1'
$script:DepthFailureScript = Join-Path $script:DepthScriptRoot 'failure-memory.ps1'
$script:DepthConfidenceAvailable = $false
$script:DepthFailureAvailable = $false
if (Test-Path -LiteralPath $script:DepthConfidenceScript -PathType Leaf) {
    try {
        . $script:DepthConfidenceScript
        $script:DepthConfidenceAvailable = $true
    } catch {
        $script:DepthConfidenceAvailable = $false
    }
}
if (-not $script:DepthFailureAvailable -and (Test-Path -LiteralPath $script:DepthFailureScript -PathType Leaf)) {
    try {
        . $script:DepthFailureScript
        $script:DepthFailureAvailable = $true
    } catch {
        $script:DepthFailureAvailable = $false
    }
}

function Get-DepthRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($script:DepthScriptRoot) {
        return (Split-Path (Split-Path $script:DepthScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-DepthRiskScore {
    param([string]$Risk)
    if ($Risk -eq 'high') { return 2 }
    if ($Risk -eq 'med') { return 1 }
    return 0
}

function Get-DepthConfidenceScore {
    param([double]$Value)
    if ($Value -lt 0.40) { return 2 }
    if ($Value -lt 0.75) { return 1 }
    return 0
}

function Get-DepthLevel {
    param([double]$Value)
    if ($Value -ge 0.75) { return 'high' }
    if ($Value -ge 0.40) { return 'med' }
    return 'low'
}

function Resolve-DepthRisk {
    param([string]$Risk, [string]$TaskType)
    $value = ''
    if (-not [string]::IsNullOrWhiteSpace($Risk)) { $value = $Risk.Trim().ToLowerInvariant() }
    if ($value -eq 'medium') { $value = 'med' }
    if ($value -eq 'low' -or $value -eq 'med' -or $value -eq 'high') {
        return [pscustomobject]@{ risk = $value; source = 'explicit' }
    }
    $key = $TaskType.Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($key) -and $script:DepthDefaultRisk.ContainsKey($key)) {
        $source = 'default'
        if (-not [string]::IsNullOrWhiteSpace($Risk)) { $source = 'default-invalid-input' }
        return [pscustomobject]@{ risk = [string]$script:DepthDefaultRisk[$key]; source = $source }
    }
    $source = 'default-unknown-type'
    if (-not [string]::IsNullOrWhiteSpace($Risk)) { $source = 'default-invalid-input' }
    return [pscustomobject]@{ risk = 'med'; source = $source }
}

function Get-VerificationDepth {
    param(
        [string]$TaskType = '',
        [string]$Risk = '',
        [object]$Confidence = $null,
        [string]$Root = '',
        [string]$TaskId = '',
        [string]$AgentName = ''
    )
    $resolvedRoot = Get-DepthRoot -Root $Root
    $factors = New-Object System.Collections.ArrayList
    $rationale = New-Object System.Collections.ArrayList

    $riskInfo = Resolve-DepthRisk -Risk $Risk -TaskType $TaskType
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
            if ($parsed -lt 0.0) { $confidenceValue = 0.0; [void]$factors.Add('confidence-clamped-low') }
            if ($parsed -gt 1.0) { $confidenceValue = 1.0; [void]$factors.Add('confidence-clamped-high') }
        } else {
            [void]$factors.Add('confidence-invalid-assumed-0.5')
        }
    }
    if ($null -eq $confidenceValue -and -not [string]::IsNullOrWhiteSpace($TaskId) -and $script:DepthConfidenceAvailable) {
        try {
            $measured = Get-TaskConfidence -TaskId $TaskId -Root $resolvedRoot -AgentName $AgentName
            $confidenceValue = [double]$measured.confidence
            $confidenceSource = 'task:' + $TaskId
            [void]$factors.Add('confidence-measured-from-task')
        } catch {
            $confidenceValue = $null
        }
    }
    if ($null -eq $confidenceValue) {
        $confidenceValue = 0.5
        [void]$factors.Add('confidence-assumed-0.5')
    }
    $confidenceValue = [math]::Round([double]$confidenceValue, 2)

    $failureHints = 0
    $openFailureHints = 0
    if ($script:DepthFailureAvailable) {
        try {
            $entries = @(Get-FailureRegistryEntries -Root $resolvedRoot)
            foreach ($entry in $entries) {
                if ([string]$entry.task_type -ne $TaskType.Trim().ToLowerInvariant()) { continue }
                $failureHints++
                if (-not [bool]$entry.fixed) { $openFailureHints++ }
            }
            if ($openFailureHints -gt 0) { [void]$factors.Add('open-failure-memory=' + $openFailureHints) }
        } catch { }
    } else {
        [void]$factors.Add('failure-memory-unavailable')
    }

    $riskScore = Get-DepthRiskScore -Risk $riskInfo.risk
    $confidenceScore = Get-DepthConfidenceScore -Value $confidenceValue
    $score = $riskScore + $confidenceScore + $openFailureHints
    $depth = 'standard'
    if ($score -le 1) { $depth = 'light' }
    elseif ($score -ge 3) { $depth = 'deep' }

    [void]$rationale.Add(('risk=' + $riskInfo.risk + ' (score ' + $riskScore + ') source=' + $riskInfo.source))
    [void]$rationale.Add(('confidence=' + $confidenceValue + ' level=' + (Get-DepthLevel -Value $confidenceValue) + ' (score ' + $confidenceScore + ') source=' + $confidenceSource))
    if ($openFailureHints -gt 0) { [void]$rationale.Add(('open failure-memory signatures for this task type: ' + $openFailureHints + ' (+' + $openFailureHints + ')')) }
    [void]$rationale.Add(('combined score ' + $score + ' -> depth ' + $depth))

    return [pscustomobject]@{
        task_type          = $TaskType
        risk               = $riskInfo.risk
        risk_source        = $riskInfo.source
        confidence         = $confidenceValue
        confidence_level   = (Get-DepthLevel -Value $confidenceValue)
        confidence_source  = $confidenceSource
        score              = $score
        depth              = $depth
        rationale          = @($rationale)
        factors            = @($factors)
        failure_hints      = $failureHints
        open_failure_hints = $openFailureHints
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $result = Get-VerificationDepth -TaskType $DepthTaskType -Risk $DepthRisk -Confidence $DepthConfidence -Root $DepthRoot -TaskId $DepthTaskId -AgentName $DepthAgent
        if ($DepthJson) {
            $json = ''
            try { $json = ConvertTo-Json -InputObject $result -Depth 6 } catch { $json = '' }
            if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
            $builder = New-Object System.Text.StringBuilder
            foreach ($ch in $json.ToCharArray()) {
                $code = [int][char]$ch
                if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
            }
            Write-Output $builder.ToString()
        } else {
            Write-Host ('=== verification depth: ' + $result.depth + ' ===') -ForegroundColor Cyan
            Write-Host ('  task_type={0} risk={1} confidence={2} ({3})' -f $result.task_type, $result.risk, $result.confidence, $result.confidence_level)
            foreach ($line in @($result.rationale)) { Write-Host ('  ' + $line) }
        }
    } catch {
        Write-Error ('verification-depth failed: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
