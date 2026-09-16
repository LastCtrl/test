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
#   - A lease whose JSON cannot be read is retried before it is acted on; on a
#     persistent read failure the stale scan (not a fresh LastWriteTime) decides,
#     so a transient read glitch can never keep a hung lease alive (BUG-019).
#   - A corrupt lease is rebuilt on heartbeat.

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
# Attempt bookkeeping (MINOR #5): the lease's "attempt" must grow when a stale
# lease is revoked and the task is claimed again. The lease itself is deleted on
# revoke, so the last attempt is carried over in a tiny sibling marker file
# (<leaf>.attempt) that the stale scan deliberately ignores (*.claim.json only).
# ---------------------------------------------------------------------------
function Get-ClaimAttemptMarkerPath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )
    $dir = Get-TaskStateDir -StateDir $StateDir
    $leaf = (Get-ClaimFileName -TaskId $TaskId) -replace '\.claim\.json$', ''
    return (Join-Path $dir "$leaf.attempt")
}

function Read-ClaimAttemptMarker {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )
    $marker = Get-ClaimAttemptMarkerPath -TaskId $TaskId -StateDir $StateDir
    $read = Read-ClaimDataChecked -Path $marker
    if (-not $read.ok -or $null -eq $read.data) { return 0 }
    if (-not $read.data.PSObject.Properties['attempt']) { return 0 }
    $value = 0
    if ([int]::TryParse([string]$read.data.attempt, [ref]$value) -and $value -gt 0) { return $value }
    return 0
}

function Set-ClaimAttemptMarker {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [int]$Attempt,
        [string]$StateDir
    )
    try {
        $marker = Get-ClaimAttemptMarkerPath -TaskId $TaskId -StateDir $StateDir
        $dir = Split-Path $marker -Parent
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $json = ([PSCustomObject]@{ attempt = [int]$Attempt }) | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($marker, $json, $TaskStateUtf8NoBom)
    } catch {
        Write-Warning "Set-ClaimAttemptMarker: task '$TaskId' marker write failed: $($_.Exception.Message)"
    }
}

function Clear-ClaimAttemptMarker {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [string]$StateDir
    )
    try {
        $marker = Get-ClaimAttemptMarkerPath -TaskId $TaskId -StateDir $StateDir
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Marker cleanup is best-effort; a stale marker only over-counts attempts.
    }
}

