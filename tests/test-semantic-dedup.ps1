# test-semantic-dedup.ps1 - isolated tests for P3 semantic duplicate detection.
# Covers: exact and near duplicates (ids/numbers/case), unrelated tasks stay apart,
# threshold effect, Test-IsDuplicate, JSON validity, empty/broken sources, filters and
# file invariants. Every case uses its own temp root; the repo is never written.
# Exit code: 0 - all checks passed, 1 - at least one FAIL.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Target   = Join-Path $RepoRoot ".agents\scripts\semantic-dedup.ps1"
$TempBase = Join-Path $env:TEMP "agent-hq-semantic-dedup-tests"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
        $script:Pass++
    } else {
        Write-Host ("    FAIL: " + $Label)
        $script:Fail++
    }
}

function New-FixtureRoot {
    param([switch]$Bare)
    $fxRoot = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fxRoot -Force | Out-Null
    if (-not $Bare) {
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\inbox\dev-3") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\inbox\dev-4") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\inbox\dev-5") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\dead-letter") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot ".memory\archive") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $fxRoot "projects\proj") -Force | Out-Null
    }
    return $fxRoot
}

function Remove-FixtureRoot {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function New-InboxMessage {
    param([string]$Id, [string]$To, [string]$Payload)
    return ('{"id":"' + $Id + '","from":"team-lead","to":"' + $To + '","type":"task","priority":"normal","payload":"' + $Payload + '","created":"2026-09-18T10:00:00"}')
}

function Add-MainFixtures {
    param([string]$Path)
    $svc1 = 'Deploy the Agent HQ service #123'
    $svc2 = 'deploy the agent   hq service #456'
    $uniq = 'write unit tests for parser'
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-3\m1.json")  (New-InboxMessage -Id 'm1' -To 'dev-3' -Payload $svc1)
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-3\m2.json")  (New-InboxMessage -Id 'm2' -To 'dev-3' -Payload $svc2)
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-3\m2b.json") (New-InboxMessage -Id 'm2b' -To 'dev-3' -Payload $svc1)
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-4\m3.json")  (New-InboxMessage -Id 'm3' -To 'dev-4' -Payload $uniq)
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-5\n1.json")  (New-InboxMessage -Id 'n1' -To 'dev-5' -Payload 'alpha beta gamma delta')
    Write-FixtureText (Join-Path $Path ".memory\inbox\dev-5\n2.json")  (New-InboxMessage -Id 'n2' -To 'dev-5' -Payload 'alpha beta gamma epsilon')
    $dl = '{"id":"dl1","from":"team-lead","to":"dev-3","type":"failed","priority":"normal","payload":"Deploy the agent hq service #777","status":"failed"}'
    Write-FixtureText (Join-Path $Path ".memory\dead-letter\dl1.json") $dl
    $ar = '{"id":"ar1","from":"dev-3","to":"dev-3","type":"result","priority":"normal","payload":"deploy AGENT hq SERVICE","status":"done"}'
    Write-FixtureText (Join-Path $Path ".memory\archive\dev-3-m1.json") $ar
    $t1 = '{"id":"T1","title":"Deploy the agent HQ service #1","priority":"normal","status":"assigned","assigned_agent":"dev-3"}'
    $t2 = '{"id":"T2","title":"refactor database migrations","priority":"low","status":"queued","assigned_agent":"dev-4"}'
    Write-FixtureText (Join-Path $Path "projects\proj\queue.json") ('{"tasks":[' + $t1 + ',' + $t2 + ']}')
}

function Test-CanonicalCase {
    Write-Check "canon) exact text keeps tokens" ((Get-SemanticCanonicalText -Text 'Deploy the Agent HQ service #123') -eq 'deploy the agent hq service')
    Write-Check "canon) case/space/number variants collapse" ((Get-SemanticCanonicalText -Text 'deploy the agent   hq service #456') -eq 'deploy the agent hq service')
    Write-Check "canon) paths and guids removed" ((Get-SemanticCanonicalText -Text 'fix D:\work\agent-hq\file.ps1 550e8400-e29b-41d4-a716-446655440000 now') -eq 'fix now')
    Write-Check "canon) id token removed" ((Get-SemanticCanonicalText -Text 'close item abc123 please') -eq 'close item please')
    Write-Check "canon) empty stays empty" ((Get-SemanticCanonicalText -Text '   ') -eq '')
    Write-Check "canon) null stays empty" ((Get-SemanticCanonicalText -Text $null) -eq '')
    Write-Check "sim) identical = 1.0" ((Get-SemanticSimilarity -TextA 'deploy the agent hq service' -TextB 'Deploy the Agent HQ service #999') -eq 1.0)
    Write-Check "sim) unrelated = 0.0" ((Get-SemanticSimilarity -TextA 'write unit tests' -TextB 'refactor migrations') -eq 0.0)
    Write-Check "sim) partial = 0.6" ((Get-SemanticSimilarity -TextA 'alpha beta gamma delta' -TextB 'alpha beta gamma epsilon') -eq 0.6)
    Write-Check "sim) empty/empty = 0.0" ((Get-SemanticSimilarity -TextA '' -TextB '') -eq 0.0)
}

function Test-MainScanCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-MainFixtures -Path $fxRoot
        $scan = Get-SemanticScan -Root $fxRoot -Threshold 0.8
        Write-Check "main) 10 items loaded across 4 sources" ($scan.item_count -eq 10)
        Write-Check "main) exactly 1 duplicate group at 0.8" ($scan.group_count -eq 1)
        if ($scan.group_count -eq 1) {
            $group = $scan.groups[0]
            Write-Check "main) group has 6 members" ([int]$group.size -eq 6)
            Write-Check "main) group score 1.0" ([double]$group.score -eq 1.0)
            $sources = @($group.members | ForEach-Object { [string]$_.source })
            Write-Check "main) inbox contributes 3 members" (@($sources | Where-Object { $_ -eq 'inbox' }).Count -eq 3)
            Write-Check "main) dead-letter contributes 1 member" (@($sources | Where-Object { $_ -eq 'dead-letter' }).Count -eq 1)
            Write-Check "main) archive contributes 1 member" (@($sources | Where-Object { $_ -eq 'archive' }).Count -eq 1)
            Write-Check "main) project contributes 1 member" (@($sources | Where-Object { $_ -eq 'project' }).Count -eq 1)
            $ids = @($group.members | ForEach-Object { [string]$_.id })
            Write-Check "main) unrelated m3 excluded from group" (-not ($ids -contains 'm3'))
        } else {
            Write-Check "main) group detail checks skipped (no group)" $false
        }
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-ThresholdCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-MainFixtures -Path $fxRoot
        $low = Get-SemanticScan -Root $fxRoot -Threshold 0.5
        Write-Check "threshold) 0.5 yields 2 groups (partial overlaps join)" ([int]$low.group_count -eq 2)
        $partial = @($low.groups | Where-Object { [int]$_.size -eq 2 })
        Write-Check "threshold) partial-overlap group present at 0.5" ($partial.Count -eq 1)
        $high = Get-SemanticScan -Root $fxRoot -Threshold 0.9
        Write-Check "threshold) 0.9 still keeps only the exact group" ([int]$high.group_count -eq 1)
        $none = Get-SemanticScan -Root $fxRoot -Threshold 1.0
        Write-Check "threshold) 1.0 keeps exact duplicates" ([int]$none.group_count -eq 1)
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-IsDuplicateCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-MainFixtures -Path $fxRoot
        $dup = Test-IsDuplicate -Text 'deploy the Agent HQ service #999' -Root $fxRoot -Threshold 0.8
        Write-Check "isdup) near duplicate detected at 0.8" ([bool]$dup.is_duplicate -and [double]$dup.similarity -eq 1.0)
        Write-Check "isdup) best match is populated" ($null -ne $dup.match -and -not [string]::IsNullOrWhiteSpace([string]$dup.match.id))
        $uniq = Test-IsDuplicate -Text 'completely unrelated unique phrase here' -Root $fxRoot -Threshold 0.8
        Write-Check "isdup) unrelated text not duplicate" (-not [bool]$uniq.is_duplicate)
        $partialLow = Test-IsDuplicate -Text 'alpha beta gamma zeta' -Root $fxRoot -Threshold 0.5
        Write-Check "isdup) partial text duplicate at 0.5" ([bool]$partialLow.is_duplicate -and [double]$partialLow.similarity -eq 0.6)
        $partialHigh = Test-IsDuplicate -Text 'alpha beta gamma zeta' -Root $fxRoot -Threshold 0.85
        Write-Check "isdup) partial text unique at 0.85" (-not [bool]$partialHigh.is_duplicate)
        $empty = Test-IsDuplicate -Text '' -Root $fxRoot -Threshold 0.8
        Write-Check "isdup) empty text not duplicate, no throw" ((-not [bool]$empty.is_duplicate) -and [int]$empty.compared -eq 10)
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-FilterCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-MainFixtures -Path $fxRoot
        $include = @(Get-SemanticItems -Root $fxRoot -Include @('dev-3'))
        Write-Check "filter) include dev-3 = 6 items" ($include.Count -eq 6)
        $exclude = @(Get-SemanticItems -Root $fxRoot -Exclude @('dev-3'))
        Write-Check "filter) exclude dev-3 = 4 items" ($exclude.Count -eq 4)
        $excludeGroups = @(Find-SemanticDuplicateGroups -Items $exclude -Threshold 0.8)
        Write-Check "filter) no duplicates left after excluding dev-3" ($excludeGroups.Count -eq 0)
        $csv = @(Get-SemanticItems -Root $fxRoot -Include @('dev-3,dev-4'))
        Write-Check "filter) comma-joined include = 8 items" ($csv.Count -eq 8)
    } finally { Remove-FixtureRoot $fxRoot }
}

