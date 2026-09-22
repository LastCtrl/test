# cost-quality.ps1 - P3 cost/quality frontier: cheapest candidate that clears a grade bar.
#
# Read-only. Ranks passport agents/models by cost tier and by a quality score built
# from acceptance grades minus an open failure-memory penalty. Sources, never guessed:
#   * .agents\config\capability-passport.json - agents/models, cost_tier, capabilities
#   * .agents\config\model-limits.json        - documented cost tier fallback
#   * .memory\ratings.jsonl                   - acceptance grades (avg_grade, samples)
#   * .memory\failure-memory.jsonl            - open failure signatures (penalty)
# Missing data is reported as a data_state, never filled in by assumption.
#
# Environment hook (tests): AGENT_HQ_ROOT. An explicit -Root always wins.
# No param() block on purpose: tests dot-source the file for its functions, so the
# command line is parsed from $args on a direct invocation only.

$script:CostQualityScriptRoot = $PSScriptRoot
$script:CostQualityMinSamples = 2
$script:CostQualityDefaultMinGrade = 6.0
$script:CostQualityFailureWeight = 1.5
$script:CostQualityFailureCap = 4.5
$script:CostQualityCostRank = @{ "free" = 0; "medium" = 1; "paid" = 2; "unknown" = 3 }
$script:CostQualityEvidenced = "ok"

$script:CostQualityPassportScript = Join-Path $script:CostQualityScriptRoot "capability-passport.ps1"
if (Test-Path -LiteralPath $script:CostQualityPassportScript -PathType Leaf) {
    . $script:CostQualityPassportScript
}

function Get-CostQualityRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:CostQualityScriptRoot)) {
        return (Split-Path (Split-Path $script:CostQualityScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-CostQualityPaths {
    param([string]$Root)
    $resolved = Get-CostQualityRoot -Root $Root
    return [pscustomobject]@{
        Root          = $resolved
        Passport      = (Join-Path $resolved ".agents\config\capability-passport.json")
        Limits        = (Join-Path $resolved ".agents\config\model-limits.json")
        Ratings       = (Join-Path $resolved ".memory\ratings.jsonl")
        FailureMemory = (Join-Path $resolved ".memory\failure-memory.jsonl")
    }
}

function Get-CostQualityCostRankValue {
    param([string]$CostTier)
    $tier = ([string]$CostTier).Trim().ToLowerInvariant()
    if ($script:CostQualityCostRank.ContainsKey($tier)) { return [int]$script:CostQualityCostRank[$tier] }
    return 3
}

function Get-CostQualityTier {
    param([string]$Declared, [string]$Model, $TierMap)
    $tier = ([string]$Declared).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($tier) -or ($tier -eq "unknown")) {
        if ((-not [string]::IsNullOrWhiteSpace($Model)) -and ($null -ne $TierMap) -and $TierMap.ContainsKey($Model.ToLowerInvariant())) {
            $tier = ([string]$TierMap[$Model.ToLowerInvariant()]).Trim().ToLowerInvariant()
        }
    }
    if ([string]::IsNullOrWhiteSpace($tier)) { return "unknown" }
    return $tier
}

function Get-CostQualityTierMap {
    param([string]$Root)
    $map = @{}
    $path = (Get-CostQualityPaths -Root $Root).Limits
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $doc = $null
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return $map }
    if (($null -eq $doc) -or ($null -eq $doc.models)) { return $map }
    foreach ($property in $doc.models.PSObject.Properties) {
        $tier = [string]$property.Value.tier
        if (-not [string]::IsNullOrWhiteSpace($tier)) { $map[$property.Name.ToLowerInvariant()] = $tier.Trim().ToLowerInvariant() }
    }
    return $map
}

function Read-CostQualityFailureEntries {
    param([string]$Root)
    $path = (Get-CostQualityPaths -Root $Root).FailureMemory
    $entries = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,@() }
    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $entry = $null
        try { $entry = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $entry) { continue }
        [void]$entries.Add($entry)
    }
    return ,$entries.ToArray()
}

