# task-state.ps1 - file-atomic claim/lease state for agent-hq tasks.
#
# Dot-source compatible:
#   . "$PSScriptRoot\task-state.ps1"
# It only DEFINES functions: it never calls exit, never changes the caller's
# $ErrorActionPreference / strict mode, and never emits output on its own.
#
# Atomicity
#   Claim-Task creates the lease file with [System.IO.File]::Open(..., CreateNew,
#   Write, None). CreateNew maps to CREATE_NEW at the OS layer, so exactly one
#   process can create the file: every other concurrent claim throws IOException
#   and gets $false back. That makes "who owns task X" a single-winner decision
#   without any external dependency.
#
# State layout
#   <StateDir> (default <root>\.memory\claims) \ <safe-task-id>.claim.json
#   lease JSON: { task_id, agent, claimed_at, heartbeat_at, lease_seconds, attempt }
#
# Safety
#   - Task ids that are not filename-safe are hashed, so a hostile id such as
#     '..\..\evil' can never escape the claims directory.
#   - A lease whose JSON is unreadable is never trusted blindly: staleness falls
#     back to the file's LastWriteTime, and a corrupt lease is rebuilt on heartbeat.

# Directory this helper was loaded from, captured at dot-source time.
$TaskStateScriptRoot = $PSScriptRoot
$TaskStateUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TaskStateDefaultLeaseSeconds = 900

# ---------------------------------------------------------------------------
# Resolve the claims directory. Explicit -StateDir wins; then $env:AGENT_HQ_ROOT;
# then the repo root derived from this helper's location (<root>\.agents\scripts).
# Resolved at call time so env changes after dot-sourcing are honoured.
# ---------------------------------------------------------------------------
function Get-TaskStateDir {
    param([string]$StateDir)

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        return $StateDir
    }

    $base = $null
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) {
        $base = $env:AGENT_HQ_ROOT
    } elseif ($TaskStateScriptRoot) {
        $base = Split-Path (Split-Path $TaskStateScriptRoot -Parent) -Parent
    } else {
        $base = (Get-Location).Path
    }
    return (Join-Path $base ".memory\claims")
}