# ---------------------------------------------------------------------------
# Read + parse a lease file WITH bounded retries and an explicit outcome, so a
# caller can tell "genuinely missing" apart from "transiently unreadable"
# (antivirus/indexer or a FileShare.None writer opening the same path).
# Returns a PSCustomObject:
#   ok=$true , reason='ok'      -> data = parsed lease
#   ok=$true , reason='missing' -> no file
#   ok=$true , reason='empty'   -> file was empty on every try
#   ok=$true , reason='corrupt' -> file readable but not valid JSON
#   ok=$false, reason='io: ...' -> unreadable after every retry
# ---------------------------------------------------------------------------
function Read-ClaimDataChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 2,
        [int]$RetryDelayMs = 120
    )

    $out = [PSCustomObject]@{
        ok     = $false
        data   = $null
        reason = ""
        path   = $Path
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $out.ok = $true
        $out.reason = "missing"
        return $out
    }

    $attempts = [Math]::Max(1, $Retries + 1)
    for ($i = 0; $i -lt $attempts; $i++) {
        $text = $null
        try {
            # FileShare.ReadWrite: a concurrent writer must not block the reader
            # and vice versa (claim correctness never depends on exclusion).
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $reader = New-Object System.IO.StreamReader($fs, $TaskStateUtf8NoBom)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally {
                $fs.Close()
            }
        } catch {
            # Most likely a sharing violation (a CreateNew with FileShare.None in
            # flight) or an AV/indexer holding the file: retry before giving up.
            $out.ok = $false
            $out.reason = "io: " + $_.Exception.Message
            if ($i -lt ($attempts - 1)) { Start-Sleep -Milliseconds $RetryDelayMs; continue }
            return $out
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($i -lt ($attempts - 1)) { Start-Sleep -Milliseconds $RetryDelayMs; continue }
            $out.ok = $true
            $out.reason = "empty"
            return $out
        }

        try {
            $out.data = $text | ConvertFrom-Json -ErrorAction Stop
            $out.ok = $true
            $out.reason = "ok"
            return $out
        } catch {
            # Half-written JSON is possible: retry, then report it as corrupt
            # (readable, but not parseable) instead of a transient I/O error.
            if ($i -lt ($attempts - 1)) { Start-Sleep -Milliseconds $RetryDelayMs; continue }
            $out.ok = $true
            $out.reason = "corrupt"
            $out.data = $null
            return $out
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Read + parse a lease file. Returns the object, or $null when missing/empty,
# corrupt, or unreadable after the retries. Thin wrapper over the checked reader
# so existing callers keep their simple $null contract.
# ---------------------------------------------------------------------------
function Read-ClaimData {
    param([Parameter(Mandatory = $true)][string]$Path)
    $read = Read-ClaimDataChecked -Path $Path
    return $read.data
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
        [int]$Attempt = 0,
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

    # MINOR #5: never hard-code attempt=1. An explicit -Attempt wins; otherwise a
    # previous revoke's marker (if any) is carried forward, so re-claims count up.
    $attemptValue = 0
    if ($Attempt -gt 0) {
        $attemptValue = [int]$Attempt
    } else {
        $attemptValue = (Read-ClaimAttemptMarker -TaskId $TaskId -StateDir $StateDir) + 1
    }

    $claim = [ordered]@{
        task_id       = $TaskId
        agent         = $Agent
        claimed_at    = $now
        heartbeat_at  = $now
        lease_seconds = [int]$LeaseSeconds
        attempt       = [int]$attemptValue
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
    # Claim succeeded: the carried-over attempt marker has been consumed.
    Clear-ClaimAttemptMarker -TaskId $TaskId -StateDir $StateDir
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

    $read = Read-ClaimDataChecked -Path $path
    if (-not $read.ok) {
        # Transient read failure: do NOT rebuild, or a valid lease would lose its
        # owner/agent fields. Report failure; the caller may retry/revoke later.
        Write-Warning "Update-Heartbeat: lease for task '$TaskId' is temporarily unreadable: $($read.reason)"
        return $false
    }
    $data = $read.data
    if ($null -eq $data) {
        # Genuinely missing/empty/corrupt lease: rebuild a minimal valid one so
        # the claim stays trackable.
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
        # Optional owner guard (RISK-001b): when the caller states its agent, a
        # lease owned by somebody else is never deleted (e.g. a fresh lease taken
        # after this caller was considered timed out). Empty = legacy behaviour.
        [string]$Agent = "",
        [string]$StateDir
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }

    $path = Get-ClaimPath -TaskId $TaskId -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }

    if (-not [string]::IsNullOrWhiteSpace($Agent)) {
        $read = Read-ClaimDataChecked -Path $path
        if (-not $read.ok) {
            # Ownership cannot be verified during a transient read failure: keep
            # the lease (revoke will eventually collect it) instead of risking a
            # foreign lease deletion.
            Write-Warning "Release-Task: lease for task '$TaskId' unreadable ($($read.reason)); not releasing"
            return $false
        }
        if ($null -ne $read.data -and $read.data.PSObject.Properties['agent']) {
            $owner = [string]$read.data.agent
            if (-not [string]::IsNullOrWhiteSpace($owner) -and $owner -ne $Agent) {
                Write-Warning "Release-Task: task '$TaskId' is owned by '$owner', not '$Agent' — lease kept"
                return $false
            }
        }
    }

    try { [System.IO.File]::Delete($path) } catch { }
    $gone = -not (Test-Path -LiteralPath $path -PathType Leaf)
    if ($gone) { Clear-ClaimAttemptMarker -TaskId $TaskId -StateDir $StateDir }
    return $gone
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

    $read = Read-ClaimDataChecked -Path $path
    if ($null -ne $read.data) { return $read.data }
    if ($read.reason -eq "corrupt") {
        Write-Warning "Get-Claim: lease for task '$TaskId' is corrupt (invalid JSON): $path"
    } elseif (-not $read.ok) {
        # Transient unavailability (FileShare.None window, AV/indexer): a "corrupt"
        # warning here would be a false positive, so stay silent and return $null.
        Write-Verbose "Get-Claim: lease for task '$TaskId' temporarily unreadable: $($read.reason)"
    }
    return $null
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
# the scan keeps its claim. NOTE: this is a best-effort check-then-delete with a
# small TOCTOU window (a heartbeat could still land between the re-check and the
# Delete) — the window is tiny and a lost re-claim is recoverable, but it is NOT
# a strictly race-free "no lost-update" guarantee (MINOR #4).
# A transient read failure is NEVER treated as "fresh" (BUG-019): the scan's age
# decides, and every skip/failure is logged instead of being swallowed.
# ---------------------------------------------------------------------------
function Revoke-StaleClaims {
    param(
        [int]$TtlSeconds = $TaskStateDefaultLeaseSeconds,
        [string]$StateDir
    )

    $revoked = @()
    $stale = @(Get-StaleClaims -TtlSeconds $TtlSeconds -StateDir $StateDir)
    $now = Get-Date

    foreach ($s in $stale) {
        $path = [string]$s.claim_path
        $taskId = [string]$s.task_id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        # Bounded retry read: distinguishes a transient sharing violation from a
        # genuinely stale lease, and never falls back to a fresh LastWriteTime.
        $read = Read-ClaimDataChecked -Path $path -Retries 3 -RetryDelayMs 150

        $hb = $null
        if ($read.ok -and $null -ne $read.data -and $read.data.PSObject.Properties['heartbeat_at']) {
            $hb = ConvertTo-ClaimTime $read.data.heartbeat_at
        }

        if ($null -ne $hb) {
            if (($now - $hb).TotalSeconds -le $TtlSeconds) {
                # Heartbeat landed after the scan -> the owner is alive; keep it.
                Write-Verbose "Revoke-StaleClaims: task '$taskId' heartbeat is fresh; lease kept"
                continue
            }
        } elseif ($read.ok) {
            Write-Warning "Revoke-StaleClaims: lease for task '$taskId' is $($read.reason); revoking on stale scan age $($s.age_seconds)s"
        } else {
            Write-Warning "Revoke-StaleClaims: lease for task '$taskId' unreadable after retries ($($read.reason)); revoking on stale scan age $($s.age_seconds)s"
        }

        # Carry the last attempt over so a re-claim increments it (MINOR #5).
        $prevAttempt = 1
        if ($read.ok -and $null -ne $read.data -and $read.data.PSObject.Properties['attempt']) {
            $parsedAttempt = 0
            if ([int]::TryParse([string]$read.data.attempt, [ref]$parsedAttempt) -and $parsedAttempt -gt 0) {
                $prevAttempt = $parsedAttempt
            }
        }
        Set-ClaimAttemptMarker -TaskId $taskId -Attempt $prevAttempt -StateDir $StateDir

        try {
            [System.IO.File]::Delete($path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $revoked += $s
            } else {
                Write-Warning "Revoke-StaleClaims: lease for task '$taskId' still present after delete"
            }
        } catch {
            Write-Warning "Revoke-StaleClaims: failed to delete stale lease for task '$taskId': $($_.Exception.Message)"
        }
    }
    return $revoked
}