function Get-CostQualityReliability {
    param([string]$Root)
    $map = @{}
    if ($null -eq (Get-Command -Name "Get-ReliabilityIndex" -ErrorAction SilentlyContinue)) { return $map }
    $path = (Get-CostQualityPaths -Root $Root).Ratings
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $index = (Get-ReliabilityIndex -RatingsPath $path).index
    foreach ($key in @($index.Keys)) {
        $stats = $index[$key]
        if ([int]$stats.samples -le 0) { continue }
        $map[[string]$key] = [ordered]@{
            samples   = [int]$stats.samples
            avg_grade = [math]::Round(([double]$stats.grade_sum / [double]$stats.samples), 2)
            source    = "ratings"
        }
    }
    return $map
}

function Get-CostQualityReliabilityFor {
    param($Reliability, $Entry, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    if (($null -ne $Reliability) -and $Reliability.ContainsKey($Key.ToLowerInvariant())) { return $Reliability[$Key.ToLowerInvariant()] }
    $rel = $null
    if ($Entry -is [System.Collections.IDictionary]) { $rel = $Entry["reliability"] }
    if (($rel -is [System.Collections.IDictionary]) -and ($null -ne $rel["avg_grade"]) -and ([int]$rel["samples"] -gt 0)) {
        return [ordered]@{ samples = [int]$rel["samples"]; avg_grade = [double]$rel["avg_grade"]; source = "passport" }
    }
    return $null
}

function Get-CostQualityFailurePenalty {
    param([object[]]$Entries, [string]$Kind, [string]$Key, [string]$CanonicalType)
    $count = 0
    $signatures = New-Object System.Collections.ArrayList
    $keyValue = ([string]$Key).Trim().ToLowerInvariant()
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        if ([bool]$entry.fixed) { continue }
        $type = ([string]$entry.task_type).Trim().ToLowerInvariant()
        if ((-not [string]::IsNullOrWhiteSpace($CanonicalType)) -and ($type -ne $CanonicalType)) { continue }
        if ($Kind -eq "agent") { $owner = ([string]$entry.agent).Trim().ToLowerInvariant() }
        else { $owner = ([string]$entry.model).Trim().ToLowerInvariant() }
        if ([string]::IsNullOrWhiteSpace($owner)) { continue }
        if ($owner -ne $keyValue) { continue }
        $count = $count + [int]$entry.count
        [void]$signatures.Add([string]$entry.signature)
    }
    $penalty = [math]::Min(($count * $script:CostQualityFailureWeight), $script:CostQualityFailureCap)
    return [ordered]@{ count = $count; penalty = [math]::Round($penalty, 2); signatures = @($signatures.ToArray()) }
}

function Get-CostQualityCanonicalType {
    param([string]$TaskType)
    if ([string]::IsNullOrWhiteSpace($TaskType)) { return "" }
    if ($null -eq (Get-Command -Name "Get-PassportCanonicalTokens" -ErrorAction SilentlyContinue)) {
        return $TaskType.Trim().ToLowerInvariant()
    }
    $tokens = Get-PassportCanonicalTokens -Tokens @($TaskType)
    if (@($tokens).Count -eq 0) { return $TaskType.Trim().ToLowerInvariant() }
    return [string]@($tokens)[0]
}

