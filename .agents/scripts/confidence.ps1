# confidence.ps1 - P3 confidence-aware scoring: 0..1 per task from machine facts.
param(
    [Alias('TaskId')][string]$ConfidenceTaskId = '',
    [Alias('Agent')][string]$ConfidenceAgent = '',
    [Alias('Root')][string]$ConfidenceRoot = '',
    [Alias('BufferPath')][string]$ConfidenceBufferPath = '',
    [Alias('Json')][switch]$ConfidenceJson
)

$script:ConfidenceScriptRoot = $PSScriptRoot
$script:ConfidenceFailedStatuses = @('failed', 'failure', 'error', 'timeout', 'timed-out', 'blocked', 'dead', 'cancelled', 'canceled')
$script:ConfidenceFailureScript = Join-Path $script:ConfidenceScriptRoot 'failure-memory.ps1'
$script:ConfidenceReviewScript = Join-Path $script:ConfidenceScriptRoot 'review-disagreement.ps1'
$script:ConfidenceFailureAvailable = $false
$script:ConfidenceVerdictsAvailable = $false
if (Test-Path -LiteralPath $script:ConfidenceFailureScript -PathType Leaf) {
    try {
        . $script:ConfidenceFailureScript
        $script:ConfidenceFailureAvailable = $true
    } catch {
        $script:ConfidenceFailureAvailable = $false
    }
}
if (Test-Path -LiteralPath $script:ConfidenceReviewScript -PathType Leaf) {
    try {
        . $script:ConfidenceReviewScript
        $script:ConfidenceVerdictsAvailable = $true
    } catch {
        $script:ConfidenceVerdictsAvailable = $false
    }
}

