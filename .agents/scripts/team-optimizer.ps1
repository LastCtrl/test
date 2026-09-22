# team-optimizer.ps1 - P3 team optimizer: recommend an agent line-up for a task type.
#
# Recommendation only. This script never writes configuration, queues, the
# passport or the failure registry; it only reads and ranks. Sources, never guessed:
#   * .agents\config\capability-passport.json - capabilities, cost tier, reliability
#   * .memory\ratings.jsonl                   - acceptance grades per agent
#   * .memory\failure-memory.jsonl            - open failure signatures per task type
#
# Environment hook (tests): AGENT_HQ_ROOT. An explicit -Root always wins.
# No param() block on purpose: tests dot-source the file for its functions, so the
# command line is parsed from $args on a direct invocation only.

$script:TeamOptimizerScriptRoot = $PSScriptRoot
$script:TeamOptimizerDefaultGrade = 6.0
$script:TeamOptimizerFailureWeight = 1.5
$script:TeamOptimizerFailureCap = 4.5
$script:TeamOptimizerCostWeight = 0.05
$script:TeamOptimizerCostRank = @{ "free" = 0; "medium" = 1; "paid" = 2; "unknown" = 2 }
$script:TeamOptimizerMaxCostRank = @{ "free" = 0; "medium" = 1; "paid" = 2 }
# risk -> verifier capability types that must be present, in order
$script:TeamOptimizerRiskVerifiers = @{
    "low"  = @("test")
    "med"  = @("test", "review")
    "high" = @("test", "review", "security")
}
# preferred role per verifier type; a matching role outranks a higher score
$script:TeamOptimizerVerifierRoles = @{
    "test"     = @("qa-engineer", "qa-engineer-1")
    "review"   = @("code-reviewer", "code-reviewer-1", "senior-reviewer", "senior-reviewer-1")
    "security" = @("security-auditor", "security-auditor-1")
}

$script:TeamOptimizerPassportScript = Join-Path $script:TeamOptimizerScriptRoot "capability-passport.ps1"
if (Test-Path -LiteralPath $script:TeamOptimizerPassportScript -PathType Leaf) {
    . $script:TeamOptimizerPassportScript
}

