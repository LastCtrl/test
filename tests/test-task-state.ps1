# test-task-state.ps1 - independent tests for .agents\scripts\task-state.ps1
#
# Pure PowerShell 5.1 (no Pester). Everything runs inside an isolated temp root
# that is exposed to the helper through $env:AGENT_HQ_ROOT, so no real claim
# state of the repository is touched.
#
# Covered:
#   a) atomicity       - 4 parallel processes race for one task id -> exactly 1 wins
#   b) heartbeat       - Update-Heartbeat advances heartbeat_at
#   c) ttl             - aged lease is detected, revoked, and re-claimable
#   d) release         - idempotent (including "never claimed")
#   e) edge cases      - unsafe task id cannot escape the state dir, unknown ids
#                        return $null/$false, empty stale set returns an empty array
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Helper   = Join-Path $RepoRoot ".agents\scripts\task-state.ps1"

$TempBase = Join-Path $env:TEMP "agent-hq-taskstate-tests"
$Root     = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$StateDir = Join-Path $Root ".memory\claims"

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

function Test-PathLeaf {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Get-ClaimFile {
    param([string]$TaskId)
    return (Join-Path $StateDir ($TaskId + ".claim.json"))
}

function Write-AgedLease {
    # Rewrite a lease with an older heartbeat so TTL logic is tested without
    # sleeping for minutes. The helper contract (heartbeat_at) is preserved.
    param([string]$TaskId, [datetime]$HeartbeatAt)
    $path = Get-ClaimFile $TaskId
    $claim = [ordered]@{
        task_id       = $TaskId
        agent         = "aged"
        claimed_at    = $HeartbeatAt.ToString("yyyy-MM-ddTHH:mm:ss.fff")
        heartbeat_at  = $HeartbeatAt.ToString("yyyy-MM-ddTHH:mm:ss.fff")
        lease_seconds = 900
        attempt       = 1
    }
    [System.IO.File]::WriteAllText($path, ($claim | ConvertTo-Json -Compress), $script:Utf8NoBom)
}

# --- setup -----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}
foreach ($rel in @(".memory\claims")) {
    New-Item -ItemType Directory -Path (Join-Path $Root $rel) -Force | Out-Null
}

$env:AGENT_HQ_ROOT = $Root

Write-Host "=== agent-hq task-state (claim/lease) tests ==="
Write-Host ("Helper : " + $Helper)
Write-Host ("Root   : " + $Root)

if (-not (Test-PathLeaf $Helper)) {
    Write-Host ("FATAL: helper not found: " + $Helper)
    exit 1
}

# Syntax gate - a broken helper must fail fast instead of producing odd results.
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $Helper), [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host ("FATAL: helper has " + $parseErrors.Count + " parse error(s)")
    exit 1
}

. $Helper

# --- a) atomicity ----------------------------------------------------------

Write-Host ""
Write-Host "CASE: a) parallel Claim-Task -> exactly one winner"
$caseOk = $true
$raceId = "race-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

$jobCount = 4
$jobs = @()
for ($i = 1; $i -le $jobCount; $i++) {
    $jobs += Start-Job -ScriptBlock {
        param($HelperPath, $ClaimsDir, $TaskId, $Worker)
        . $HelperPath
        return [bool](Claim-Task -TaskId $TaskId -Agent ("worker-" + $Worker) -StateDir $ClaimsDir)
    } -ArgumentList $Helper, $StateDir, $raceId, $i
}

$null = Wait-Job -Job $jobs -Timeout 90
$results = @()
foreach ($j in $jobs) {
    $results += @(Receive-Job -Job $j -ErrorAction SilentlyContinue)
}
Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue

$booleans = @($results | Where-Object { $_ -is [bool] })
$wins = @($booleans | Where-Object { $_ -eq $true })

