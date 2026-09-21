# snapshot-backoff.ps1 - bounded exponential backoff for opencode snapshot/busy errors.
# Dot-source to use Invoke-SnapshotBackoff / Test-SnapshotRetryable / Get-SnapshotBackoffDelay.
# CLI: -ErrorText '<msg>' classifies an error (exit 2 = retryable, 0 = not retryable, 1 = usage).
# Apply: wrap fragile opencode invocations (agent-hq-daemon, run-poller, run-daemons, CI)
# with Invoke-SnapshotBackoff; classify captured logs via -ErrorText.
param(
    [string]$ErrorText = '',
    [switch]$Json,
    [int]$MaxRetries = 4,
    [int]$BaseDelayMs = 200,
    [int]$MaxDelayMs = 5000,
    [double]$Factor = 2,
    [int]$JitterMs = 0
)

$ErrorActionPreference = 'Continue'

function Test-SnapshotRetryable {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    # snapshot/exclude are matched only as a composed pair: a lone mention of
    # either word (e.g. a fatal "SyntaxError in snapshot.ts") must not retry.
    $patterns = @(
        'Busy:\s*FileSystem',
        'FileSystem\.writeFile',
        'snapshot[^\r\n]{0,40}exclude',
        'exclude[^\r\n]{0,40}snapshot',
        'EPERM',
        'uv_spawn',
        'EBUSY',
        'failed to get diff'
    )
    foreach ($p in $patterns) {
        if ([regex]::IsMatch($Message, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $true }
    }
    return $false
}

function Get-SnapshotBackoffDelay {
    param(
        [int]$Attempt = 1,
        [int]$BaseDelayMs = 200,
        [int]$MaxDelayMs = 5000,
        [double]$Factor = 2,
        [int]$JitterMs = 0
    )
    if ($Attempt -lt 1) { $Attempt = 1 }
    if ($BaseDelayMs -lt 0) { $BaseDelayMs = 0 }
    if ($MaxDelayMs -lt 0) { $MaxDelayMs = 0 }
    if ($Factor -lt 1) { $Factor = 1 }
    if ($JitterMs -lt 0) { $JitterMs = 0 }
    $d = [double]$BaseDelayMs * [math]::Pow([double]$Factor, [double]($Attempt - 1))
    if ($MaxDelayMs -gt 0 -and $d -gt $MaxDelayMs) { $d = [double]$MaxDelayMs }
    $d = [math]::Round($d, 0)
    if ($JitterMs -gt 0) { $d = $d + (Get-Random -Minimum 0 -Maximum ($JitterMs + 1)) }
    if ($d -lt 0) { $d = 0 }
    return [int]$d
}

function Invoke-SnapshotBackoff {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [int]$MaxRetries = 4,
        [int]$BaseDelayMs = 200,
        [int]$MaxDelayMs = 5000,
        [double]$Factor = 2,
        [int]$JitterMs = 0,
        [switch]$NoSleep
    )
    if ($MaxRetries -lt 0) { $MaxRetries = 0 }
    $delays = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    $lastError = ''
    while ($true) {
        $attempt++
        try {
            $result = & $Operation
            return [pscustomobject]@{
                Status     = 'ok'
                Attempts   = $attempt
                MaxRetries = $MaxRetries
                Result     = $result
                LastError  = ''
                Delays     = @($delays)
                ElapsedMs  = $sw.ElapsedMilliseconds
            }
        } catch {
            $lastError = [string]$_.Exception.Message
            if (-not (Test-SnapshotRetryable -Message $lastError)) {
                return [pscustomobject]@{
                    Status     = 'non-retryable'
                    Attempts   = $attempt
                    MaxRetries = $MaxRetries
                    Result     = $null
                    LastError  = $lastError
                    Delays     = @($delays)
                    ElapsedMs  = $sw.ElapsedMilliseconds
                }
            }
            if ($attempt -gt $MaxRetries) {
                return [pscustomobject]@{
                    Status     = 'exhausted'
                    Attempts   = $attempt
                    MaxRetries = $MaxRetries
                    Result     = $null
                    LastError  = $lastError
                    Delays     = @($delays)
                    ElapsedMs  = $sw.ElapsedMilliseconds
                }
            }
            $delay = Get-SnapshotBackoffDelay -Attempt $attempt -BaseDelayMs $BaseDelayMs -MaxDelayMs $MaxDelayMs -Factor $Factor -JitterMs $JitterMs
            $null = $delays.Add($delay)
            if (-not $NoSleep -and $delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {

    if ([string]::IsNullOrWhiteSpace($ErrorText)) {
        Write-Host 'snapshot-backoff: pass -ErrorText "<message>" to classify an error'
        exit 1
    }
    if ($MaxRetries -lt 0) { $MaxRetries = 0 }
    $retryable = Test-SnapshotRetryable -Message $ErrorText
    $delays = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $MaxRetries; $i++) {
        $null = $delays.Add((Get-SnapshotBackoffDelay -Attempt $i -BaseDelayMs $BaseDelayMs -MaxDelayMs $MaxDelayMs -Factor $Factor -JitterMs $JitterMs))
    }
    $advice = if ($retryable) { 'retry with exponential backoff' } else { 'do not retry this error' }
    if ($Json) {
        $obj = [pscustomobject]@{
            retryable      = [bool]$retryable
            maxRetries     = $MaxRetries
            delaysMs       = @($delays)
            recommendation = $advice
        }
        Write-Output ($obj | ConvertTo-Json -Depth 4 -Compress)
    } else {
        if ($retryable) {
            Write-Host 'snapshot-backoff: RETRYABLE (snapshot/busy/EPERM style error)'
            Write-Host ("backoff schedule (ms): {0}" -f ((@($delays)) -join ', '))
            Write-Host ("advice: {0}" -f $advice)
        } else {
            Write-Host 'snapshot-backoff: NOT retryable by this helper'
            Write-Host ("advice: {0}" -f $advice)
        }
    }
    if ($retryable) { exit 2 }
    exit 0
}