function Get-TeamOptimizerRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:TeamOptimizerScriptRoot)) {
        return (Split-Path (Split-Path $script:TeamOptimizerScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Test-TeamOptimizerPassportReady {
    $read = Get-Command -Name "Read-PassportDocument" -ErrorAction SilentlyContinue
    $match = Get-Command -Name "Test-CapabilityMatch" -ErrorAction SilentlyContinue
    return (($null -ne $read) -and ($null -ne $match))
}

function Get-TeamOptimizerCanonicalType {
    param([string]$TaskType)
    if ([string]::IsNullOrWhiteSpace($TaskType)) { return "" }
    if ($null -eq (Get-Command -Name "Get-PassportCanonicalTokens" -ErrorAction SilentlyContinue)) {
        return $TaskType.Trim().ToLowerInvariant()
    }
    $tokens = Get-PassportCanonicalTokens -Tokens @($TaskType)
    if (@($tokens).Count -eq 0) { return $TaskType.Trim().ToLowerInvariant() }
    return [string]@($tokens)[0]
}

function Get-TeamOptimizerCostRank {
    param([string]$CostTier)
    $tier = ([string]$CostTier).Trim().ToLowerInvariant()
    if ($script:TeamOptimizerCostRank.ContainsKey($tier)) { return [int]$script:TeamOptimizerCostRank[$tier] }
    return 2
}

function Get-TeamOptimizerMaxCostRank {
    param([string]$MaxCostTier)
    $tier = ([string]$MaxCostTier).Trim().ToLowerInvariant()
    if ($script:TeamOptimizerMaxCostRank.ContainsKey($tier)) { return [int]$script:TeamOptimizerMaxCostRank[$tier] }
    return 2
}

function Read-TeamOptimizerFailureEntries {
    param([string]$Root)
    $path = Join-Path (Get-TeamOptimizerRoot -Root $Root) ".memory\failure-memory.jsonl"
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

function Get-TeamOptimizerReliability {
    param([string]$Root)
    $map = @{}
    if ($null -eq (Get-Command -Name "Get-ReliabilityIndex" -ErrorAction SilentlyContinue)) { return $map }
    $path = Join-Path (Get-TeamOptimizerRoot -Root $Root) ".memory\ratings.jsonl"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $index = (Get-ReliabilityIndex -RatingsPath $path).index
    foreach ($key in @($index.Keys)) {
        $stats = $index[$key]
        if ([int]$stats.samples -le 0) { continue }
        $map[[string]$key] = [ordered]@{
            samples   = [int]$stats.samples
            avg_grade = [math]::Round(([double]$stats.grade_sum / [double]$stats.samples), 2)
        }
    }
    return $map
}

function Get-TeamOptimizerFailurePenalty {
    param([object[]]$Entries, [string]$AgentName, [string]$CanonicalType)
    $count = 0
    $signatures = New-Object System.Collections.ArrayList
    $agentKey = $AgentName.Trim().ToLowerInvariant()
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        if ([bool]$entry.fixed) { continue }
        $type = ([string]$entry.task_type).Trim().ToLowerInvariant()
        if ($type -ne $CanonicalType) { continue }
        $agent = ([string]$entry.agent).Trim().ToLowerInvariant()
        if ($agent -ne $agentKey) { continue }
        $count = $count + [int]$entry.count
        [void]$signatures.Add([string]$entry.signature)
    }
    $penalty = [math]::Min(($count * $script:TeamOptimizerFailureWeight), $script:TeamOptimizerFailureCap)
    return [ordered]@{
        count      = $count
        penalty    = [math]::Round($penalty, 2)
        signatures = @($signatures.ToArray())
    }
}

function Get-TeamRecommendation {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskType,
        [ValidateSet("low", "med", "high")][string]$Risk = "med",
        [ValidateSet("free", "medium", "paid")][string]$MaxCostTier = "paid",
        [ValidateRange(1, 10)][int]$Size = 1,
        [string]$Root
    )
    $rootValue = Get-TeamOptimizerRoot -Root $Root
    $notes = New-Object System.Collections.ArrayList
    $result = [ordered]@{
        ok                 = $false
        task_type          = [string]$TaskType
        canonical_type     = ""
        risk               = $Risk
        max_cost_tier      = $MaxCostTier
        size               = $Size
        dry_run            = $true
        changed            = $false
        passport           = ""
        executors          = @()
        verifiers          = @()
        rejected           = @()
        reason             = ""
        notes              = @()
        reliability_source = ""
        failure_source     = ""
    }

    $canonical = Get-TeamOptimizerCanonicalType -TaskType $TaskType
    $result.canonical_type = $canonical

    if (-not (Test-TeamOptimizerPassportReady)) {
        $result.passport = "missing"
        $result.reason = "passport-module-missing"
        [void]$notes.Add("capability-passport.ps1 is not loaded; candidates cannot be evaluated")
        $result.notes = @($notes.ToArray())
        return $result
    }

    $doc = Read-PassportDocument -Root $rootValue
    if (-not $doc.ok) {
        if (([string]$doc.error) -match "not found") { $result.passport = "missing" } else { $result.passport = "broken" }
        $result.reason = "passport-" + $result.passport
        [void]$notes.Add([string]$doc.error)
        $result.notes = @($notes.ToArray())
        return $result
    }
    $result.passport = "ok"
    $result.reliability_source = Join-Path $rootValue ".memory\ratings.jsonl"
    $result.failure_source = Join-Path $rootValue ".memory\failure-memory.jsonl"

    $reliability = Get-TeamOptimizerReliability -Root $rootValue
    $failures = Read-TeamOptimizerFailureEntries -Root $rootValue
    $maxRank = Get-TeamOptimizerMaxCostRank -MaxCostTier $MaxCostTier

    $required = New-Object System.Collections.ArrayList
    foreach ($type in @($script:TeamOptimizerRiskVerifiers[$Risk])) { [void]$required.Add($type) }
    if (($canonical -eq "security") -and (-not $required.Contains("security"))) { [void]$required.Add("security") }

    $evaluated = New-Object System.Collections.ArrayList
    $rejected = New-Object System.Collections.ArrayList

    foreach ($key in @($doc.agents.Keys)) {
        $entry = $doc.agents[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $model = ""
        if ($null -ne $entry["model"]) { $model = [string]$entry["model"] }
        $costTier = "unknown"
        if ($null -ne $entry["cost_tier"]) { $costTier = [string]$entry["cost_tier"] }
        $role = ""
        if ($null -ne $entry["role"]) { $role = [string]$entry["role"] }

        $costRank = Get-TeamOptimizerCostRank -CostTier $costTier
        if ($costRank -gt $maxRank) {
            [void]$rejected.Add([ordered]@{
                name = $name; model = $model; cost_tier = $costTier; role = $role
                reason = "cost-tier-above-max"
                detail = ("cost=" + $costTier + " max=" + $MaxCostTier)
            })
            continue
        }

        $declared = Get-PassportTaskTypes -Passport $entry
        $declaredTokens = Get-PassportCanonicalTokens -Tokens $declared
        $match = Test-CapabilityMatch -Declared $declaredTokens -Requested $canonical

        $samples = 0
        $avgGrade = $null
        $relKey = $name.ToLowerInvariant()
        if ($reliability.ContainsKey($relKey)) {
            $samples = [int]$reliability[$relKey].samples
            $avgGrade = [double]$reliability[$relKey].avg_grade
        } else {
            $passportRel = $entry["reliability"]
            if (($passportRel -is [System.Collections.IDictionary]) -and ($null -ne $passportRel["avg_grade"])) {
                $samples = [int]$passportRel["samples"]
                $avgGrade = [double]$passportRel["avg_grade"]
            }
        }

        $baseGrade = $script:TeamOptimizerDefaultGrade
        if ($null -ne $avgGrade) { $baseGrade = [double]$avgGrade }
        $failure = Get-TeamOptimizerFailurePenalty -Entries $failures -AgentName $name -CanonicalType $canonical
        $costPenalty = [double]$costRank * $script:TeamOptimizerCostWeight
        $score = [math]::Round(($baseGrade - [double]$failure.penalty - $costPenalty), 2)

        [void]$evaluated.Add([ordered]@{
            name               = $name
            model              = $model
            role               = $role
            cost_tier          = $costTier
            declared           = @($declaredTokens)
            matches            = [bool]$match.matched
            avg_grade          = $avgGrade
            samples            = $samples
            failure_count      = [int]$failure.count
            failure_penalty    = [double]$failure.penalty
            failure_signatures = @($failure.signatures)
            cost_penalty       = [math]::Round($costPenalty, 2)
            score              = $score
        })
    }

    foreach ($row in $evaluated) {
        if ([bool]$row.matches) { continue }
        [void]$rejected.Add([ordered]@{
            name = $row.name; model = $row.model; cost_tier = $row.cost_tier; role = $row.role
            reason = "capability-mismatch"
            detail = ("declares [" + (@($row.declared) -join ",") + "]")
        })
    }

    $executorPool = @($evaluated | Where-Object { [bool]$_.matches })
    $ranked = @($executorPool | Sort-Object -Property @{ Expression = { [double]$_.score }; Descending = $true }, @{ Expression = { [string]$_.name }; Descending = $false })
    $executorRows = New-Object System.Collections.ArrayList
    $selectedNames = @{}
    foreach ($candidate in @($ranked | Select-Object -First $Size)) {
        $selectedNames[[string]$candidate.name] = $true
        $gradeLabel = "default"
        if ($null -ne $candidate.avg_grade) { $gradeLabel = [string]$candidate.avg_grade }
        [void]$executorRows.Add([ordered]@{
            name               = $candidate.name
            model              = $candidate.model
            role               = $candidate.role
            cost_tier          = $candidate.cost_tier
            declared           = @($candidate.declared)
            score              = $candidate.score
            avg_grade          = $candidate.avg_grade
            samples            = $candidate.samples
            failure_count      = $candidate.failure_count
            failure_penalty    = $candidate.failure_penalty
            failure_signatures = $candidate.failure_signatures
            reason             = ("score=" + $candidate.score + " (grade=" + $gradeLabel + "/" + $candidate.samples + " samples, failure_penalty=" + $candidate.failure_penalty + ", cost=" + $candidate.cost_tier + ")")
        })
    }

    foreach ($candidate in $ranked) {
        if ($selectedNames.ContainsKey([string]$candidate.name)) { continue }
        [void]$rejected.Add([ordered]@{
            name            = $candidate.name
            model           = $candidate.model
            cost_tier       = $candidate.cost_tier
            role            = $candidate.role
            reason          = "lower-ranked"
            detail          = ("score=" + $candidate.score)
            failure_penalty = $candidate.failure_penalty
            failure_count   = $candidate.failure_count
        })
    }

    $verifiers = New-Object System.Collections.ArrayList
    $usedNames = @{}
    foreach ($row in $executorRows) { $usedNames[[string]$row.name] = $true }
    foreach ($type in @($required)) {
        $pool = New-Object System.Collections.ArrayList
        foreach ($candidate in $evaluated) {
            if ($usedNames.ContainsKey([string]$candidate.name)) { continue }
            if (-not (@($candidate.declared) -contains $type)) { continue }
            $rolePriority = 0
            if ($script:TeamOptimizerVerifierRoles.ContainsKey($type)) {
                $preferred = @($script:TeamOptimizerVerifierRoles[$type])
                for ($i = 0; $i -lt $preferred.Count; $i++) {
                    if ([string]$candidate.role -ieq [string]$preferred[$i]) { $rolePriority = ($preferred.Count - $i); break }
                }
            }
            [void]$pool.Add([pscustomobject]@{ candidate = $candidate; role_priority = $rolePriority })
        }
        $ordered = @($pool | Sort-Object -Property @{ Expression = { [int]$_.role_priority }; Descending = $true }, @{ Expression = { [double]$_.candidate.score }; Descending = $true }, @{ Expression = { [string]$_.candidate.name }; Descending = $false })
        $best = $null
        if ($ordered.Count -gt 0) { $best = $ordered[0].candidate }
        if ($null -eq $best) {
            [void]$notes.Add("no " + $type + " agent available within max cost tier " + $MaxCostTier)
            continue
        }
        $usedNames[[string]$best.name] = $true
        [void]$verifiers.Add([ordered]@{
            name       = $best.name
            model      = $best.model
            role       = $best.role
            cost_tier  = $best.cost_tier
            verifies   = $type
            score      = $best.score
            avg_grade  = $best.avg_grade
            samples    = $best.samples
            reason     = ("verifies=" + $type + " (role=" + $best.role + ", score=" + $best.score + ")")
        })
    }

    $result.executors = @($executorRows.ToArray())
    $result.verifiers = @($verifiers.ToArray())
    $result.rejected = @($rejected.ToArray() | Sort-Object -Property @{ Expression = { [string]$_.name }; Descending = $false })

    if ($result.executors.Count -eq 0) {
        $result.ok = $false
        $result.reason = "no-executor-candidates"
    } else {
        $result.ok = $true
        $execNames = (@($result.executors | ForEach-Object { [string]$_.name }) -join ",")
        $verNames = (@($result.verifiers | ForEach-Object { [string]$_.name }) -join ",")
        if ([string]::IsNullOrWhiteSpace($verNames)) { $verNames = "none" }
        $result.reason = ($canonical + "/" + $Risk + " risk -> executors [" + $execNames + "] + verifiers [" + $verNames + "]")
    }
    $result.notes = @($notes.ToArray())
    return $result
}

function Show-TeamOptimizerAgents {
    param([string]$Root)
    Write-Host ""
    Write-Host "PASSPORT AGENTS" -ForegroundColor Cyan
    if (-not (Test-TeamOptimizerPassportReady)) { Write-Host "  capability-passport.ps1 is not loaded"; return }
    $doc = Read-PassportDocument -Root (Get-TeamOptimizerRoot -Root $Root)
    if (-not $doc.ok) { Write-Host ("  " + $doc.error) -ForegroundColor Yellow; return }
    Write-Host ("  {0,-22} {1,-40} {2,-8} {3}" -f "NAME", "MODEL", "COST", "TASK_TYPES")
    foreach ($key in @($doc.agents.Keys | Sort-Object)) {
        $entry = $doc.agents[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $model = ""
        if ($null -ne $entry["model"]) { $model = [string]$entry["model"] }
        $cost = "unknown"
        if ($null -ne $entry["cost_tier"]) { $cost = [string]$entry["cost_tier"] }
        $types = Get-PassportTaskTypes -Passport $entry
        Write-Host ("  {0,-22} {1,-40} {2,-8} {3}" -f [string]$key, $model, $cost, (@($types) -join ","))
    }
}

function Show-TeamRecommendation {
    param($Recommendation)
    Write-Host ""
    Write-Host "TEAM RECOMMENDATION" -ForegroundColor Cyan
    if ($null -eq $Recommendation) { Write-Host "  no recommendation"; return }
    Write-Host ("task_type  : " + $Recommendation.task_type + " (canonical=" + $Recommendation.canonical_type + ")")
    Write-Host ("risk       : " + $Recommendation.risk + "  max_cost=" + $Recommendation.max_cost_tier + "  size=" + $Recommendation.size)
    Write-Host ("passport   : " + $Recommendation.passport + "  ok=" + $Recommendation.ok)
    Write-Host ""
    Write-Host "EXECUTORS" -ForegroundColor Green
    if (@($Recommendation.executors).Count -eq 0) { Write-Host "  none" } else {
        foreach ($row in @($Recommendation.executors)) {
            Write-Host ("  {0,-20} {1,-40} {2,-7} score={3} grade={4} samples={5} fails={6}" -f `
                [string]$row.name, [string]$row.model, [string]$row.cost_tier, [string]$row.score, [string]$row.avg_grade, [string]$row.samples, [string]$row.failure_count)
        }
    }
    Write-Host "VERIFIERS" -ForegroundColor Green
    if (@($Recommendation.verifiers).Count -eq 0) { Write-Host "  none" } else {
        foreach ($row in @($Recommendation.verifiers)) {
            Write-Host ("  {0,-20} {1,-40} {2,-7} verifies={3} score={4}" -f `
                [string]$row.name, [string]$row.model, [string]$row.cost_tier, [string]$row.verifies, [string]$row.score)
        }
    }
    Write-Host "REJECTED" -ForegroundColor Green
    if (@($Recommendation.rejected).Count -eq 0) { Write-Host "  none" } else {
        foreach ($row in @($Recommendation.rejected)) {
            Write-Host ("  {0,-20} {1,-28} {2}" -f [string]$row.name, [string]$row.reason, [string]$row.detail)
        }
    }
    Write-Host ("REASON     : " + $Recommendation.reason)
    foreach ($note in @($Recommendation.notes)) { Write-Host ("NOTE       : " + $note) }
}

function ConvertTo-TeamOptimizerJson {
    param($InputObject, [int]$Depth = 10)
    $json = ""
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = "" }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = "null" }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat("\u{0:x4}", $code) }
    }
    return $builder.ToString()
}

