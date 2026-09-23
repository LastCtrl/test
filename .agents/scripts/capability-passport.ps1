# capability-passport.ps1 - agent/model capability passport for the agent-hq fleet (P3).
#
# Read-mostly. The single write path is Update-PassportFromMetrics, which refreshes
# the reliability/speed metrics of .agents\config\capability-passport.json and swaps
# the file in atomically (temp + Replace/Move, never truncated in place).
#
# Data sources, never guessed; a missing source leaves the field null and adds a note:
#   * .opencode\agents\<agent>.json     - agent name / division / configured model
#   * .memory\ratings.jsonl             - acceptance grades per model and per agent
#   * performance.jsonl + traces.jsonl  - measured session latency per agent/model
#   * .agents\config\model-limits.json  - documented request/token ceilings
#   * authored passport fields          - capabilities / context / notes (see "sources")
#
# Environment hooks (used by tests): AGENT_HQ_ROOT, AGENT_HQ_TRACES_DIR.
#
# No param() block on purpose: the file is dot-sourced by model-router.ps1 and by
# tests, so the command line is parsed from $args on a direct invocation only.

$script:PassportFileName = "capability-passport.json"
$script:PassportScriptRoot = $PSScriptRoot
$script:DefaultTracesDirName = "agent-hq-traces"
$script:DefaultMaxTraceLines = 60000

$script:CostTierRank = @{ "free" = 0; "medium" = 1; "paid" = 2; "unknown" = 2 }

function Get-PassportRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:PassportScriptRoot)) {
        return (Split-Path (Split-Path $script:PassportScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-PassportPath {
    param([string]$Root)
    return (Join-Path (Get-PassportRoot -Root $Root) (".agents\config\" + $script:PassportFileName))
}

function Get-PassportLimitsPath {
    param([string]$Root)
    return (Join-Path (Get-PassportRoot -Root $Root) ".agents\config\model-limits.json")
}

function Get-PassportTracesDir {
    param([string]$TracesDir)
    if (-not [string]::IsNullOrWhiteSpace($TracesDir)) { return $TracesDir }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_TRACES_DIR)) { return $env:AGENT_HQ_TRACES_DIR }
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base "opencode") $script:DefaultTracesDirName)
}

# ===========================================================================
# JSON helpers
# ===========================================================================

# PSCustomObject / IDictionary -> ordered hashtables, so entries can be edited
# and looked up without PSObject property ceremony.
function ConvertTo-PassportTable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $out[$property.Name] = ConvertTo-PassportTable $property.Value
        }
        return $out
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $out[[string]$key] = ConvertTo-PassportTable $InputObject[$key]
        }
        return $out
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$items.Add((ConvertTo-PassportTable $item)) }
        return ,$items.ToArray()
    }
    return $InputObject
}

# Ordered has no case-insensitive lookup, so exact match is tried first and a
# scan follows - agent/model ids come from different tools with different casing.
function Get-PassportEntry {
    param($Section, [string]$Name)
    if (($null -eq $Section) -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($Section -isnot [System.Collections.IDictionary]) { return $null }
    if ($Section.Contains($Name)) { return $Section[$Name] }
    foreach ($key in @($Section.Keys)) {
        if ([string]$key -ieq $Name) { return $Section[$key] }
    }
    return $null
}

function Read-PassportDocument {
    param([string]$Root)
    $path = Get-PassportPath -Root $Root
    $doc = [ordered]@{
        ok         = $false
        path       = $path
        error      = ""
        version    = 0
        updated_at = ""
        sources    = $null
        task_types = $null
        agents     = [ordered]@{}
        models     = [ordered]@{}
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $doc.error = "passport file not found: $path"
        return $doc
    }
    $table = $null
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $doc.error = "passport file is empty: $path"
            return $doc
        }
        $table = ConvertTo-PassportTable ($raw | ConvertFrom-Json)
    } catch {
        $doc.error = "passport file is unreadable or not valid JSON: $($_.Exception.Message)"
        return $doc
    }
    if ($table -isnot [System.Collections.IDictionary]) {
        $doc.error = "passport document is not an object: $path"
        return $doc
    }
    foreach ($key in @("version", "generated_by", "updated_at", "sources", "task_types", "agents", "models", "metrics", "notes")) {
        if ($table.Contains($key)) { $doc[$key] = $table[$key] }
    }
    if ($null -eq $doc.agents) { $doc.agents = [ordered]@{} }
    if ($null -eq $doc.models) { $doc.models = [ordered]@{} }
    $doc.ok = $true
    return $doc
}