function Test-EmptyAndBrokenCase {
    $bare = New-FixtureRoot -Bare
    try {
        $ok = $true
        $scan = $null
        try { $scan = Get-SemanticScan -Root $bare -Threshold 0.8 } catch { $ok = $false }
        Write-Check "empty) bare root scan does not throw" $ok
        Write-Check "empty) bare root has 0 items / 0 groups" ($ok -and [int]$scan.item_count -eq 0 -and [int]$scan.group_count -eq 0)
        $query = $null
        try { $query = Test-IsDuplicate -Text 'anything at all' -Root $bare -Threshold 0.8 } catch { $ok = $false }
        Write-Check "empty) IsDuplicate on bare root is false" ($ok -and (-not [bool]$query.is_duplicate))
    } finally { Remove-FixtureRoot $bare }

    $broken = New-FixtureRoot
    try {
        Write-FixtureText (Join-Path $broken ".memory\inbox\dev-3\bad.json") '{ not json at all'
        Write-FixtureText (Join-Path $broken ".memory\dead-letter\broken.json") '<<<>>>'
        Write-FixtureText (Join-Path $broken ".memory\archive\empty.json") ''
        Write-FixtureText (Join-Path $broken ".memory\inbox\dev-3\null.json") '{"id":"z","to":"dev-3","payload":null}'
        Write-FixtureText (Join-Path $broken "projects\p\queue.json") 'not json'
        $ok = $true
        $scan = $null
        try { $scan = Get-SemanticScan -Root $broken -Threshold 0.8 } catch { $ok = $false }
        Write-Check "broken) scan survives unparseable sources" $ok
        Write-Check "broken) no fake duplicate groups" ($ok -and [int]$scan.group_count -eq 0)
        Write-Check "broken) only the raw broken text becomes an item" ($ok -and [int]$scan.item_count -eq 1)
    } finally { Remove-FixtureRoot $broken }
}