function Show-TeamOptimizerUsage {
    Write-Host ""
    Write-Host "team-optimizer.ps1 - recommend an agent line-up for a task type" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -TaskType <type>          code | review | test | security | data | ... (required unless -List)"
    Write-Host "  -Risk <low|med|high>      verifier depth (default med)"
    Write-Host "  -MaxCostTier <tier>       free | medium | paid (default paid)"
    Write-Host "  -Size <n>                 number of executors to recommend (default 1)"
    Write-Host "  -List                     list passport agents (or the full table with -TaskType)"
    Write-Host "  -Json                     emit the recommendation as JSON"
    Write-Host "  -DryRun                   explicit no-op; nothing is ever changed"
    Write-Host "  -Root <path>              repository root override"
    Write-Host ""
    Write-Host "Exit: 0 recommendation produced, 2 passport missing/broken, 1 argument failure"
    Write-Host ""
}

function Parse-TeamOptimizerArguments {
    param([object[]]$Arguments)
    $options = @{ Help = $false; List = $false; Json = $false; DryRun = $false; TaskType = ""; Risk = "med"; MaxCostTier = "paid"; Size = 1; Root = "" }
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
        elseif ($name -eq "-Json") { $options.Json = $true; $index++ }
        elseif ($name -eq "-DryRun") { $options.DryRun = $true; $index++ }
        elseif ($name -eq "-Help") { $options.Help = $true; $index++ }
        elseif (@("-TaskType", "-Risk", "-MaxCostTier", "-Size", "-Root") -contains $name) {
            $value = $inlineValue
            if ($null -eq $value) {
                if (($index + 1) -ge $Arguments.Count) { throw "Missing value for $name" }
                $value = [string]$Arguments[$index + 1]
                $index = $index + 2
            } else { $index++ }
            if ($name -eq "-TaskType") { $options.TaskType = $value }
            elseif ($name -eq "-Risk") { $options.Risk = $value.ToLowerInvariant() }
            elseif ($name -eq "-MaxCostTier") { $options.MaxCostTier = $value.ToLowerInvariant() }
            elseif ($name -eq "-Size") {
                $size = 0
                if (-not [int]::TryParse($value, [ref]$size)) { throw "Invalid -Size value '$value'" }
                $options.Size = $size
            }
            else { $options.Root = $value }
        } else {
            throw "Unknown argument '$token'. Usage: -TaskType <type> [-Risk low|med|high] [-MaxCostTier free|medium|paid] [-Size n] [-Json] [-List]"
        }
    }
    return $options
}