function New-CostQualityCandidate {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$Model,
        [string]$DeclaredTier,
        $TierMap,
        [string[]]$TaskTypes,
        $Reliability,
        $PassportEntry,
        [object[]]$Failures,
        [string]$CanonicalType,
        [int]$MinSamples
    )
    $tier = Get-CostQualityTier -Declared $DeclaredTier -Model $Model -TierMap $TierMap
    $rel = Get-CostQualityReliabilityFor -Reliability $Reliability -Entry $PassportEntry -Key $Name
    $avgGrade = $null
    $samples = 0
    $relSource = ""
    if ($null -ne $rel) {
        if ($null -ne $rel.avg_grade) { $avgGrade = [double]$rel.avg_grade }
        $samples = [int]$rel.samples
        $relSource = [string]$rel.source
    }
    $failure = Get-CostQualityFailurePenalty -Entries $Failures -Kind $Kind -Key $Name -CanonicalType $CanonicalType
    $quality = $null
    if ($null -ne $avgGrade) { $quality = [math]::Round(($avgGrade - [double]$failure.penalty), 2) }
    $dataState = "no-grade"
    if ($null -ne $avgGrade) {
        if ($samples -lt $MinSamples) { $dataState = "low-sample" } else { $dataState = $script:CostQualityEvidenced }
    }
    $declaredTokens = @($TaskTypes)
    if ($null -ne (Get-Command -Name "Get-PassportCanonicalTokens" -ErrorAction SilentlyContinue)) {
        $declaredTokens = @(Get-PassportCanonicalTokens -Tokens @($TaskTypes))
    }
    return [ordered]@{
        kind               = $Kind
        name               = $Name
        model              = $Model
        cost_tier          = $tier
        cost_rank          = (Get-CostQualityCostRankValue -CostTier $tier)
        task_types         = @($TaskTypes)
        declared_tokens    = @($declaredTokens)
        avg_grade          = $avgGrade
        samples            = $samples
        reliability_source = $relSource
        failure_count      = [int]$failure.count
        failure_penalty    = [double]$failure.penalty
        failure_signatures = @($failure.signatures)
        quality            = $quality
        data_state         = $dataState
    }
}