function Test-CliJsonCase {
    $fxRoot = New-FixtureRoot
    try {
        Add-MainFixtures -Path $fxRoot

        $scanText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Scan -Json -Root $fxRoot 2>&1 | Out-String
        $scanExit = $LASTEXITCODE
        $scanParsed = $null
        $scanOk = $true
        try { $scanParsed = $scanText | ConvertFrom-Json } catch { $scanOk = $false }
        Write-Check "cli) -Scan -Json exit 0" ($scanExit -eq 0)
        Write-Check "cli) -Scan -Json valid with 1 group / 10 items" ($scanOk -and [int]$scanParsed.group_count -eq 1 -and [int]$scanParsed.item_count -eq 10)

        $listText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -List -Json -Root $fxRoot 2>&1 | Out-String
        $listExit = $LASTEXITCODE
        $listParsed = $null
        $listOk = $true
        try { $listParsed = $listText | ConvertFrom-Json } catch { $listOk = $false }
        Write-Check "cli) -List -Json exit 0, 10 items" ($listExit -eq 0 -and $listOk -and [int]$listParsed.item_count -eq 10)

        $dupText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -IsDuplicate -Text 'deploy the Agent HQ service #999' -Json -Root $fxRoot 2>&1 | Out-String
        $dupExit = $LASTEXITCODE
        $dupParsed = $null
        $dupOk = $true
        try { $dupParsed = $dupText | ConvertFrom-Json } catch { $dupOk = $false }
        Write-Check "cli) -IsDuplicate -Json true" ($dupExit -eq 0 -and $dupOk -and [bool]$dupParsed.is_duplicate)

        $uniqText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -IsDuplicate -Text 'nothing similar in this corpus' -Json -Root $fxRoot 2>&1 | Out-String
        $uniqParsed = $null
        $uniqOk = $true
        try { $uniqParsed = $uniqText | ConvertFrom-Json } catch { $uniqOk = $false }
        Write-Check "cli) -IsDuplicate -Json false" ($uniqOk -and (-not [bool]$uniqParsed.is_duplicate))

        $lowText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Scan -Threshold 0.5 -Json -Root $fxRoot 2>&1 | Out-String
        $lowParsed = $null
        $lowOk = $true
        try { $lowParsed = $lowText | ConvertFrom-Json } catch { $lowOk = $false }
        Write-Check "cli) -Threshold 0.5 changes group count" ($lowOk -and [int]$lowParsed.group_count -eq 2)

        $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Scan -Root $fxRoot 2>&1 | Out-String
        Write-Check "cli) plain -Scan exit 0" ($LASTEXITCODE -eq 0)
    } finally { Remove-FixtureRoot $fxRoot }

    $emptyRoot = New-FixtureRoot -Bare
    try {
        $emptyText = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Scan -Json -Root $emptyRoot 2>&1 | Out-String
        $emptyExit = $LASTEXITCODE
        $emptyParsed = $null
        $emptyOk = $true
        try { $emptyParsed = $emptyText | ConvertFrom-Json } catch { $emptyOk = $false }
        Write-Check "cli) empty root -Scan -Json valid, exit 0" ($emptyExit -eq 0 -and $emptyOk -and [int]$emptyParsed.group_count -eq 0)
    } finally { Remove-FixtureRoot $emptyRoot }
}