# ---------------------------------------------------------------------------
# Map a task id to a filename-safe leaf. Safe ids are used verbatim; anything
# else is hashed (deterministic + collision resistant) and prefixed with 'h'.
# ---------------------------------------------------------------------------
function Get-ClaimFileName {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    if ($TaskId -match '^[A-Za-z0-9._-]{1,200}$') {
        return "$TaskId.claim.json"
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($TaskId)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return "h$($hex.Substring(0, 40)).claim.json"
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Full path to a task's lease file.
# ---------------------------------------------------------------------------
function Get-ClaimPath {
    param(
        # AllowEmptyString: an empty id must reach the $false guard instead of
        # tripping parameter binding (a claim helper returns, it never throws).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )
    $dir = Get-TaskStateDir -StateDir $StateDir
    return (Join-Path $dir (Get-ClaimFileName -TaskId $TaskId))
}

# ---------------------------------------------------------------------------
# Read + parse a lease file. Returns the object, or $null when missing/empty or
# not valid JSON (callers then fall back to file timestamps).
# ---------------------------------------------------------------------------
function Read-ClaimData {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    try {
        # FileShare.ReadWrite: a concurrent writer must not block the reader and
        # vice versa (claim correctness never depends on reader/writer exclusion).
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($fs, $TaskStateUtf8NoBom)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally {
            $fs.Close()
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Atomic rewrite of a JSON file: write to a unique tmp sibling, then replace the
# destination in one rename. Returns $true only when the destination exists with
# the new content. Never throws.
# ---------------------------------------------------------------------------
function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Data
    )

    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Data | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tmp, $json, $TaskStateUtf8NoBom)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($tmp, $Path, $null)
                return (Test-Path -LiteralPath $Path -PathType Leaf)
            } catch {
                # Fall through to move-overwrite (same volume rename).
            }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return (Test-Path -LiteralPath $Path -PathType Leaf)
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Parse an ISO timestamp; returns $null when it is absent/unparseable.
# ---------------------------------------------------------------------------
function ConvertTo-ClaimTime {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

# ---------------------------------------------------------------------------
# Claim-Task: ATOMICALLY take ownership of a task.
#   $true  -> claim created and owned by this caller
#   $false -> already claimed (or the state dir is unusable / write failed)
# ---------------------------------------------------------------------------
function Claim-Task {
    param(
        # AllowEmptyString: an empty id must reach the $false guard instead of
        # tripping parameter binding (a claim helper returns, it never throws).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$Agent = "",
        [int]$LeaseSeconds = $TaskStateDefaultLeaseSeconds,
        [string]$StateDir
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    if ($LeaseSeconds -le 0) { $LeaseSeconds = $TaskStateDefaultLeaseSeconds }

    $dir = Get-TaskStateDir -StateDir $StateDir
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        return $false
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }

    $path = Join-Path $dir (Get-ClaimFileName -TaskId $TaskId)
    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
    $claim = [ordered]@{
        task_id       = $TaskId
        agent         = $Agent
        claimed_at    = $now
        heartbeat_at  = $now
        lease_seconds = [int]$LeaseSeconds
        attempt       = 1
    }

    # --- THE atomic step: CREATE_NEW fails if anyone else already owns the file.
    $handle = $null
    try {
        $handle = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        return $false
    } catch {
        return $false
    }

    $written = $false
    try {
        $writer = New-Object System.IO.StreamWriter($handle, $TaskStateUtf8NoBom)
        try {
            $writer.Write(($claim | ConvertTo-Json -Depth 10 -Compress))
            $writer.Flush()
            $written = $true
        } finally {
            $writer.Dispose()
        }
    } catch {
        $written = $false
    } finally {
        if ($handle) { $handle.Close() }
    }

    if (-not $written) {
        # Never leave a half-initialised lock behind.
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Update-Heartbeat: refresh heartbeat_at with an atomic tmp+replace rewrite.
#   $false when no lease exists (nothing to keep alive).
# ---------------------------------------------------------------------------
function Update-Heartbeat {
    param(
        # AllowEmptyString: an empty id must reach the $false guard instead of
        # tripping parameter binding (a claim helper returns, it never throws).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }

    $path = Get-ClaimPath -TaskId $TaskId -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

    $data = Read-ClaimData -Path $path
    if ($null -eq $data) {
        # Corrupt lease: rebuild a minimal but valid one so it stays trackable.
        $data = [PSCustomObject]@{
            task_id       = $TaskId
            agent         = ""
            claimed_at    = $null
            heartbeat_at  = $null
            lease_seconds = $TaskStateDefaultLeaseSeconds
            attempt       = 1
        }
    }

    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")
    if ($data.PSObject.Properties['heartbeat_at']) { $data.heartbeat_at = $now }
    else { $data | Add-Member -NotePropertyName heartbeat_at -NotePropertyValue $now -Force }
    if (-not $data.PSObject.Properties['claimed_at'] -or -not $data.claimed_at) {
        if ($data.PSObject.Properties['claimed_at']) { $data.claimed_at = $now }
        else { $data | Add-Member -NotePropertyName claimed_at -NotePropertyValue $now -Force }
    }
    if (-not $data.PSObject.Properties['task_id']) {
        $data | Add-Member -NotePropertyName task_id -NotePropertyValue $TaskId -Force
    }

    return (Write-JsonAtomic -Path $path -Data $data)
}

# ---------------------------------------------------------------------------
# Release-Task: drop the lease. Idempotent: $true when the task is unclaimed
# afterwards (including the "was never claimed" case).
# ---------------------------------------------------------------------------
function Release-Task {
    param(
        # AllowEmptyString: an empty id must reach the $false guard instead of
        # tripping parameter binding (a claim helper returns, it never throws).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }

    $path = Get-ClaimPath -TaskId $TaskId -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }

    try { [System.IO.File]::Delete($path) } catch { }
    return (-not (Test-Path -LiteralPath $path -PathType Leaf))
}

# ---------------------------------------------------------------------------
# Get-Claim: read the lease for a task. $null when unclaimed/unreadable.
# ---------------------------------------------------------------------------
function Get-Claim {
    param(
        # AllowEmptyString: an empty id must reach the $false guard instead of
        # tripping parameter binding (a claim helper returns, it never throws).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }

    $path = Get-ClaimPath -TaskId $TaskId -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    $data = Read-ClaimData -Path $path
    if ($null -eq $data) {
        Write-Warning "Get-Claim: lease for task '$TaskId' is unreadable/corrupt: $path"
        return $null
    }
    return $data
}

# ---------------------------------------------------------------------------
# Get-StaleClaims: leases whose heartbeat is older than -TtlSeconds.
# Heartbeat source: heartbeat_at when parseable, else the file's LastWriteTime
# (so a corrupt lease can still expire instead of blocking a task forever).
# ---------------------------------------------------------------------------
function Get-StaleClaims {
    param(
        [int]$TtlSeconds = $TaskStateDefaultLeaseSeconds,
        [string]$StateDir
    )

    if ($TtlSeconds -le 0) { $TtlSeconds = $TaskStateDefaultLeaseSeconds }

    $result = @()
    $dir = Get-TaskStateDir -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $result }

    $files = @(Get-ChildItem -LiteralPath $dir -Filter "*.claim.json" -File -ErrorAction SilentlyContinue)
    $now = Get-Date

    foreach ($f in $files) {
        $data = Read-ClaimData -Path $f.FullName
        $hb = $null
        if ($null -ne $data -and $data.PSObject.Properties['heartbeat_at']) {
            $hb = ConvertTo-ClaimTime $data.heartbeat_at
        }
        if ($null -eq $hb) { $hb = $f.LastWriteTime }

        $age = ($now - $hb).TotalSeconds
        if ($age -le $TtlSeconds) { continue }

        $taskId = $f.BaseName -replace '\.claim$', ''
        if ($null -ne $data -and $data.PSObject.Properties['task_id'] -and $data.task_id) {
            $taskId = [string]$data.task_id
        }
        $agent = ""
        if ($null -ne $data -and $data.PSObject.Properties['agent'] -and $data.agent) {
            $agent = [string]$data.agent
        }

        $result += [PSCustomObject]@{
            task_id      = $taskId
            agent        = $agent
            heartbeat_at = $hb.ToString("yyyy-MM-ddTHH:mm:ss.fff")
            age_seconds  = [int]$age
            claim_path   = $f.FullName
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Revoke-StaleClaims: release every stale lease and return the released list.
# Re-checks each lease right before deleting, so a heartbeat that landed after
# the scan keeps its claim (no lost-update race).
# ---------------------------------------------------------------------------
function Revoke-StaleClaims {
    param(
        [int]$TtlSeconds = $TaskStateDefaultLeaseSeconds,
        [string]$StateDir
    )

    $revoked = @()
    $stale = @(Get-StaleClaims -TtlSeconds $TtlSeconds -StateDir $StateDir)

    foreach ($s in $stale) {
        $path = [string]$s.claim_path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $data = Read-ClaimData -Path $path
        $hb = $null
        if ($null -ne $data -and $data.PSObject.Properties['heartbeat_at']) {
            $hb = ConvertTo-ClaimTime $data.heartbeat_at
        }
        if ($null -eq $hb) {
            try { $hb = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime }
            catch { $hb = $null }
        }
        if ($null -ne $hb -and ((Get-Date) - $hb).TotalSeconds -le $TtlSeconds) { continue }

        try {
            [System.IO.File]::Delete($path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $revoked += $s }
        } catch {
            # Unreadable/held file: leave it for the next stale cycle.
        }
    }
    return $revoked
}