$caseOk = (Write-Check ("all " + $jobCount + " workers returned a boolean") ($booleans.Count -eq $jobCount)) -and $caseOk
$caseOk = (Write-Check "exactly one worker won the claim" ($wins.Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "lease file created once" (Test-PathLeaf (Get-ClaimFile $raceId))) -and $caseOk

if ($wins.Count -eq 1) {
    $owner = Get-Claim -TaskId $raceId -StateDir $StateDir
    $caseOk = (Write-Check "lease records the winning worker" ([string]$owner.agent -match '^worker-\d$')) -and $caseOk
}

$null = Release-Task -TaskId $raceId -StateDir $StateDir

if ($caseOk) { $script:CasePass++ ; Write-Host "PASS a) atomicity" } else { $script:CaseFail++ ; Write-Host "FAIL a) atomicity" }

# --- b) heartbeat ----------------------------------------------------------

Write-Host ""
Write-Host "CASE: b) Update-Heartbeat advances heartbeat_at"
$caseOk = $true
$hbId = "hb-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

$caseOk = (Write-Check "claim succeeds" (Claim-Task -TaskId $hbId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk
$before = Get-Claim -TaskId $hbId -StateDir $StateDir
Start-Sleep -Milliseconds 1100
$caseOk = (Write-Check "Update-Heartbeat returns true" (Update-Heartbeat -TaskId $hbId -StateDir $StateDir)) -and $caseOk
$after = Get-Claim -TaskId $hbId -StateDir $StateDir

$hbBefore = [datetime]::MinValue
$hbAfter  = [datetime]::MinValue
$beforeParsed = [datetime]::TryParse([string]$before.heartbeat_at, [ref]$hbBefore)
$afterParsed  = [datetime]::TryParse([string]$after.heartbeat_at, [ref]$hbAfter)
$caseOk = (Write-Check "heartbeat_at timestamps are parseable" ($beforeParsed -and $afterParsed)) -and $caseOk
$caseOk = (Write-Check "heartbeat_at moved forward" ($afterParsed -and ($hbAfter -gt $hbBefore))) -and $caseOk
$caseOk = (Write-Check "claimed_at preserved" ([string]$after.claimed_at -eq [string]$before.claimed_at)) -and $caseOk
$caseOk = (Write-Check "agent preserved" ([string]$after.agent -eq "dev-3")) -and $caseOk

$null = Release-Task -TaskId $hbId -StateDir $StateDir

if ($caseOk) { $script:CasePass++ ; Write-Host "PASS b) heartbeat" } else { $script:CaseFail++ ; Write-Host "FAIL b) heartbeat" }

# --- c) TTL / stale revoke -------------------------------------------------

Write-Host ""
Write-Host "CASE: c) aged lease -> Get-StaleClaims -> Revoke -> re-claimable"
$caseOk = $true

$staleId = "stale-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$freshId = "fresh-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

$caseOk = (Write-Check "stale claim succeeds" (Claim-Task -TaskId $staleId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk
$caseOk = (Write-Check "fresh claim succeeds" (Claim-Task -TaskId $freshId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk

Write-AgedLease -TaskId $staleId -HeartbeatAt (Get-Date).AddHours(-2)

$staleDefault = @(Get-StaleClaims -TtlSeconds 900 -StateDir $StateDir)
$caseOk = (Write-Check "fresh lease is NOT reported stale" (@($staleDefault | Where-Object { $_.task_id -eq $freshId }).Count -eq 0)) -and $caseOk
$caseOk = (Write-Check "aged lease IS reported stale" (@($staleDefault | Where-Object { $_.task_id -eq $staleId }).Count -eq 1)) -and $caseOk

$staleShort = @(Get-StaleClaims -TtlSeconds 60 -StateDir $StateDir)
$staleEntry = @($staleShort | Where-Object { $_.task_id -eq $staleId })
$caseOk = (Write-Check "stale entry carries a positive age_seconds" ($staleEntry.Count -eq 1 -and [int]$staleEntry[0].age_seconds -gt 0)) -and $caseOk

$revoked = @(Revoke-StaleClaims -TtlSeconds 60 -StateDir $StateDir)
$caseOk = (Write-Check "Revoke-StaleClaims returned the aged lease" (@($revoked | Where-Object { $_.task_id -eq $staleId }).Count -eq 1)) -and $caseOk
$caseOk = (Write-Check "aged lease file removed" (-not (Test-PathLeaf (Get-ClaimFile $staleId)))) -and $caseOk
$caseOk = (Write-Check "fresh lease survived the revoke" ((Get-Claim -TaskId $freshId -StateDir $StateDir) -ne $null)) -and $caseOk
$caseOk = (Write-Check "re-claim after revoke succeeds" (Claim-Task -TaskId $staleId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk

$null = Release-Task -TaskId $staleId -StateDir $StateDir
$null = Release-Task -TaskId $freshId -StateDir $StateDir

if ($caseOk) { $script:CasePass++ ; Write-Host "PASS c) ttl" } else { $script:CaseFail++ ; Write-Host "FAIL c) ttl" }

# --- d) release idempotency ------------------------------------------------

Write-Host ""
Write-Host "CASE: d) Release-Task is idempotent"
$caseOk = $true
$relId = "rel-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

$caseOk = (Write-Check "claim succeeds" (Claim-Task -TaskId $relId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk
$caseOk = (Write-Check "first release returns true" (Release-Task -TaskId $relId -StateDir $StateDir)) -and $caseOk
$caseOk = (Write-Check "second release returns true" (Release-Task -TaskId $relId -StateDir $StateDir)) -and $caseOk
$caseOk = (Write-Check "Get-Claim is null after release" ((Get-Claim -TaskId $relId -StateDir $StateDir) -eq $null)) -and $caseOk
$caseOk = (Write-Check "release of a never-claimed task returns true" (Release-Task -TaskId ("never-" + $relId) -StateDir $StateDir)) -and $caseOk

if ($caseOk) { $script:CasePass++ ; Write-Host "PASS d) release" } else { $script:CaseFail++ ; Write-Host "FAIL d) release" }

# --- e) edge cases ---------------------------------------------------------

Write-Host ""
Write-Host "CASE: e) edge cases (unsafe id, unknown id, empty stale set)"
$caseOk = $true

$evilId = "..\..\evil-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$caseOk = (Write-Check "unsafe task id is still claimable (hashed leaf)" (Claim-Task -TaskId $evilId -Agent "dev-3" -StateDir $StateDir)) -and $caseOk
$evilClaim = Get-Claim -TaskId $evilId -StateDir $StateDir
$caseOk = (Write-Check "unsafe id round-trips through Get-Claim" ($null -ne $evilClaim -and [string]$evilClaim.task_id -eq $evilId)) -and $caseOk

$outsideClaims = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter "*.claim.json" -File -ErrorAction SilentlyContinue |
    Where-Object { -not $_.FullName.StartsWith($StateDir, [System.StringComparison]::OrdinalIgnoreCase) })
$caseOk = (Write-Check "no claim file escaped the state dir" ($outsideClaims.Count -eq 0)) -and $caseOk

$allClaimsInside = $true
foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter "*.claim.json" -File -ErrorAction SilentlyContinue)) {
    if (-not $f.FullName.StartsWith($StateDir, [System.StringComparison]::OrdinalIgnoreCase)) { $allClaimsInside = $false }
}
$caseOk = (Write-Check "every claim file lives inside the state dir" $allClaimsInside) -and $caseOk

$caseOk = (Write-Check "lease JSON has the required fields" (
    $null -ne $evilClaim -and
    $evilClaim.PSObject.Properties['task_id'] -and
    $evilClaim.PSObject.Properties['agent'] -and
    $evilClaim.PSObject.Properties['claimed_at'] -and
    $evilClaim.PSObject.Properties['heartbeat_at'] -and
    $evilClaim.PSObject.Properties['lease_seconds'] -and
    $evilClaim.PSObject.Properties['attempt']
)) -and $caseOk

$caseOk = (Write-Check "Get-Claim(unknown) is null" ((Get-Claim -TaskId ("unknown-" + $relId) -StateDir $StateDir) -eq $null)) -and $caseOk
$unknownHb = Update-Heartbeat -TaskId ("unknown-" + $relId) -StateDir $StateDir
$caseOk = (Write-Check "Update-Heartbeat(unknown) is false" ($unknownHb -eq $false)) -and $caseOk
$emptyClaim = Claim-Task -TaskId "" -StateDir $StateDir
$caseOk = (Write-Check "Claim-Task(empty id) returns false" ($emptyClaim -eq $false)) -and $caseOk

$null = Release-Task -TaskId $evilId -StateDir $StateDir
$noStale = @(Revoke-StaleClaims -TtlSeconds 60 -StateDir $StateDir)
$caseOk = (Write-Check "Revoke-StaleClaims on empty set returns an empty array" ($noStale.Count -eq 0)) -and $caseOk

if ($caseOk) { $script:CasePass++ ; Write-Host "PASS e) edges" } else { $script:CaseFail++ ; Write-Host "FAIL e) edges" }

# --- summary + cleanup -----------------------------------------------------

$total = $script:CasePass + $script:CaseFail
Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:CasePass + " failed=" + $script:CaseFail + " total=" + $total)
Write-Host "=================================================="

Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($script:CaseFail -gt 0) { exit 1 } else { exit 0 }