function Get-ConfidenceRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($script:ConfidenceScriptRoot) {
        return (Split-Path (Split-Path $script:ConfidenceScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-ConfidenceEvidenceFile {
    param([string]$Root, [string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return '' }
    if ($TaskId -notmatch '^[A-Za-z0-9._-]{1,64}$') { return '' }
    return (Join-Path (Join-Path (Join-Path $Root '.memory') 'evidence') ($TaskId + '.json'))
}

function Get-ConfidenceLevel {
    param([double]$Value)
    if ($Value -ge 0.75) { return 'high' }
    if ($Value -ge 0.40) { return 'med' }
    return 'low'
}

function Get-TaskConfidence {
    param(
        [string]$TaskId = '',
        [string]$Root = '',
        [string]$AgentName = '',
        [string]$BufferPath = ''
    )
    $resolvedRoot = Get-ConfidenceRoot -Root $Root
    $factors = New-Object System.Collections.ArrayList
    $confidence = 1.0

    $evidenceExists = $false
    $evidenceMalformed = $false
    $attemptCount = 0
    $failedCount = 0

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        [void]$factors.Add('noTaskId')
        $confidence = 0.0
        return [pscustomobject]@{
            task_id            = ''
            confidence         = 0.0
            level              = 'low'
            factors            = @($factors)
            evidence_exists    = $false
            evidence_malformed = $false
            attempts           = 0
            failed_attempts    = 0
            verdicts_accept    = 0
            verdicts_reject    = 0
            verdicts_partial   = 0
            disagreement       = $false
            failure_memory_hit = $false
        }
    }

    $evidenceFile = Get-ConfidenceEvidenceFile -Root $resolvedRoot -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($evidenceFile)) {
        [void]$factors.Add('taskIdRejectedByGuard')
        $confidence -= 0.50
    } elseif (-not (Test-Path -LiteralPath $evidenceFile -PathType Leaf)) {
        [void]$factors.Add('evidence-missing')
        $confidence -= 0.40
    } else {
        $evidenceExists = $true
        $doc = $null
        try {
            $doc = [System.IO.File]::ReadAllText($evidenceFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $doc = $null
        }
        if ($null -eq $doc) {
            $evidenceMalformed = $true
            [void]$factors.Add('evidence-malformed')
            $confidence -= 0.50
        } else {
            $attempts = @($doc.attempts)
            $attemptCount = $attempts.Count
            if ($attemptCount -eq 0) {
                [void]$factors.Add('no-attempts')
                $confidence -= 0.30
            } else {
                foreach ($attempt in $attempts) {
                    if ($null -eq $attempt) { continue }
                    $hasExit = ($null -ne $attempt.exit_code) -and (-not [string]::IsNullOrWhiteSpace([string]$attempt.exit_code))
                    $exit = 0
                    if ($hasExit) { [void][int]::TryParse([string]$attempt.exit_code, [ref]$exit) }
                    $status = ([string]$attempt.status).ToLowerInvariant()
                    $isFailure = $false
                    if ($hasExit -and ($exit -ne 0)) { $isFailure = $true }
                    elseif ($script:ConfidenceFailedStatuses -contains $status) { $isFailure = $true }
                    if ($isFailure) { $failedCount++ }
                }
                if ($failedCount -gt 0) {
                    $penalty = [math]::Min(0.30 * $failedCount, 0.60)
                    $confidence -= $penalty
                    [void]$factors.Add('failed-attempts=' + $failedCount)
                }
                if ($failedCount -eq $attemptCount) {
                    $confidence -= 0.10
                    [void]$factors.Add('all-attempts-failed')
                }
            }
        }
    }

    $acceptCount = 0
    $rejectCount = 0
    $partialCount = 0
    if ($script:ConfidenceVerdictsAvailable) {
        $verdicts = @()
        try { $verdicts = @(Get-ReviewVerdicts -Root $resolvedRoot -BufferPath $BufferPath -TaskId $TaskId) } catch { $verdicts = @() }
        if (-not [string]::IsNullOrWhiteSpace($AgentName)) {
            $verdicts = @($verdicts | Where-Object { [string]$_.agent -eq $AgentName })
        }
        foreach ($verdict in $verdicts) {
            if ($null -eq $verdict) { continue }
            $category = [string]$verdict.verdict
            if ($category -eq 'accept') { $acceptCount++ }
            elseif ($category -eq 'reject') { $rejectCount++ }
            elseif ($category -eq 'partial') { $partialCount++ }
        }
        if ($rejectCount -gt 0 -and $acceptCount -gt 0) {
            $confidence -= 0.40
            [void]$factors.Add('mixed-verdicts')
        } elseif ($rejectCount -gt 0) {
            $confidence -= 0.30
            [void]$factors.Add('reviewer-rejected')
        } elseif ($partialCount -gt 0) {
            $confidence -= 0.15
            [void]$factors.Add('partial-verdict')
        } elseif ($acceptCount -gt 0) {
            $confidence += 0.10
            [void]$factors.Add('reviewer-accepted')
        } else {
            [void]$factors.Add('no-verdicts')
        }
    } else {
        [void]$factors.Add('verdicts-unavailable')
    }

    $disagreement = $false
    if ($script:ConfidenceVerdictsAvailable) {
        try {
            $items = @(Find-ReviewDisagreement -Root $resolvedRoot -BufferPath $BufferPath -TaskId $TaskId)
            if ($items.Count -gt 0) {
                $disagreement = $true
                $confidence -= 0.20
                [void]$factors.Add('reviewer-disagreement')
            }
        } catch { }
    }

    $failureHit = $false
    $failureHitCount = 0
    if ($script:ConfidenceFailureAvailable) {
        try {
            $occurrences = @(Get-FailureOccurrences -Root $resolvedRoot | Where-Object { [string]$_.task_id -eq $TaskId })
            $failureHitCount = $occurrences.Count
            if ($failureHitCount -gt 0) {
                $failureHit = $true
                $confidence -= 0.15
                [void]$factors.Add('failure-memory-hit=' + $failureHitCount)
            }
        } catch { }
    }

    if ($confidence -gt 1.0) { $confidence = 1.0 }
    if ($confidence -lt 0.0) { $confidence = 0.0 }
    $confidence = [math]::Round($confidence, 2)

    return [pscustomobject]@{
        task_id            = $TaskId
        confidence         = $confidence
        level              = (Get-ConfidenceLevel -Value $confidence)
        factors            = @($factors)
        evidence_exists    = $evidenceExists
        evidence_malformed = $evidenceMalformed
        attempts           = $attemptCount
        failed_attempts    = $failedCount
        verdicts_accept    = $acceptCount
        verdicts_reject    = $rejectCount
        verdicts_partial   = $partialCount
        disagreement       = $disagreement
        failure_memory_hit = $failureHit
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $result = Get-TaskConfidence -TaskId $ConfidenceTaskId -Root $ConfidenceRoot -AgentName $ConfidenceAgent -BufferPath $ConfidenceBufferPath
        if ($ConfidenceJson) {
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
            Write-Host ('=== task confidence: {0} = {1} ({2}) ===' -f $result.task_id, $result.confidence, $result.level) -ForegroundColor Cyan
            Write-Host ('  evidence: exists={0} malformed={1} attempts={2} failed={3}' -f $result.evidence_exists, $result.evidence_malformed, $result.attempts, $result.failed_attempts)
            Write-Host ('  verdicts: accept={0} reject={1} partial={2} disagreement={3}' -f $result.verdicts_accept, $result.verdicts_reject, $result.verdicts_partial, $result.disagreement)
            Write-Host ('  factors : ' + (@($result.factors) -join ', '))
        }
    } catch {
        Write-Error ('confidence failed: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
