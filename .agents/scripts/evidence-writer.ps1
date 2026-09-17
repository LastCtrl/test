# evidence-writer.ps1 - machine-generated evidence for the inbox-poller pipeline (P0-C).
#
# PURPOSE: an agent's self-report is NOT proof. This helper is dot-sourced by
# inbox-poller.ps1 so that the RUNTIME (the poller, not the model under test)
# appends tamper-evident records describing every opencode attempt:
# exit code, stdout/stderr hashes and lengths, timing, git state, host, pid.
#
# File layout: .memory\evidence\<task_id>.json
#   { "task_id": "<id>", "attempts": [ <record>, ... ] }
# Written atomically (temp file + Move-Item -Force), UTF-8 without BOM.
#
# Pure PowerShell 5.1. No secrets are ever written or logged here.

$script:EvidenceBase = if ($env:AGENT_HQ_ROOT) {
    $env:AGENT_HQ_ROOT
} elseif ($PSScriptRoot) {
    Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
} else {
    (Get-Location).Path
}
$script:EvidenceDir = Join-Path (Join-Path $script:EvidenceBase ".memory") "evidence"
$script:EvidenceUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-EvidenceDir {
    return $script:EvidenceDir
}

function Initialize-EvidenceDir {
    if (-not (Test-Path -LiteralPath $script:EvidenceDir)) {
        New-Item -ItemType Directory -Path $script:EvidenceDir -Force | Out-Null
    }
}

# Relative (repo-root) path embedded into outbox/dead-letter `evidence` fields.
function Get-EvidenceRelativePath {
    param([string]$TaskId)
    return (".memory/evidence/" + $TaskId + ".json")
}

# Lowercase hex SHA-256 of a UTF-8 string. $null is treated as "".
function Get-TextSha256 {
    param([string]$Text)
    if ($null -eq $Text) { $Text = "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

# Lowercase hex SHA-256 of a file, or $null when the file is missing/unreadable.
function Get-FileSha256 {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try {
                return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
            } finally {
                $stream.Dispose()
            }
        } finally {
            $sha.Dispose()
        }
    } catch {
        return $null
    }
}

# Git state of the evidence base directory. Never throws when git is absent or
# the base is not a repository: both values fall back to "".
function Get-GitInfo {
    $info = [PSCustomObject]@{ git_head = ""; git_diff_sha256 = "" }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $info }
    try {
        $head = & git -C $script:EvidenceBase rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $head) {
            $info.git_head = (@($head) -join "`n").Trim()
        }
    } catch {
        $info.git_head = ""
    }
    try {
        $diff = & git -C $script:EvidenceBase diff 2>$null
        $info.git_diff_sha256 = Get-TextSha256 ((@($diff) -join "`n"))
    } catch {
        $info.git_diff_sha256 = ""
    }
    return $info
}

# Append one attempt record to .memory\evidence\<TaskId>.json (atomic write).
# Returns the relative evidence path so callers can embed it into the message.
function Write-EvidenceRecord {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)]$Record
    )

    Initialize-EvidenceDir
    $file = Join-Path $script:EvidenceDir ($TaskId + ".json")

    $attempts = @()
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($existing -and $existing.attempts) { $attempts = @($existing.attempts) }
        } catch {
            $attempts = @()
        }
    }
    $attempts += $Record

    $document = [ordered]@{
        task_id  = $TaskId
        attempts = $attempts
    }
    $json = $document | ConvertTo-Json -Depth 6

    $tmp = $file + ".tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:EvidenceUtf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $file -Force

    return (Get-EvidenceRelativePath -TaskId $TaskId)
}