function Test-FileInvariantsCase {
    $targets = @($Target, $PSCommandPath)
    foreach ($target in $targets) {
        $name = Split-Path -Leaf $target
        Write-Check ("inv) " + $name + " exists") (Test-Path -LiteralPath $target -PathType Leaf)
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }

        $bytes = [System.IO.File]::ReadAllBytes($target)
        $nonAscii = 0
        $lf = 0
        $crlf = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -gt 127) { $nonAscii++ }
            if ($bytes[$i] -eq 10) {
                $lf++
                if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
            }
        }
        Write-Check ("inv) " + $name + " CRLF (lone LF = 0)") ((($lf - $crlf) -eq 0) -and ($crlf -gt 0))
        Write-Check ("inv) " + $name + " ASCII-only (no BOM/AMSI noise)") ($nonAscii -eq 0)

        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $target -Raw), [ref]$errors)
        Write-Check ("inv) " + $name + " PSParser 0 errors") ($errors.Count -eq 0)
    }
}

# --- runner ----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
    Write-Host ("FATAL: target script not found: " + $Target)
    exit 1
}
if (-not (Test-Path -LiteralPath $TempBase -PathType Container)) {
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
}

. $Target

$originalRoot = $env:AGENT_HQ_ROOT
try {
    Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    Write-Host "=== semantic-dedup tests ==="

    Test-CanonicalCase
    Test-MainScanCase
    Test-ThresholdCase
    Test-IsDuplicateCase
    Test-FilterCase
    Test-EmptyAndBrokenCase
    Test-CliJsonCase
    Test-FileInvariantsCase
} finally {
    if ([string]::IsNullOrWhiteSpace($originalRoot)) {
        Remove-Item -Path "Env:\AGENT_HQ_ROOT" -ErrorAction SilentlyContinue
    } else {
        $env:AGENT_HQ_ROOT = $originalRoot
    }
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