function Get-AgentPassport {
    param([Parameter(Mandatory = $true)][string]$Agent, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Agent)) { return $null }
    $doc = Read-PassportDocument -Root $Root
    return (Get-PassportEntry -Section $doc.agents -Name $Agent)
}

function Get-ModelPassport {
    param([Parameter(Mandatory = $true)][string]$Model, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
    $doc = Read-PassportDocument -Root $Root
    return (Get-PassportEntry -Section $doc.models -Name $Model)
}

function Get-PassportTaskTypes {
    param($Passport)
    if ($null -eq $Passport) { return ,@() }
    $caps = $Passport.capabilities
    if ($null -eq $caps) { return ,@() }
    if ($caps -is [System.Collections.IDictionary]) {
        $types = $caps["task_types"]
        if ($null -eq $types) { return ,@() }
        return ,@($types)
    }
    return ,@()
}

# ===========================================================================
# Capability matching (task type vocabulary is authored, see the passport)
# ===========================================================================

function Get-PassportCanonicalTokens {
    param([string[]]$Tokens)
    $map = @{
        "code"          = "code"; "dev" = "code"; "feature" = "code"; "bugfix" = "code"; "bug" = "code"
        "refactor"      = "code"; "implementation" = "code"; "hardening" = "code"; "script" = "code"
        "review"        = "review"; "code-review" = "review"; "acceptance" = "review"; "audit" = "review"
        "test"          = "test"; "tests" = "test"; "testing" = "test"; "qa" = "test"; "pytest" = "test"; "regression" = "test"
        "security"      = "security"; "owasp" = "security"; "secret" = "security"; "secrets" = "security"; "vulnerability" = "security"
        "docs"          = "docs"; "doc" = "docs"; "documentation" = "docs"; "markdown" = "docs"; "adr" = "docs"
        "ops"           = "ops"; "devops" = "ops"; "ci" = "ops"; "cd" = "ops"; "ci-cd" = "ops"; "infra" = "ops"; "deploy" = "ops"; "k8s" = "ops"; "docker" = "ops"
        "data"          = "data"; "sql" = "data"; "etl" = "data"; "db" = "data"; "database" = "data"; "postgres" = "data"; "clickhouse" = "data"; "nosql" = "data"
        "integration"   = "integration"; "api" = "integration"; "grpc" = "integration"; "kafka" = "integration"
        "frontend"      = "frontend"; "react" = "frontend"; "ui" = "frontend"; "css" = "frontend"; "typescript" = "frontend"
        "mobile"        = "mobile"; "react-native" = "mobile"; "flutter" = "mobile"
        "orchestration" = "orchestration"; "architecture" = "orchestration"; "delegation" = "orchestration"; "planning" = "orchestration"
        "business"      = "business"; "legal" = "business"; "law" = "business"; "contract" = "business"; "tax" = "business"
        "marketing"     = "business"; "smm" = "business"; "promotion" = "business"; "product" = "business"; "requirements" = "business"
        "research"      = "research"; "skills" = "research"; "tools" = "research"; "discovery" = "research"; "memory" = "research"
        "1c"            = "1c"; "bsl" = "1c"; "vanessa" = "1c"
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($token in @($Tokens)) {
        if ($null -eq $token) { continue }
        $normalized = ([string]$token).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        foreach ($part in @($normalized -split '[^a-z0-9а-я]+' | Where-Object { $_ -ne "" })) {
            if ($map.ContainsKey($part)) {
                if (-not $out.Contains($map[$part])) { [void]$out.Add($map[$part]) }
            } elseif (-not $out.Contains($part)) {
                [void]$out.Add($part)
            }
        }
    }
    return ,$out.ToArray()
}

# Unknown capability data never filters: an agent/model without declared task
# types matches everything (the caller sees matched="unknown" and decides).
function Test-CapabilityMatch {
    param($Declared, [string]$Requested)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        return [ordered]@{ matched = $true; declared = @(); requested = @(); matched_types = @() }
    }
    $declaredTokens = Get-PassportCanonicalTokens -Tokens @($Declared)
    $requestedTokens = Get-PassportCanonicalTokens -Tokens @($Requested)
    if (@($declaredTokens).Count -eq 0) {
        return [ordered]@{ matched = $true; declared = @(); requested = @($requestedTokens); matched_types = @() }
    }
    $hit = New-Object System.Collections.ArrayList
    foreach ($token in @($requestedTokens)) {
        if (@($declaredTokens) -contains $token) { [void]$hit.Add($token) }
    }
    return [ordered]@{
        matched       = ($hit.Count -gt 0)
        declared      = @($declaredTokens)
        requested     = @($requestedTokens)
        matched_types = @($hit.ToArray())
    }
}

# ===========================================================================
# Reliability from .memory\ratings.jsonl
# ===========================================================================

function Get-ReliabilityIndex {
    param([string]$RatingsPath)
    $index = @{}
    $summary = [ordered]@{ path = $RatingsPath; lines = 0; parsed = 0; skipped = 0; exists = $false }
    if (-not (Test-Path -LiteralPath $RatingsPath -PathType Leaf)) { return [pscustomobject]@{ index = $index; summary = $summary } }
    $summary.exists = $true

    $lines = @(Get-Content -LiteralPath $RatingsPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        $summary.lines = $summary.lines + 1
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $record = $null
        try { $record = $trimmed | ConvertFrom-Json } catch { $summary.skipped = $summary.skipped + 1; continue }
        if ($null -eq $record) { $summary.skipped = $summary.skipped + 1; continue }
        $grade = $record.grade
        $isNumber = (($grade -is [int]) -or ($grade -is [double]) -or ($grade -is [decimal]))
        if (-not $isNumber) { $summary.skipped = $summary.skipped + 1; continue }
        $date = ""
        if ($null -ne $record.date) { $date = [string]$record.date }

        $iterations = $null
        if (($null -ne $record.iterations) -and (($record.iterations -is [int]) -or ($record.iterations -is [double]))) {
            $iterations = [double]$record.iterations
        }

        $keys = @()
        if (($null -ne $record.model) -and (-not [string]::IsNullOrWhiteSpace([string]$record.model))) { $keys += [string]$record.model }
        if (($null -ne $record.agent) -and (-not [string]::IsNullOrWhiteSpace([string]$record.agent))) { $keys += [string]$record.agent }
        foreach ($key in $keys) {
            $bucketKey = $key.ToLowerInvariant()
            if (-not $index.ContainsKey($bucketKey)) {
                $index[$bucketKey] = [ordered]@{
                    samples = 0; grade_sum = 0.0; grade_min = $null; grade_max = $null
                    last_grade = $null; last_date = ""; first_date = ""
                    iterations_sum = 0.0; iterations_samples = 0
                }
            }
            $bucket = $index[$bucketKey]
            $bucket.samples = [int]$bucket.samples + 1
            $bucket.grade_sum = [double]$bucket.grade_sum + [double]$grade
            if (($null -eq $bucket.grade_min) -or ([double]$grade -lt [double]$bucket.grade_min)) { $bucket.grade_min = [double]$grade }
            if (($null -eq $bucket.grade_max) -or ([double]$grade -gt [double]$bucket.grade_max)) { $bucket.grade_max = [double]$grade }
            $bucket.last_grade = [double]$grade
            if (-not [string]::IsNullOrWhiteSpace($date)) {
                if ([string]::IsNullOrWhiteSpace([string]$bucket.first_date)) { $bucket.first_date = $date }
                $bucket.last_date = $date
            }
            if ($null -ne $iterations) {
                $bucket.iterations_sum = [double]$bucket.iterations_sum + $iterations
                $bucket.iterations_samples = [int]$bucket.iterations_samples + 1
            }
        }
        $summary.parsed = $summary.parsed + 1
    }
    return [pscustomobject]@{ index = $index; summary = $summary }
}

function Format-ReliabilityStats {
    param($Stats, [string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = ".memory\ratings.jsonl" }
    if (($null -eq $Stats) -or ([int]$Stats.samples -le 0)) {
        return [ordered]@{
            samples            = 0
            avg_grade          = $null
            grade_min          = $null
            grade_max          = $null
            last_grade         = $null
            last_date          = $null
            iterations_avg     = $null
            iterations_samples = 0
            source             = ($Source + " (no records)")
        }
    }
    $iterationsAvg = $null
    if ([int]$Stats.iterations_samples -gt 0) {
        $iterationsAvg = [math]::Round(([double]$Stats.iterations_sum / [double]$Stats.iterations_samples), 2)
    }
    return [ordered]@{
        samples            = [int]$Stats.samples
        avg_grade          = [math]::Round(([double]$Stats.grade_sum / [double]$Stats.samples), 2)
        grade_min          = $Stats.grade_min
        grade_max          = $Stats.grade_max
        last_grade         = $Stats.last_grade
        last_date          = $Stats.last_date
        iterations_avg     = $iterationsAvg
        iterations_samples = [int]$Stats.iterations_samples
        source             = $Source
    }
}

# ===========================================================================
# Measured speed (performance.jsonl session durations joined to traces.jsonl)
# ===========================================================================

function Get-PerfSessionDurations {
    param([string]$TracesDir, [int]$MaxLines = 0)
    $records = New-Object System.Collections.ArrayList
    $path = Join-Path $TracesDir "performance.jsonl"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,$records.ToArray() }
    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (($MaxLines -gt 0) -and ($lines.Count -gt $MaxLines)) { $lines = @($lines[($lines.Count - $MaxLines)..($lines.Count - 1)]) }
    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $record = $null
        try { $record = $trimmed | ConvertFrom-Json } catch { continue }
        if ($null -eq $record) { continue }
        $type = [string]$record.type
        if ((-not [string]::IsNullOrWhiteSpace($type)) -and ($type -ne "session")) { continue }
        if ($null -eq $record.session_id) { continue }
        if ($null -eq $record.duration_ms) { continue }
        $duration = 0.0
        if (-not [double]::TryParse([string]$record.duration_ms, [ref]$duration)) { continue }
        [void]$records.Add([pscustomobject]@{ session_id = [string]$record.session_id; duration_ms = $duration })
    }
    return ,$records.ToArray()
}