function Get-CostQualityCandidates {
    param([string]$Root, [string]$CanonicalType = "", [int]$MinSamples = 0)
    if ($MinSamples -le 0) { $MinSamples = $script:CostQualityMinSamples }
    $paths = Get-CostQualityPaths -Root $Root
    $out = [ordered]@{
        ok         = $false
        passport   = "ok"
        error      = ""
        path       = $paths.Passport
        candidates = @()
        sources    = [ordered]@{
            passport       = $paths.Passport
            limits         = $paths.Limits
            ratings        = $paths.Ratings
            failure_memory = $paths.FailureMemory
        }
    }
    if ($null -eq (Get-Command -Name "Read-PassportDocument" -ErrorAction SilentlyContinue)) {
        $out.passport = "missing"
        $out.error = "capability-passport.ps1 is not loaded"
        return $out
    }
    $doc = Read-PassportDocument -Root $paths.Root
    $out.path = $doc.path
    if (-not $doc.ok) {
        if (([string]$doc.error) -match "not found") { $out.passport = "missing" } else { $out.passport = "broken" }
        $out.error = $doc.error
        return $out
    }
    $tierMap = Get-CostQualityTierMap -Root $paths.Root
    $reliability = Get-CostQualityReliability -Root $paths.Root
    $failures = Read-CostQualityFailureEntries -Root $paths.Root
    $list = New-Object System.Collections.ArrayList

    foreach ($key in @($doc.agents.Keys)) {
        $entry = $doc.agents[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $model = ""
        if ($null -ne $entry["model"]) { $model = [string]$entry["model"] }
        $declaredTier = ""
        if ($null -ne $entry["cost_tier"]) { $declaredTier = [string]$entry["cost_tier"] }
        $taskTypes = @(Get-PassportTaskTypes -Passport $entry)
        [void]$list.Add((New-CostQualityCandidate -Kind "agent" -Name $name -Model $model -DeclaredTier $declaredTier `
            -TierMap $tierMap -TaskTypes $taskTypes -Reliability $reliability -PassportEntry $entry `
            -Failures $failures -CanonicalType $CanonicalType -MinSamples $MinSamples))
    }

    foreach ($key in @($doc.models.Keys)) {
        $entry = $doc.models[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $declaredTier = ""
        if ($null -ne $entry["cost_tier"]) { $declaredTier = [string]$entry["cost_tier"] }
        $taskTypes = @(Get-PassportTaskTypes -Passport $entry)
        [void]$list.Add((New-CostQualityCandidate -Kind "model" -Name $name -Model $name -DeclaredTier $declaredTier `
            -TierMap $tierMap -TaskTypes $taskTypes -Reliability $reliability -PassportEntry $entry `
            -Failures $failures -CanonicalType $CanonicalType -MinSamples $MinSamples))
    }

    $out.ok = $true
    $out.candidates = @($list.ToArray())
    return $out
}

function Get-CostQualityMatchingCandidates {
    param($Candidates, [string]$CanonicalType)
    $out = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $matched = $true
        if (-not [string]::IsNullOrWhiteSpace($CanonicalType)) {
            if ($null -ne (Get-Command -Name "Test-CapabilityMatch" -ErrorAction SilentlyContinue)) {
                $match = Test-CapabilityMatch -Declared @($candidate.declared_tokens) -Requested $CanonicalType
                $matched = [bool]$match.matched
            } else {
                $matched = (@($candidate.declared_tokens) -contains $CanonicalType)
            }
        }
        if ($matched) { [void]$out.Add($candidate) }
    }
    return @($out.ToArray())
}

function Select-CostQualityCandidate {
    param($Candidates, [double]$MinGrade, [int]$MinSamples)
    $matching = @($Candidates)
    $qualifying = @($matching | Where-Object { ($_.data_state -eq $script:CostQualityEvidenced) -and ($null -ne $_.quality) -and ([double]$_.quality -ge $MinGrade) })
    if ($qualifying.Count -gt 0) {
        $ordered = @($qualifying | Sort-Object -Property `
            @{ Expression = { [int]$_.cost_rank }; Descending = $false }, `
            @{ Expression = { [double]$_.quality }; Descending = $true }, `
            @{ Expression = { [int]$_.samples }; Descending = $true }, `
            @{ Expression = { [string]$_.name }; Descending = $false })
        return [ordered]@{ selected = $ordered[0]; meets = $true }
    }
    $graded = @($matching | Where-Object { $null -ne $_.quality })
    if ($graded.Count -gt 0) {
        $ordered = @($graded | Sort-Object -Property `
            @{ Expression = { if ($_.data_state -eq $script:CostQualityEvidenced) { 1 } else { 0 } }; Descending = $true }, `
            @{ Expression = { [double]$_.quality }; Descending = $true }, `
            @{ Expression = { [int]$_.cost_rank }; Descending = $false }, `
            @{ Expression = { [string]$_.name }; Descending = $false })
        return [ordered]@{ selected = $ordered[0]; meets = $false }
    }
    return [ordered]@{ selected = $null; meets = $false }
}

function Get-CostQualityFrontier {
    param($Candidates)
    $evidenced = @($Candidates | Where-Object { ($null -ne $_) -and ($null -ne $_.quality) -and ($_.data_state -eq $script:CostQualityEvidenced) -and ($_.cost_tier -ne "unknown") })
    $excluded = @($Candidates | Where-Object { ($null -ne $_) -and (($null -eq $_.quality) -or ($_.data_state -ne $script:CostQualityEvidenced) -or ($_.cost_tier -eq "unknown")) })
    $front = New-Object System.Collections.ArrayList
    foreach ($candidate in $evidenced) {
        $rank = [int]$candidate.cost_rank
        $dominated = $false
        foreach ($other in $evidenced) {
            if (($other.kind -eq $candidate.kind) -and ($other.name -eq $candidate.name)) { continue }
            $otherRank = [int]$other.cost_rank
            $cheaperOrEqual = ($otherRank -le $rank)
            $betterOrEqual = ([double]$other.quality -ge [double]$candidate.quality)
            $strict = ($otherRank -lt $rank) -or ([double]$other.quality -gt [double]$candidate.quality)
            if ($cheaperOrEqual -and $betterOrEqual -and $strict) { $dominated = $true; break }
        }
        if (-not $dominated) { [void]$front.Add($candidate) }
    }
    $byTier = @{}
    foreach ($candidate in $front) {
        $tier = [string]$candidate.cost_tier
        if (-not $byTier.ContainsKey($tier)) { $byTier[$tier] = $candidate; continue }
        $current = $byTier[$tier]
        if (([double]$candidate.quality -gt [double]$current.quality) -or `
            (([double]$candidate.quality -eq [double]$current.quality) -and ([int]$candidate.samples -gt [int]$current.samples))) {
            $byTier[$tier] = $candidate
        }
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($tier in @($byTier.Keys)) { [void]$rows.Add($byTier[$tier]) }
    $sorted = @($rows | Sort-Object -Property `
        @{ Expression = { [int]$_.cost_rank }; Descending = $false }, `
        @{ Expression = { [string]$_.name }; Descending = $false })
    return [ordered]@{
        rows                 = @($sorted)
        evidenced           = $evidenced.Count
        excluded_insufficient = $excluded.Count
    }
}

function Get-CostQualityRecommendation {
    param([string]$TaskType, [double]$MinGrade = -1, [int]$MinSamples = 0, [string]$Root)
    if ($MinSamples -le 0) { $MinSamples = $script:CostQualityMinSamples }
    $minGradeSource = "argument"
    $minGradeValue = $MinGrade
    if ($minGradeValue -lt 0) { $minGradeValue = $script:CostQualityDefaultMinGrade; $minGradeSource = "default" }
    $canonical = Get-CostQualityCanonicalType -TaskType $TaskType
    $warnings = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $built = Get-CostQualityCandidates -Root $Root -CanonicalType $canonical -MinSamples $MinSamples

    $result = [ordered]@{
        ok                   = $false
        mode                 = "recommend"
        task_type            = [string]$TaskType
        canonical_type       = $canonical
        min_grade            = [math]::Round($minGradeValue, 2)
        min_grade_source     = $minGradeSource
        min_samples          = $MinSamples
        passport             = [string]$built.passport
        passport_path        = [string]$built.path
        selected             = $null
        meets_min_grade      = $false
        deficit              = $null
        reason               = ""
        candidates_considered = 0
        candidates_sufficient = 0
        frontier             = @()
        excluded_insufficient = 0
        warnings             = @()
        notes                = @()
        sources              = $built.sources
        dry_run              = $true
        changed              = $false
    }

    if (-not $built.ok) {
        $result.reason = "passport-" + $built.passport
        [void]$notes.Add([string]$built.error)
        $result.notes = @($notes.ToArray())
        return $result
    }

    $matching = Get-CostQualityMatchingCandidates -Candidates $built.candidates -CanonicalType $canonical
    $result.candidates_considered = $matching.Count
    $result.candidates_sufficient = @($matching | Where-Object { $_.data_state -eq $script:CostQualityEvidenced }).Count

    $pick = Select-CostQualityCandidate -Candidates $matching -MinGrade $minGradeValue -MinSamples $MinSamples
    $selected = $pick.selected

    $frontier = Get-CostQualityFrontier -Candidates $matching
    $result.frontier = @($frontier.rows)
    $result.excluded_insufficient = $frontier.excluded_insufficient

    if ($null -eq $selected) {
        if ($matching.Count -eq 0) {
            $result.reason = "no-matching-candidates"
        } else {
            $result.reason = "no-quality-data"
            [void]$notes.Add(("" + $matching.Count + " matching candidate(s) carry no grade in ratings.jsonl; nothing is recommended"))
        }
        $result.warnings = @($warnings.ToArray())
        $result.notes = @($notes.ToArray())
        return $result
    }

    $result.meets_min_grade = [bool]$pick.meets
    if ($pick.meets) {
        $result.reason = "cheapest sufficient candidate with quality >= min_grade"
    } else {
        $result.reason = "no candidate reached min_grade; nearest evidence-backed candidate returned"
        [void]$warnings.Add(("no candidate reached min_grade " + [math]::Round($minGradeValue, 2) + "; nearest has quality " + $selected.quality))
    }
    $deficit = 0.0
    if ($pick.meets) { $deficit = 0.0 } else { $deficit = [math]::Round(($minGradeValue - [double]$selected.quality), 2) }
    if ($deficit -lt 0) { $deficit = 0.0 }
    $result.deficit = $deficit

    $thinAbove = @($matching | Where-Object { ($_.data_state -ne $script:CostQualityEvidenced) -and ($null -ne $_.quality) -and ([double]$_.quality -ge $minGradeValue) })
    if ($thinAbove.Count -gt 0) {
        [void]$warnings.Add(("" + $thinAbove.Count + " candidate(s) had quality >= min_grade but insufficient samples (samples < " + $MinSamples + ") and were not recommended"))
    }
    if ($selected.data_state -ne $script:CostQualityEvidenced) {
        [void]$warnings.Add(("selected candidate has insufficient evidence: data_state=" + $selected.data_state + " samples=" + $selected.samples + " (min=" + $MinSamples + ")"))
    }

    $threshold = $minGradeValue
    $result.selected = [ordered]@{
        kind               = $selected.kind
        name               = $selected.name
        model              = $selected.model
        cost_tier          = $selected.cost_tier
        cost_rank          = [int]$selected.cost_rank
        task_types         = @($selected.task_types)
        avg_grade          = $selected.avg_grade
        samples            = [int]$selected.samples
        reliability_source = $selected.reliability_source
        failure_count      = [int]$selected.failure_count
        failure_penalty    = [double]$selected.failure_penalty
        failure_signatures = @($selected.failure_signatures)
        quality            = $selected.quality
        data_state         = $selected.data_state
        meets_min_grade    = [bool]$pick.meets
        deficit            = $deficit
        reason             = ("quality=" + $selected.quality + " grade=" + $selected.avg_grade + " samples=" + $selected.samples + " penalty=" + $selected.failure_penalty + " cost=" + $selected.cost_tier + " (min_grade=" + [math]::Round($threshold, 2) + ")")
    }
    $result.ok = $true
    $result.warnings = @($warnings.ToArray())
    $result.notes = @($notes.ToArray())
    return $result
}

function ConvertTo-CostQualityJson {
    param($InputObject, [int]$Depth = 10)
    $json = ""
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = "" }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = "null" }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

function Show-CostQualityCandidates {
    param($Candidates, [string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("  {0,-6} {1,-22} {2,-34} {3,-8} {4,-7} {5,-8} {6,-9} {7}" -f "KIND", "NAME", "MODEL", "COST", "GRADE", "SAMPLES", "QUALITY", "DATA")
    $any = $false
    foreach ($candidate in @($Candidates)) {
        $any = $true
        $grade = ""
        if ($null -ne $candidate.avg_grade) { $grade = [string]$candidate.avg_grade }
        $quality = ""
        if ($null -ne $candidate.quality) { $quality = [string]$candidate.quality }
        Write-Host ("  {0,-6} {1,-22} {2,-34} {3,-8} {4,-7} {5,-8} {6,-9} {7}" -f `
            [string]$candidate.kind, [string]$candidate.name, [string]$candidate.model, [string]$candidate.cost_tier, `
            $grade, [string]$candidate.samples, $quality, [string]$candidate.data_state)
    }
    if (-not $any) { Write-Host "  none" }
}

function Show-CostQualityFrontier {
    param($Frontier, [string]$TaskType)
    Write-Host ""
    Write-Host "COST -> QUALITY FRONTIER" -ForegroundColor Cyan
    $label = "<any>"
    if (-not [string]::IsNullOrWhiteSpace($TaskType)) { $label = $TaskType }
    Write-Host ("task_type : " + $label)
    Write-Host ("  {0,-8} {1,-9} {2,-7} {3,-8} {4,-24} {5}" -f "COST", "QUALITY", "GRADE", "SAMPLES", "CANDIDATE", "FAIL_PENALTY")
    if (@($Frontier.rows).Count -eq 0) {
        Write-Host "  none (no evidence-backed candidate with a known cost tier)"
    } else {
        foreach ($row in @($Frontier.rows)) {
            Write-Host ("  {0,-8} {1,-9} {2,-7} {3,-8} {4,-24} {5}" -f `
                [string]$row.cost_tier, [string]$row.quality, [string]$row.avg_grade, [string]$row.samples, `
                ([string]$row.kind + ":" + [string]$row.name), [string]$row.failure_penalty)
        }
    }
    Write-Host ("  evidenced=" + $Frontier.evidenced + "  excluded(insufficient-or-unknown-cost)=" + $Frontier.excluded_insufficient)
}

function Show-CostQualityRecommendation {
    param($Recommendation)
    Write-Host ""
    Write-Host "COST/QUALITY RECOMMENDATION" -ForegroundColor Cyan
    if ($null -eq $Recommendation) { Write-Host "  no recommendation"; return }
    Write-Host ("task_type : " + $Recommendation.task_type + " (canonical=" + $Recommendation.canonical_type + ")")
    Write-Host ("min_grade : " + $Recommendation.min_grade + " (" + $Recommendation.min_grade_source + ")  min_samples=" + $Recommendation.min_samples)
    Write-Host ("passport  : " + $Recommendation.passport)
    if ($null -ne $Recommendation.selected) {
        $row = $Recommendation.selected
        Write-Host ("selected  : " + $row.kind + " " + $row.name + " (model=" + $row.model + ", cost=" + $row.cost_tier + ")")
        Write-Host ("quality   : " + $row.quality + "  grade=" + $row.avg_grade + " samples=" + $row.samples + " failure_penalty=" + $row.failure_penalty)
        Write-Host ("meets bar : " + $row.meets_min_grade + "  deficit=" + $row.deficit + "  data_state=" + $row.data_state)
    } else {
        Write-Host "selected  : none"
    }
    Write-Host ("reason    : " + $Recommendation.reason)
    Write-Host ("candidates: considered=" + $Recommendation.candidates_considered + " sufficient=" + $Recommendation.candidates_sufficient)
    foreach ($warning in @($Recommendation.warnings)) { Write-Host ("WARN      : " + $warning) -ForegroundColor Yellow }
    foreach ($note in @($Recommendation.notes)) { Write-Host ("NOTE      : " + $note) }
}

function Show-CostQualityUsage {
    Write-Host ""
    Write-Host "cost-quality.ps1 - cheapest candidate that clears a grade bar" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -TaskType <type>          code | review | test | security | data | ..."
    Write-Host "  -MinGrade <n>             quality bar (default 6.0); recommend the cheapest candidate above it"
    Write-Host "  -MinSamples <n>           samples needed for full-evidence quality (default 2)"
    Write-Host "  -Frontier                 cost -> best quality table (pareto)"
    Write-Host "  -List                     list every candidate and its data state"
    Write-Host "  -Json                     emit the result as JSON"
    Write-Host "  -Root <path>              repository root override"
    Write-Host ""
    Write-Host "Quality = ratings avg_grade minus an open failure-memory penalty (agent name for"
    Write-Host "agents, model id for models). Missing data is marked, never guessed."
    Write-Host ""
    Write-Host "Exit: 0 result produced, 2 passport missing/broken, 1 argument failure or no selection"
    Write-Host ""
}

function Parse-CostQualityArguments {
    param([object[]]$Arguments)
    $options = @{ Help = $false; List = $false; Frontier = $false; Json = $false; TaskType = ""; MinGrade = -1.0; MinSamples = 2; Root = "" }
    if ($null -eq $Arguments) { $Arguments = @() }
    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $name = $token
        $inlineValue = $null
        if ($token -match '^-([A-Za-z]+):(.*)$') {
            $name = "-" + $Matches[1]
            $inlineValue = $Matches[2]
        }
        if ($name -eq "-List") { $options.List = $true; $index++ }
        elseif ($name -eq "-Frontier") { $options.Frontier = $true; $index++ }
        elseif ($name -eq "-Json") { $options.Json = $true; $index++ }
        elseif ($name -eq "-Help") { $options.Help = $true; $index++ }
        elseif (@("-TaskType", "-MinGrade", "-MinSamples", "-Root") -contains $name) {
            $value = $inlineValue
            if ($null -eq $value) {
                if (($index + 1) -ge $Arguments.Count) { throw "Missing value for $name" }
                $value = [string]$Arguments[$index + 1]
                $index = $index + 2
            } else { $index++ }
            if ($name -eq "-TaskType") { $options.TaskType = $value }
            elseif ($name -eq "-Root") { $options.Root = $value }
            elseif ($name -eq "-MinGrade") {
                $grade = 0.0
                if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$grade)) { throw "Invalid -MinGrade value '$value'" }
                if ($grade -lt 0) { throw "-MinGrade must be >= 0" }
                $options.MinGrade = $grade
            }
            else {
                $samples = 0
                if (-not [int]::TryParse($value, [ref]$samples)) { throw "Invalid -MinSamples value '$value'" }
                $options.MinSamples = $samples
            }
        } else {
            throw "Unknown argument '$token'. Usage: -TaskType <type> [-MinGrade n] [-Frontier] [-List] [-Json]"
        }
    }
    return $options
}

function Invoke-CostQualityCommandLine {
    param([object[]]$Arguments)
    $options = $null
    try { $options = Parse-CostQualityArguments -Arguments $Arguments }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-CostQualityUsage
        exit 1
    }

    if ($options.Help) { Show-CostQualityUsage; exit 0 }
    if ($options.MinSamples -lt 1) {
        Write-Host "-MinSamples must be >= 1" -ForegroundColor Red
        exit 1
    }

    $canonical = ""
    if (-not [string]::IsNullOrWhiteSpace($options.TaskType)) { $canonical = Get-CostQualityCanonicalType -TaskType $options.TaskType }

    if ($options.List) {
        $built = Get-CostQualityCandidates -Root $options.Root -CanonicalType $canonical -MinSamples $options.MinSamples
        if (-not $built.ok) {
            if ($options.Json) { Write-Output (ConvertTo-CostQualityJson -InputObject ([ordered]@{ ok = $false; mode = "list"; passport = $built.passport; error = $built.error })) }
            else { Write-Host ("LIST FAILED: " + $built.error) -ForegroundColor Red }
            exit 2
        }
        $matching = Get-CostQualityMatchingCandidates -Candidates $built.candidates -CanonicalType $canonical
        if ($options.Json) {
            $payload = [ordered]@{ ok = $true; mode = "list"; task_type = $options.TaskType; candidates = @($matching); dry_run = $true; changed = $false }
            Write-Output (ConvertTo-CostQualityJson -InputObject $payload)
        } else {
            Show-CostQualityCandidates -Candidates $matching -Title "COST/QUALITY CANDIDATES"
        }
        exit 0
    }

    if ($options.Frontier) {
        $built = Get-CostQualityCandidates -Root $options.Root -CanonicalType $canonical -MinSamples $options.MinSamples
        if (-not $built.ok) {
            if ($options.Json) { Write-Output (ConvertTo-CostQualityJson -InputObject ([ordered]@{ ok = $false; mode = "frontier"; passport = $built.passport; error = $built.error })) }
            else { Write-Host ("FRONTIER FAILED: " + $built.error) -ForegroundColor Red }
            exit 2
        }
        $matching = Get-CostQualityMatchingCandidates -Candidates $built.candidates -CanonicalType $canonical
        $frontier = Get-CostQualityFrontier -Candidates $matching
        if ($options.Json) {
            $payload = [ordered]@{
                ok = $true; mode = "frontier"; task_type = $options.TaskType; canonical_type = $canonical
                rows = @($frontier.rows); evidenced = $frontier.evidenced; excluded_insufficient = $frontier.excluded_insufficient
                dry_run = $true; changed = $false
            }
            Write-Output (ConvertTo-CostQualityJson -InputObject $payload)
        } else {
            Show-CostQualityFrontier -Frontier $frontier -TaskType $options.TaskType
        }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($options.TaskType)) {
        Write-Host "-TaskType is required (or use -List / -Frontier)" -ForegroundColor Red
        Show-CostQualityUsage
        exit 1
    }

    $recommendation = Get-CostQualityRecommendation -TaskType $options.TaskType -MinGrade $options.MinGrade -MinSamples $options.MinSamples -Root $options.Root
    if ($options.Json) { Write-Output (ConvertTo-CostQualityJson -InputObject $recommendation) }
    else { Show-CostQualityRecommendation -Recommendation $recommendation }
    if (($recommendation.passport -eq "missing") -or ($recommendation.passport -eq "broken")) { exit 2 }
    if (-not $recommendation.ok) { exit 1 }
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CostQualityCommandLine -Arguments $args
}