function Invoke-TeamOptimizerCommandLine {
    param([object[]]$Arguments)
    $options = $null
    try { $options = Parse-TeamOptimizerArguments -Arguments $Arguments }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-TeamOptimizerUsage
        exit 1
    }

    if ($options.Help) { Show-TeamOptimizerUsage; exit 0 }

    if ($options.List -and [string]::IsNullOrWhiteSpace($options.TaskType)) {
        Show-TeamOptimizerAgents -Root $options.Root
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($options.TaskType)) {
        Write-Host "-TaskType is required (or use -List)" -ForegroundColor Red
        Show-TeamOptimizerUsage
        exit 1
    }
    if (-not (@("low", "med", "high") -contains $options.Risk)) {
        Write-Host ("invalid -Risk '" + $options.Risk + "'") -ForegroundColor Red
        exit 1
    }
    if (-not (@("free", "medium", "paid") -contains $options.MaxCostTier)) {
        Write-Host ("invalid -MaxCostTier '" + $options.MaxCostTier + "'") -ForegroundColor Red
        exit 1
    }
    if ($options.Size -lt 1) {
        Write-Host "-Size must be >= 1" -ForegroundColor Red
        exit 1
    }
    if ($options.Size -gt 10) {
        Write-Host "-Size must be between 1 and 10" -ForegroundColor Red
        Show-TeamOptimizerUsage
        exit 1
    }

    $recommendation = Get-TeamRecommendation -TaskType $options.TaskType -Risk $options.Risk -MaxCostTier $options.MaxCostTier -Size $options.Size -Root $options.Root
    if ($options.Json) {
        Write-Output (ConvertTo-TeamOptimizerJson -InputObject $recommendation -Depth 10)
    } else {
        Show-TeamRecommendation -Recommendation $recommendation
    }
    if (-not $recommendation.ok -and (($recommendation.passport -eq "missing") -or ($recommendation.passport -eq "broken"))) { exit 2 }
    if (-not $recommendation.ok) { exit 1 }
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-TeamOptimizerCommandLine -Arguments $args
}