function Get-TraceAgentMap {
    param([string]$TracesDir, [int]$MaxLines = 0)
    $map = @{}
    $scanned = 0
    $path = Join-Path $TracesDir "traces.jsonl"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ map = $map; scanned = 0 } }
    $lines = @(Get-Content -LiteralPath $path -Tail $MaxLines -Encoding UTF8 -ErrorAction SilentlyContinue)
    $sessionPattern = [regex]'"session_id":"([^"]+)"'
    $agentPattern = [regex]'"agent":"([^"]+)"'
    foreach ($line in $lines) {
        $scanned = $scanned + 1
        $sessionMatch = $sessionPattern.Match([string]$line)
        if (-not $sessionMatch.Success) { continue }
        $agentMatch = $agentPattern.Match([string]$line)
        if (-not $agentMatch.Success) { continue }
        $key = $sessionMatch.Groups[1].Value
        if (-not $map.ContainsKey($key)) { $map[$key] = $agentMatch.Groups[1].Value }
    }
    return [pscustomobject]@{ map = $map; scanned = $scanned }
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if (($null -eq $Values) -or (@($Values).Count -eq 0)) { return $null }
    $sorted = @($Values | Sort-Object)
    $rank = [int][math]::Ceiling($Percentile * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
    return [math]::Round($sorted[$rank - 1], 0)
}

function Get-MeasuredSpeedIndex {
    param([string]$TracesDir, [int]$MaxLines = 0)
    if ($MaxLines -le 0) { $MaxLines = $script:DefaultMaxTraceLines }
    $sessions = Get-PerfSessionDurations -TracesDir $TracesDir
    $traceInfo = Get-TraceAgentMap -TracesDir $TracesDir -MaxLines $MaxLines
    $byAgent = @{}
    $attributed = 0
    $unknown = 0
    foreach ($record in @($sessions)) {
        $agent = ""
        if ($traceInfo.map.ContainsKey($record.session_id)) { $agent = [string]$traceInfo.map[$record.session_id] }
        if ([string]::IsNullOrWhiteSpace($agent)) { $unknown = $unknown + 1 }
        else { $attributed = $attributed + 1 }
        $bucketKey = $agent
        if (-not $byAgent.ContainsKey($bucketKey)) { $byAgent[$bucketKey] = New-Object System.Collections.ArrayList }
        [void]$byAgent[$bucketKey].Add([double]$record.duration_ms)
    }
    $result = @{}
    foreach ($key in @($byAgent.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
        $durations = @($byAgent[$key].ToArray())
        $result[[string]$key] = [ordered]@{
            sessions  = $durations.Count
            p50_ms    = Get-Percentile -Values $durations -Percentile 0.5
            p90_ms    = Get-Percentile -Values $durations -Percentile 0.9
            avg_ms    = [math]::Round((($durations | Measure-Object -Average).Average), 0)
            durations = $durations
        }
    }
    return [pscustomobject]@{
        agents           = $result
        sessions_total   = @($sessions).Count
        attributed       = $attributed
        unattributed     = $unknown
        traces_scanned   = $traceInfo.scanned
        traces_available = (Test-Path -LiteralPath (Join-Path $TracesDir "traces.jsonl") -PathType Leaf)
        perf_available   = (Test-Path -LiteralPath (Join-Path $TracesDir "performance.jsonl") -PathType Leaf)
        dir              = $TracesDir
    }
}

# ===========================================================================
# Atomic write
# ===========================================================================

function Save-PassportDocument {
    param($Document, [string]$Root)
    $path = Get-PassportPath -Root $Root
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $Document -Depth 12
    $json = ($json -replace "`r`n", "`n") -replace "`n", "`r`n"
    if (-not $json.EndsWith("`r`n")) { $json = $json + "`r`n" }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tmpPath = Join-Path $dir ("." + (Split-Path -Leaf $path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = $path + ".bak." + [guid]::NewGuid().ToString("N")
    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        $swapped = $false
        foreach ($attempt in 1..5) {
            try {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    [System.IO.File]::Replace($tmpPath, $path, $backupPath)
                } else {
                    [System.IO.File]::Move($tmpPath, $path)
                }
                $swapped = $true
                break
            } catch {
                if ($attempt -eq 5) {
                    Write-Warning "cannot swap in passport ${path}: $($_.Exception.Message)"
                } else {
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        if (-not $swapped) {
            try { [System.IO.File]::WriteAllText($path, $json, $encoding) }
            catch { Write-Warning "cannot write passport ${path}: $($_.Exception.Message)" }
        }
    } finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

# ===========================================================================
# Metrics refresh
# ===========================================================================

function Update-PassportFromMetrics {
    param(
        [string]$Root,
        [string]$RatingsPath = "",
        [string]$TracesDir = "",
        [int]$MaxTraceLines = 0,
        [switch]$DryRun
    )
    $rootValue = Get-PassportRoot -Root $Root
    $doc = Read-PassportDocument -Root $rootValue
    if (-not $doc.ok) {
        return [ordered]@{ ok = $false; error = $doc.error; path = $doc.path; written = $false }
    }
    if ([string]::IsNullOrWhiteSpace($RatingsPath)) { $RatingsPath = Join-Path $rootValue ".memory\ratings.jsonl" }
    $tracesValue = Get-PassportTracesDir -TracesDir $TracesDir

    $ratings = Get-ReliabilityIndex -RatingsPath $RatingsPath
    $measured = Get-MeasuredSpeedIndex -TracesDir $tracesValue -MaxTraceLines $MaxTraceLines

    $agentsUpdated = 0
    foreach ($key in @($doc.agents.Keys)) {
        $entry = $doc.agents[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $entry["reliability"] = Format-ReliabilityStats -Stats $ratings.index[([string]$key).ToLowerInvariant()] -Source ".memory\ratings.jsonl (agent)"
        $entry["speed"] = Merge-PassportSpeed -Existing $entry["speed"] -Measured $measured.agents[[string]$key]
        $agentsUpdated = $agentsUpdated + 1
    }

    $modelMeasured = Get-ModelMeasuredSpeed -Document $doc -Measured $measured
    $modelsUpdated = 0
    foreach ($key in @($doc.models.Keys)) {
        $entry = $doc.models[$key]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $entry["reliability"] = Format-ReliabilityStats -Stats $ratings.index[([string]$key).ToLowerInvariant()] -Source ".memory\ratings.jsonl (model)"
        $entry["speed"] = Merge-PassportSpeed -Existing $entry["speed"] -Measured $modelMeasured[[string]$key]
        $modelsUpdated = $modelsUpdated + 1
    }

    $doc["updated_at"] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $doc["metrics"] = [ordered]@{
        ratings      = [ordered]@{
            path    = $ratings.summary.path
            exists  = $ratings.summary.exists
            lines   = $ratings.summary.lines
            parsed  = $ratings.summary.parsed
            skipped = $ratings.summary.skipped
        }
        traces       = [ordered]@{
            dir           = $measured.dir
            perf_exists   = $measured.perf_available
            traces_exists = $measured.traces_available
            sessions      = $measured.sessions_total
            attributed    = $measured.attributed
            unattributed  = $measured.unattributed
            scanned_lines = $measured.traces_scanned
            attribution_note = "only sessions whose trace records carry an agent field are attributed; the rest stay counted under unattributed and never guessed"
        }
        iteration_note = "NOT ENOUGH EVIDENCE: ratings.jsonl has no iterations field and traces.jsonl attempt_id is empty -> iterations_avg stays null"
    }

    $result = [ordered]@{
        ok             = $true
        error          = ""
        path           = $doc.path
        written        = $false
        dry_run        = [bool]$DryRun
        updated_at     = $doc.updated_at
        agents_updated = $agentsUpdated
        models_updated = $modelsUpdated
        ratings_parsed = $ratings.summary.parsed
        ratings_skipped = $ratings.summary.skipped
        sessions_total = $measured.sessions_total
        sessions_attributed = $measured.attributed
        traces_scanned = $measured.traces_scanned
    }

    if (-not $DryRun) {
        try {
            [void](Save-PassportDocument -Document $doc -Root $rootValue)
            $result.written = $true
        } catch {
            $result.ok = $false
            $result.error = "write failed: $($_.Exception.Message)"
        }
    }
    return $result
}

# Keeps the authored reported figures (tps/latency/context) and refreshes the
# measured block, so the passport carries both sources side by side.
function Merge-PassportSpeed {
    param($Existing, $Measured)
    $speed = [ordered]@{}
    if ($Existing -is [System.Collections.IDictionary]) {
        foreach ($key in @($Existing.Keys)) { $speed[[string]$key] = ConvertTo-PassportTable $Existing[$key] }
    }
    foreach ($key in @("tps_p50", "latency_s", "context", "sources")) {
        if (-not $speed.Contains($key)) { $speed[$key] = $null }
    }
    if ($null -ne $Measured) {
        $speed["p50_ms"] = $Measured.p50_ms
        $speed["p90_ms"] = $Measured.p90_ms
        $speed["avg_ms"] = $Measured.avg_ms
        $speed["sessions"] = $Measured.sessions
        $speed["measured_at"] = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        $speed["measured_source"] = "performance.jsonl + traces.jsonl"
        $sources = New-Object System.Collections.ArrayList
        foreach ($source in @($speed["sources"])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$source)) { [void]$sources.Add([string]$source) }
        }
        if (-not $sources.Contains("performance.jsonl + traces.jsonl")) { [void]$sources.Add("performance.jsonl + traces.jsonl") }
        $speed["sources"] = $sources.ToArray()
    } else {
        foreach ($key in @("p50_ms", "p90_ms", "avg_ms")) {
            if (-not $speed.Contains($key)) { $speed[$key] = $null }
        }
        if (-not $speed.Contains("sessions")) { $speed["sessions"] = 0 }
    }
    return $speed
}

function Get-ModelMeasuredSpeed {
    param($Document, $Measured)
    $byModel = @{}
    foreach ($key in @($Document.agents.Keys)) {
        $agent = $Document.agents[$key]
        if ($agent -isnot [System.Collections.IDictionary]) { continue }
        $model = [string]$agent["model"]
        if ([string]::IsNullOrWhiteSpace($model)) { continue }
        $agentMeasured = $Measured.agents[[string]$key]
        if ($null -eq $agentMeasured) { continue }
        if (-not $byModel.ContainsKey($model)) {
            $byModel[$model] = [ordered]@{ durations = (New-Object System.Collections.ArrayList); sessions = 0 }
        }
        $byModel[$model].sessions = [int]$byModel[$model].sessions + [int]$agentMeasured.sessions
        foreach ($duration in @($agentMeasured.durations)) { [void]$byModel[$model].durations.Add([double]$duration) }
    }
    $out = @{}
    foreach ($model in @($byModel.Keys)) {
        $values = @($byModel[$model].durations.ToArray())
        $out[[string]$model] = [ordered]@{
            sessions = $byModel[$model].sessions
            p50_ms   = Get-Percentile -Values $values -Percentile 0.5
            p90_ms   = Get-Percentile -Values $values -Percentile 0.9
            avg_ms   = [math]::Round((($values | Measure-Object -Average).Average), 0)
        }
    }
    return $out
}

# ===========================================================================
# Reporting
# ===========================================================================

function Format-PassportRow {
    param($Entry, [string]$Key)
    $model = ""
    if ($null -ne $Entry["model"]) { $model = [string]$Entry["model"] }
    $cost = "unknown"
    if ($null -ne $Entry["cost_tier"]) { $cost = [string]$Entry["cost_tier"] }
    $types = ""
    $entryTypes = Get-PassportTaskTypes -Passport $Entry
    if (@($entryTypes).Count -gt 0) { $types = (@($entryTypes) -join ",") }
    $grade = ""
    $samples = 0
    $reliability = $Entry["reliability"]
    if ($reliability -is [System.Collections.IDictionary]) {
        if ($null -ne $reliability["avg_grade"]) { $grade = ([string]$reliability["avg_grade"]) }
        if ($null -ne $reliability["samples"]) { $samples = [int]$reliability["samples"] }
    }
    $p50 = ""
    $speed = $Entry["speed"]
    if ($speed -is [System.Collections.IDictionary]) {
        if ($null -ne $speed["p50_ms"]) { $p50 = ([string]$speed["p50_ms"]) }
    }
    return [pscustomobject]@{
        NAME       = $Key
        MODEL      = $model
        COST       = $cost
        TASK_TYPES = $types
        GRADE      = $grade
        SAMPLES    = $samples
        P50_MS     = $p50
    }
}

function Format-PassportLine {
    param($Row)
    return ("  {0,-24} {1,-38} {2,-7} {3,-26} {4,-6} {5,-8} {6}" -f `
        [string]$Row.NAME, [string]$Row.MODEL, [string]$Row.COST, [string]$Row.TASK_TYPES, `
        [string]$Row.GRADE, [string]$Row.SAMPLES, [string]$Row.P50_MS)
}

function Show-PassportTable {
    param($Rows)
    Write-Host ("  {0,-24} {1,-38} {2,-7} {3,-26} {4,-6} {5,-8} {6}" -f "NAME", "MODEL", "COST", "TASK_TYPES", "GRADE", "SAMPLES", "P50_MS")
    foreach ($row in @($Rows)) { Write-Host (Format-PassportLine -Row $row) }
}

function Show-PassportList {
    param([string]$Root)
    $doc = Read-PassportDocument -Root $Root
    Write-Host ""
    Write-Host "CAPABILITY PASSPORT" -ForegroundColor Cyan
    Write-Host ("file   : " + $doc.path)
    Write-Host ("updated: " + $doc.updated_at)
    if (-not $doc.ok) {
        Write-Host ("status : " + $doc.error) -ForegroundColor Yellow
        return $doc
    }
    Write-Host ""
    Write-Host "AGENTS" -ForegroundColor Green
    $agentRows = @()
    foreach ($key in @($doc.agents.Keys | Sort-Object)) {
        $agentRows += (Format-PassportRow -Entry $doc.agents[$key] -Key ([string]$key))
    }
    if ($agentRows.Count -gt 0) { Show-PassportTable -Rows $agentRows }
    else { Write-Host "  none" }
    Write-Host "MODELS" -ForegroundColor Green
    $modelRows = @()
    foreach ($key in @($doc.models.Keys | Sort-Object)) {
        $modelRows += (Format-PassportRow -Entry $doc.models[$key] -Key ([string]$key))
    }
    if ($modelRows.Count -gt 0) { Show-PassportTable -Rows $modelRows }
    else { Write-Host "  none" }
    return $doc
}

function ConvertTo-PassportJson {
    param($InputObject)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 12
    return (($json -replace "`r`n", "`n") -replace "`n", "`r`n")
}

function Show-PassportUsage {
    Write-Host ""
    Write-Host "capability-passport.ps1 - agent/model capability passport" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -List                     agents + models table (default)"
    Write-Host "  -Json                     the whole passport document as JSON"
    Write-Host "  -Agent <name>             one agent passport (-Json for JSON)"
    Write-Host "  -Model <id>               one model passport (-Json for JSON)"
    Write-Host "  -Update                   refresh reliability/speed from ratings + traces"
    Write-Host "  -DryRun                   with -Update: compute only, write nothing"
    Write-Host "  -Root <path>              repository root override"
    Write-Host ""
    Write-Host "Exit: 0 ok, 2 passport missing/broken, 1 update or argument failure"
    Write-Host ""
}

function Parse-PassportArguments {
    param([object[]]$Arguments)
    $options = @{ Help = $false; List = $false; Json = $false; Update = $false; DryRun = $false; Agent = ""; Model = ""; Root = "" }
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
        elseif ($name -eq "-Update") { $options.Update = $true; $index++ }
        elseif ($name -eq "-DryRun") { $options.DryRun = $true; $index++ }
        elseif ($name -eq "-Help") { $options.Help = $true; $index++ }
        elseif (@("-Agent", "-Model", "-Root") -contains $name) {
            $value = $inlineValue
            if ($null -eq $value) {
                if (($index + 1) -ge $Arguments.Count) { throw "Missing value for $name" }
                $value = [string]$Arguments[$index + 1]
                $index = $index + 2
            } else { $index++ }
            if ($name -eq "-Agent") { $options.Agent = $value }
            elseif ($name -eq "-Model") { $options.Model = $value }
            else { $options.Root = $value }
        } else {
            throw "Unknown argument '$token'. Usage: -List | -Json | -Agent <name> | -Model <id> | -Update [-DryRun]"
        }
    }
    return $options
}

function Invoke-PassportCommandLine {
    param([object[]]$Arguments)
    $options = $null
    try { $options = Parse-PassportArguments -Arguments $Arguments }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-PassportUsage
        exit 1
    }

    if ($options.Help) { Show-PassportUsage; exit 0 }
    $root = $options.Root

    if ($options.Update) {
        $result = Update-PassportFromMetrics -Root $root -DryRun:($options.DryRun)
        if (-not $result.ok) {
            Write-Host ("UPDATE FAILED: " + $result.error) -ForegroundColor Red
            exit 1
        }
        Write-Host ""
        Write-Host "PASSPORT METRICS UPDATED" -ForegroundColor Cyan
        Write-Host ("file        : " + $result.path)
        Write-Host ("written     : " + $result.written + " (dry_run=" + $result.dry_run + ")")
        Write-Host ("updated_at  : " + $result.updated_at)
        Write-Host ("agents      : " + $result.agents_updated + " updated")
        Write-Host ("models      : " + $result.models_updated + " updated")
        Write-Host ("ratings     : parsed=" + $result.ratings_parsed + " skipped=" + $result.ratings_skipped)
        Write-Host ("sessions    : total=" + $result.sessions_total + " attributed=" + $result.sessions_attributed + " traces_scanned=" + $result.traces_scanned)
        if ($options.Json) { Write-Host (ConvertTo-PassportJson $result) }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($options.Agent)) {
        $passport = Get-AgentPassport -Agent $options.Agent -Root $root
        if ($null -eq $passport) {
            if ($options.Json) { Write-Host (ConvertTo-PassportJson ([ordered]@{ ok = $false; agent = $options.Agent; error = "agent passport not found" })) }
            else { Write-Host ("AGENT " + $options.Agent + ": no passport entry") -ForegroundColor Yellow }
            exit 2
        }
        if ($options.Json) { Write-Host (ConvertTo-PassportJson $passport) }
        else {
            Write-Host ""
            Write-Host ("AGENT      : " + $options.Agent)
            if ($null -ne $passport["model"]) { Write-Host ("MODEL      : " + $passport["model"]) }
            if ($null -ne $passport["cost_tier"]) { Write-Host ("COST       : " + $passport["cost_tier"]) }
            Write-Host ("TASK TYPES : " + ((Get-PassportTaskTypes -Passport $passport) -join ","))
            $reliability = $passport["reliability"]
            if ($reliability -is [System.Collections.IDictionary]) {
                Write-Host ("RELIABILITY: avg=" + $reliability["avg_grade"] + " samples=" + $reliability["samples"] + " iterations_avg=" + $reliability["iterations_avg"])
            }
            $speed = $passport["speed"]
            if ($speed -is [System.Collections.IDictionary]) {
                Write-Host ("SPEED      : p50=" + $speed["p50_ms"] + "ms p90=" + $speed["p90_ms"] + "ms sessions=" + $speed["sessions"])
            }
            foreach ($note in @($passport["notes"])) { Write-Host ("NOTE       : " + $note) }
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($options.Model)) {
        $passport = Get-ModelPassport -Model $options.Model -Root $root
        if ($null -eq $passport) {
            if ($options.Json) { Write-Host (ConvertTo-PassportJson ([ordered]@{ ok = $false; model = $options.Model; error = "model passport not found" })) }
            else { Write-Host ("MODEL " + $options.Model + ": no passport entry") -ForegroundColor Yellow }
            exit 2
        }
        if ($options.Json) { Write-Host (ConvertTo-PassportJson $passport) }
        else {
            Write-Host ""
            Write-Host ("MODEL      : " + $options.Model)
            if ($null -ne $passport["cost_tier"]) { Write-Host ("COST       : " + $passport["cost_tier"]) }
            Write-Host ("TASK TYPES : " + ((Get-PassportTaskTypes -Passport $passport) -join ","))
            $limits = $passport["limits"]
            if ($limits -is [System.Collections.IDictionary]) {
                Write-Host ("LIMITS     : requests_per_day=" + $limits["requests_per_day"] + " tokens_per_day=" + $limits["tokens_per_day"] + " confidence=" + $limits["confidence"])
            }
            $reliability = $passport["reliability"]
            if ($reliability -is [System.Collections.IDictionary]) {
                Write-Host ("RELIABILITY: avg=" + $reliability["avg_grade"] + " samples=" + $reliability["samples"])
            }
            $speed = $passport["speed"]
            if ($speed -is [System.Collections.IDictionary]) {
                Write-Host ("SPEED      : tps_p50=" + $speed["tps_p50"] + " latency_s=" + $speed["latency_s"] + " p50=" + $speed["p50_ms"] + "ms sessions=" + $speed["sessions"])
            }
            foreach ($note in @($passport["notes"])) { Write-Host ("NOTE       : " + $note) }
        }
        exit 0
    }

    $doc = Read-PassportDocument -Root $root
    if ($options.Json) {
        if (-not $doc.ok) {
            Write-Host (ConvertTo-PassportJson ([ordered]@{ ok = $false; path = $doc.path; error = $doc.error }))
            exit 2
        }
        Write-Host (ConvertTo-PassportJson $doc)
        exit 0
    }
    [void](Show-PassportList -Root $root)
    if (-not $doc.ok) { exit 2 }
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PassportCommandLine -Arguments $args
}
