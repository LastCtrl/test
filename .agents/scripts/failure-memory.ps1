# failure-memory.ps1 - P3 failure registry: normalised failure signatures and hints.
param(
    [Alias('Record')][switch]$FailureRecord,
    [Alias('List')][switch]$FailureList,
    [Alias('Json')][switch]$FailureJson,
    [Alias('Stats')][switch]$FailureStats,
    [Alias('Hints')][switch]$FailureHints,
    [Alias('TaskType')][string]$FailureTaskType = '',
    [Alias('Agent')][string]$FailureAgent = '',
    [Alias('Root')][string]$FailureRoot = '',
    [Alias('MaxFiles')][int]$FailureMaxFiles = 500
)

$script:FailureScriptRoot = $PSScriptRoot
$script:FailureUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:FailureMaxFileBytes = 8 * 1024 * 1024
$script:FailureRegistryName = 'failure-memory.jsonl'
$script:FailureFailedStatuses = @('failed', 'failure', 'error', 'timeout', 'timed-out', 'blocked', 'dead', 'cancelled', 'canceled')
$script:FailureTaskTypeOrder = @('security', 'review', 'test', 'docs', 'data', 'integration', 'frontend', 'mobile', 'orchestration', 'ops', '1c', 'business', 'research', 'code')
$script:FailureTaskTypeKeywords = @{
    security      = @('security', 'xss', 'injection', 'exploit', 'vulnerab', 'cve', 'secret', 'audit', 'malware')
    review        = @('review', 'verdict', 'qa-engineer', 'code-reviewer', 'approve', 'reject', 'acceptance')
    test          = @('test', 'tests', 'pester', 'vitest', 'spec', 'coverage', 'fixture', 'assert')
    docs          = @('doc', 'docs', 'readme', 'changelog', 'knowledge-base', 'guide', 'handbook')
    data          = @('etl', 'xlsx', 'excel', 'csv', 'sql', 'clickhouse', 'airflow', 'database', 'db-')
    integration   = @('mcp', 'bridge', 'webhook', 'telegram', 'gateway', 'integration', 'api-')
    frontend      = @('react', 'css', 'html', 'frontend', 'canvas', 'dom', 'ui-')
    mobile        = @('android', 'ios', 'mobile')
    orchestration = @('agent', 'orchestr', 'team-lead', 'worktree', 'registry', 'daemon', 'poller')
    ops           = @('ops', 'deploy', 'service', 'scheduler', 'inbox', 'outbox', 'dead-letter', 'health-check', 'sync-agents', 'cleanup')
    '1c'          = @('1c', 'bsl', 'erp')
    business      = @('business', 'forecast', 'kpi', 'invoice')
    research      = @('research', 'survey', 'analysis', 'benchmark')
}
$script:FailurePassportPath = ''
$script:FailurePassportMap = $null
$script:FailureVerdictsAvailable = $false
$script:FailureReviewScript = Join-Path $script:FailureScriptRoot 'review-disagreement.ps1'
if (Test-Path -LiteralPath $script:FailureReviewScript -PathType Leaf) {
    try {
        . $script:FailureReviewScript
        $script:FailureVerdictsAvailable = $true
    } catch {
        $script:FailureVerdictsAvailable = $false
    }
}

function Get-FailureRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($script:FailureScriptRoot) {
        return (Split-Path (Split-Path $script:FailureScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-FailurePaths {
    param([string]$Root)
    $resolved = Get-FailureRoot -Root $Root
    $memory = Join-Path $resolved '.memory'
    $buffer = Join-Path $resolved 'CONTEXT-BUFFER.md'
    if ($script:FailureVerdictsAvailable) {
        try { $buffer = Get-ReviewBufferPath -Root $resolved -BufferPath '' } catch { }
    }
    return [pscustomobject]@{
        Root          = $resolved
        Memory        = $memory
        Registry      = (Join-Path $memory $script:FailureRegistryName)
        EvidenceDir   = (Join-Path $memory 'evidence')
        DeadLetterDir = (Join-Path $memory 'dead-letter')
        KnowledgeBase = (Join-Path $resolved 'KNOWLEDGE-BASE.md')
        Buffer        = $buffer
        Passport      = (Join-Path $resolved '.agents\config\capability-passport.json')
    }
}

function Read-FailureTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt $script:FailureMaxFileBytes) { return '' }
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        return ''
    }
}

function ConvertTo-FailureTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    $dto = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $dto.UtcDateTime
    }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Local) }
        return $dt.ToUniversalTime()
    }
    return $null
}

function Format-FailureTime {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-FailureTaskType {
    param([string]$Text, [string]$Fallback = 'code')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Fallback }
    $lower = $Text.ToLowerInvariant()
    foreach ($type in $script:FailureTaskTypeOrder) {
        $keywords = $script:FailureTaskTypeKeywords[$type]
        if ($null -eq $keywords) { continue }
        foreach ($keyword in $keywords) {
            $pattern = '\b' + [regex]::Escape($keyword)
            if ($keyword -match '[a-z0-9]$') { $pattern = $pattern + '\b' }
            if ([regex]::IsMatch($lower, $pattern)) { return $type }
        }
    }
    return $Fallback
}

function ConvertTo-FailureSlug {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s.Trim('-')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    return $s
}

function ConvertTo-FailureReasonCode {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', ' ')
    $s = [regex]::Replace($s, '\b[0-9a-f]{16,}\b', ' ')
    $s = [regex]::Replace($s, '\b(?:task|us|bug|spr|p|req|issue)[-_]?\d{1,5}(?:[-_]\d{1,5})?\b', ' ')
    $s = [regex]::Replace($s, '[a-z]:\\[^\s"'']*', ' ')
    $s = [regex]::Replace($s, '(?:[a-z0-9_.-]+[\\/])+[a-z0-9_.-]+', ' ')
    $s = [regex]::Replace($s, '\d+', '#')
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s.Trim('-')
    if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
    $tokens = @($s -split '-' | Where-Object { $_.Length -ge 2 })
    if ($tokens.Count -eq 0) { return 'unknown' }
    if ($tokens.Count -gt 6) { $tokens = @($tokens[0..5]) }
    $code = ($tokens -join '-')
    if ($code.Length -gt 60) { $code = $code.Substring(0, 60).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($code)) { return 'unknown' }
    return $code
}

function Get-FailurePassportMap {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($script:FailurePassportPath) -and $script:FailurePassportPath -eq $Path -and $null -ne $script:FailurePassportMap) {
        return $script:FailurePassportMap
    }
    $map = @{}
    $raw = Read-FailureTextFile -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $doc = $null
        try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
        if ($null -ne $doc -and $null -ne $doc.agents) {
            foreach ($property in $doc.agents.PSObject.Properties) {
                $model = [string]$property.Value.model
                if (-not [string]::IsNullOrWhiteSpace($model)) { $map[$property.Name.ToLowerInvariant()] = $model }
            }
        }
    }
    $script:FailurePassportPath = $Path
    $script:FailurePassportMap = $map
    return $map
}

function Get-FailureModelForAgent {
    param([hashtable]$Map, [string]$AgentName)
    if ([string]::IsNullOrWhiteSpace($AgentName)) { return '' }
    $key = $AgentName.Trim().ToLowerInvariant()
    if ($Map.ContainsKey($key)) { return [string]$Map[$key] }
    return ''
}

function New-FailureOccurrence {
    param(
        [string]$Source,
        [string]$OccurrenceId,
        [string]$TaskId,
        [string]$Text,
        [string]$ReasonText,
        [string]$ReasonOverride = '',
        [string]$AgentName = '',
        [string]$Model = '',
        [bool]$Fixed = $false,
        $Time = $null,
        [string]$TaskTypeOverride = ''
    )
    $taskType = $TaskTypeOverride
    if ([string]::IsNullOrWhiteSpace($taskType)) {
        $taskType = Get-FailureTaskType -Text ($Text + ' ' + $ReasonText)
    }
    $reasonCode = $ReasonOverride
    if ([string]::IsNullOrWhiteSpace($reasonCode)) {
        $reasonCode = ConvertTo-FailureReasonCode -Text $ReasonText
    }
    return [pscustomobject]@{
        source        = $Source
        occurrence_id = $OccurrenceId
        task_id       = $TaskId
        task_type     = $taskType
        reason_code   = $reasonCode
        agent         = $AgentName
        model         = $Model
        fixed         = $Fixed
        time          = $Time
        signature     = ($taskType + '|' + $reasonCode)
    }
}

function Get-FailureEvidenceOccurrences {
    param([string]$Dir, [int]$MaxFiles, [hashtable]$ModelMap)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $MaxFiles) { $files = @($files | Select-Object -First $MaxFiles) }
    foreach ($file in $files) {
        $raw = Read-FailureTextFile -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $doc = $null
        try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
        if ($null -eq $doc) { continue }
        $taskId = [string]$doc.task_id
        if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
        $index = 0
        foreach ($attempt in @($doc.attempts)) {
            if ($null -eq $attempt) { continue }
            $index++
            $hasExit = ($null -ne $attempt.exit_code) -and (-not [string]::IsNullOrWhiteSpace([string]$attempt.exit_code))
            $exit = 0
            if ($hasExit) { [void][int]::TryParse([string]$attempt.exit_code, [ref]$exit) }
            $status = ([string]$attempt.status).ToLowerInvariant()
            $isFailure = $false
            if ($hasExit -and ($exit -ne 0)) { $isFailure = $true }
            elseif ($script:FailureFailedStatuses -contains $status) { $isFailure = $true }
            if (-not $isFailure) { continue }
            $reasonText = [string]$attempt.reason
            $reasonOverride = ''
            if ([string]::IsNullOrWhiteSpace($reasonText)) {
                if ($hasExit) {
                    $reasonOverride = ('exit-code-' + $exit)
                    $reasonText = ('exit-code-' + $exit)
                } else {
                    $reasonText = $status
                }
            }
            $agentName = [string]$attempt.agent
            $attemptId = [string]$attempt.attempt_id
            if ([string]::IsNullOrWhiteSpace($attemptId)) { $attemptId = ('idx-' + $index) }
            $time = ConvertTo-FailureTime -Text ([string]$attempt.finished_at)
            if ($null -eq $time) { $time = ConvertTo-FailureTime -Text ([string]$attempt.started_at) }
            [void]$out.Add((New-FailureOccurrence -Source 'evidence' -OccurrenceId ($taskId + '|' + $attemptId) -TaskId $taskId `
                -Text (([string]$attempt.command) + ' ' + $taskId) -ReasonText $reasonText -ReasonOverride $reasonOverride `
                -AgentName $agentName -Model (Get-FailureModelForAgent -Map $ModelMap -AgentName $agentName) -Time $time))
        }
    }
    return @($out)
}

function Get-FailureDeadLetterOccurrences {
    param([string]$Dir, [int]$MaxFiles, [hashtable]$ModelMap)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $MaxFiles) { $files = @($files | Select-Object -First $MaxFiles) }
    foreach ($file in $files) {
        $raw = Read-FailureTextFile -Path $file.FullName
        $doc = $null
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
        }
        $status = ''
        $type = ''
        $taskId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $agentName = ''
        $payload = ''
        $response = ''
        $time = $null
        if ($null -ne $doc) {
            $status = ([string]$doc.status).ToLowerInvariant()
            $type = ([string]$doc.type).ToLowerInvariant()
            $id = [string]$doc.id
            if (-not [string]::IsNullOrWhiteSpace($id)) { $taskId = $id }
            $agentName = [string]$doc.to
            $payload = [string]$doc.payload
            $response = [string]$doc.response
            $time = ConvertTo-FailureTime -Text ([string]$doc.finishedAt)
            if ($null -eq $time) { $time = ConvertTo-FailureTime -Text ([string]$doc.startedAt) }
        }
        if ($status -eq 'done' -or $type -eq 'done') { continue }
        $reasonText = ''
        $reasonOverride = ''
        $match = [regex]::Match($response, '(?im)^\s*REASON\s*:\s*(?<r>[^\r\n]+)')
        if ($match.Success) { $reasonText = $match.Groups['r'].Value }
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            $match = [regex]::Match(($response + ' ' + $payload), '(?i)(?:reason|error)\s*[:=]\s*(?<r>[^\r\n;]+)')
            if ($match.Success) { $reasonText = $match.Groups['r'].Value }
        }
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $reasonOverride = 'dead-letter-unreadable'
                $reasonText = 'dead-letter-unreadable'
            } else {
                $reasonOverride = 'dead-letter'
                $reasonText = 'dead-letter'
            }
        }
        [void]$out.Add((New-FailureOccurrence -Source 'dead-letter' -OccurrenceId $file.Name -TaskId $taskId `
            -Text ($payload + ' ' + $response + ' ' + $taskId) -ReasonText $reasonText -ReasonOverride $reasonOverride `
            -AgentName $agentName -Model (Get-FailureModelForAgent -Map $ModelMap -AgentName $agentName) -Time $time))
    }
    return @($out)
}

function Get-FailureKnowledgeBaseOccurrences {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    $text = Read-FailureTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $headings = [regex]::Matches($text, '(?m)^###\s+(?<id>BUG-[0-9]{1,4})\b(?<rest>[^\r\n]*)')
    for ($hi = 0; $hi -lt $headings.Count; $hi++) {
        $heading = $headings[$hi]
        $bodyStart = $heading.Index + $heading.Length
        $bodyEnd = if ($hi + 1 -lt $headings.Count) { $headings[$hi + 1].Index } else { $text.Length }
        if ($bodyEnd -lt $bodyStart) { continue }
        $body = $text.Substring($bodyStart, $bodyEnd - $bodyStart)
        $bugId = $heading.Groups['id'].Value
        $title = $heading.Groups['rest'].Value

        $severity = 'unknown'
        $severityMatch = [regex]::Match($body, '(?i)\*\*Severity\*\*\s*:\s*(?<sev>[A-Za-z]+)')
        if ($severityMatch.Success) { $severity = $severityMatch.Groups['sev'].Value.ToLowerInvariant() }

        $fixed = $false
        $statusMatch = [regex]::Match($body, '(?i)\*\*Status\*\*\s*:\s*(?<st>[^\r\n]*)')
        if ($statusMatch.Success) {
            $statusText = $statusMatch.Groups['st'].Value
            if ($statusText -match '(?i)^\s*(?:FIXED|RESOLVED|CLOSED|DONE)') { $fixed = $true }
        }

        $fileField = ''
        $fileMatch = [regex]::Match($body, '(?i)\*\*File\*\*\s*:\s*(?<file>[^\s,\r\n|]+)')
        if ($fileMatch.Success) { $fileField = $fileMatch.Groups['file'].Value }
        $base = ''
        if (-not [string]::IsNullOrWhiteSpace($fileField)) {
            $leaf = $fileField -replace '.*[\\/]', ''
            $leaf = ($leaf -split ':')[0]
            $base = ConvertTo-FailureSlug -Text ($leaf -replace '\.[a-z0-9]{1,6}$', '')
        }

        $agentName = ''
        $agentMatch = [regex]::Match($body, '(?i)\*\*Discovered by\*\*\s*:\s*(?<who>[a-z][a-z0-9._-]{1,30})')
        if ($agentMatch.Success) { $agentName = $agentMatch.Groups['who'].Value.ToLowerInvariant() }

        $time = $null
        $dateMatch = [regex]::Match($body, '(?i)\*\*Date\*\*\s*:\s*(?<d>\d{4}-\d{2}-\d{2})')
        if ($dateMatch.Success) { $time = ConvertTo-FailureTime -Text $dateMatch.Groups['d'].Value }

        $reasonCode = 'kb-' + $severity
        if (-not [string]::IsNullOrWhiteSpace($base)) { $reasonCode = 'kb-' + $base + '-' + $severity }
        [void]$out.Add((New-FailureOccurrence -Source 'kb' -OccurrenceId $bugId -TaskId $bugId `
            -Text ($title + ' ' + $fileField) -ReasonText $severity -ReasonOverride $reasonCode `
            -AgentName $agentName -Fixed $fixed -Time $time))
    }
    return @($out)
}

function Get-FailureReviewerOccurrences {
    param([string]$Root, [string]$Buffer, [hashtable]$ModelMap)
    $out = New-Object System.Collections.ArrayList
    if (-not $script:FailureVerdictsAvailable) { return @() }
    $verdicts = @()
    try { $verdicts = @(Get-ReviewVerdicts -Root $Root -BufferPath $Buffer) } catch { return @() }
    foreach ($verdict in $verdicts) {
        if ($null -eq $verdict) { continue }
        if ([string]$verdict.verdict -ne 'reject') { continue }
        $taskId = [string]$verdict.task_key
        if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = 'unknown-task' }
        $agentName = [string]$verdict.agent
        $line = [int]$verdict.line
        [void]$out.Add((New-FailureOccurrence -Source 'review' -OccurrenceId ($agentName + '|' + $line) -TaskId $taskId `
            -Text ([string]$verdict.raw_verdict) -ReasonText 'reviewer-reject' -ReasonOverride 'reviewer-reject' `
            -AgentName $agentName -Model (Get-FailureModelForAgent -Map $ModelMap -AgentName $agentName) `
            -Time $verdict.time -TaskTypeOverride 'review'))
    }
    return @($out)
}

function Get-FailureOccurrences {
    param([string]$Root, [int]$MaxFiles = 500)
    $paths = Get-FailurePaths -Root $Root
    $modelMap = Get-FailurePassportMap -Path $paths.Passport
    $all = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $collect = {
        param($items)
        foreach ($item in @($items)) {
            if ($null -eq $item) { continue }
            $key = [string]$item.source + '|' + [string]$item.occurrence_id
            if ($seen.Add($key)) { [void]$all.Add($item) }
        }
    }
    & $collect (Get-FailureEvidenceOccurrences -Dir $paths.EvidenceDir -MaxFiles $MaxFiles -ModelMap $modelMap)
    & $collect (Get-FailureDeadLetterOccurrences -Dir $paths.DeadLetterDir -MaxFiles $MaxFiles -ModelMap $modelMap)
    & $collect (Get-FailureKnowledgeBaseOccurrences -Path $paths.KnowledgeBase)
    & $collect (Get-FailureReviewerOccurrences -Root $paths.Root -Buffer $paths.Buffer -ModelMap $modelMap)
    return @($all)
}

function Get-FailureAggregatedEntries {
    param([object[]]$Occurrences, [string]$Root = '')
    $modelMap = Get-FailurePassportMap -Path (Get-FailurePaths -Root $Root).Passport
    $bySignature = @{}
    foreach ($occurrence in @($Occurrences)) {
        if ($null -eq $occurrence) { continue }
        $signature = [string]$occurrence.signature
        if (-not $bySignature.ContainsKey($signature)) {
            $bySignature[$signature] = [pscustomobject]@{
                signature      = $signature
                task_type      = [string]$occurrence.task_type
                reason_code    = [string]$occurrence.reason_code
                count          = 0
                kb_count       = 0
                kb_open        = 0
                first_seen     = $null
                last_seen      = $null
                sample_task_id = ''
                agents         = @{}
                occurrences    = New-Object System.Collections.ArrayList
            }
        }
        $entry = $bySignature[$signature]
        $entry.count++
        $entry.occurrences.Add($occurrence) | Out-Null
        if ([string]$occurrence.source -eq 'kb') {
            $entry.kb_count++
            if (-not [bool]$occurrence.fixed) { $entry.kb_open++ }
        }
        $agentName = [string]$occurrence.agent
        if (-not [string]::IsNullOrWhiteSpace($agentName)) {
            $key = $agentName.ToLowerInvariant()
            if (-not $entry.agents.ContainsKey($key)) { $entry.agents[$key] = 0 }
            $entry.agents[$key] = [int]$entry.agents[$key] + 1
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.sample_task_id) -and (-not [string]::IsNullOrWhiteSpace([string]$occurrence.task_id))) {
            $entry.sample_task_id = [string]$occurrence.task_id
        }
        if ($null -ne $occurrence.time) {
            if ($null -eq $entry.first_seen -or $occurrence.time -lt $entry.first_seen) { $entry.first_seen = $occurrence.time }
            if ($null -eq $entry.last_seen -or $occurrence.time -gt $entry.last_seen) { $entry.last_seen = $occurrence.time }
        }
    }

    $entries = New-Object System.Collections.ArrayList
    foreach ($signature in @($bySignature.Keys | Sort-Object)) {
        $bucket = $bySignature[$signature]
        $agentName = ''
        if ($bucket.agents.Count -gt 0) {
            $best = -1
            foreach ($name in @($bucket.agents.Keys | Sort-Object)) {
                if ([int]$bucket.agents[$name] -gt $best) { $best = [int]$bucket.agents[$name]; $agentName = $name }
            }
        }
        $model = ''
        $fixed = $false
        if ($bucket.kb_count -gt 0) { $fixed = ($bucket.kb_open -eq 0) }
        [void]$entries.Add([pscustomobject]@{
            signature      = $bucket.signature
            task_type      = $bucket.task_type
            agent          = $agentName
            model          = (Get-FailureModelForAgent -Map $modelMap -AgentName $agentName)
            reason_code    = $bucket.reason_code
            first_seen     = (Format-FailureTime -Value $bucket.first_seen)
            last_seen      = (Format-FailureTime -Value $bucket.last_seen)
            count          = $bucket.count
            sample_task_id = $bucket.sample_task_id
            fixed          = $fixed
        })
    }
    return @($entries | Sort-Object -Property @{ Expression = { [int]$_.count }; Descending = $true }, signature)
}

function Read-FailureRegistry {
    param([string]$Path)
    $entries = New-Object System.Collections.ArrayList
    $raw = Read-FailureTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    foreach ($line in @($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $null
        try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { $entry = $null }
        if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.signature)) { [void]$entries.Add($entry) }
    }
    return @($entries)
}

function ConvertTo-FailureRegistryLine {
    param($Entry)
    $payload = [ordered]@{
        signature      = [string]$Entry.signature
        task_type      = [string]$Entry.task_type
        agent          = [string]$Entry.agent
        model          = [string]$Entry.model
        reason_code    = [string]$Entry.reason_code
        first_seen     = [string]$Entry.first_seen
        last_seen      = [string]$Entry.last_seen
        count          = [int]$Entry.count
        sample_task_id = [string]$Entry.sample_task_id
        fixed          = [bool]$Entry.fixed
    }
    return ($payload | ConvertTo-Json -Compress -Depth 4)
}

function Write-FailureRegistry {
    param([string]$Path, [object[]]$Entries)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $lines = New-Object System.Collections.ArrayList
    foreach ($entry in @($Entries)) { [void]$lines.Add((ConvertTo-FailureRegistryLine -Entry $entry)) }
    $text = ($lines -join "`r`n")
    if ($lines.Count -gt 0) { $text += "`r`n" }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $text, $script:FailureUtf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $Path
}

function Invoke-FailureRecord {
    param([string]$Root, [int]$MaxFiles = 500)
    $paths = Get-FailurePaths -Root $Root
    $existing = @{}
    foreach ($entry in @(Read-FailureRegistry -Path $paths.Registry)) { $existing[[string]$entry.signature] = $entry }
    $occurrences = @(Get-FailureOccurrences -Root $Root -MaxFiles $MaxFiles)
    $fresh = @(Get-FailureAggregatedEntries -Occurrences $occurrences -Root $Root)

    $merged = New-Object System.Collections.ArrayList
    $freshBySignature = @{}
    foreach ($entry in $fresh) { $freshBySignature[[string]$entry.signature] = $entry }
    $added = 0

    foreach ($entry in $fresh) {
        $prior = $null
        if ($existing.ContainsKey([string]$entry.signature)) { $prior = $existing[[string]$entry.signature] }
        if ($null -eq $prior) { $added++ }
        $firstSeen = [string]$entry.first_seen
        $lastSeen = [string]$entry.last_seen
        $count = [int]$entry.count
        $sample = [string]$entry.sample_task_id
        $fixed = [bool]$entry.fixed
        if ($null -ne $prior) {
            $priorFirst = [string]$prior.first_seen
            if ($priorFirst -and ((-not $firstSeen) -or ($priorFirst -lt $firstSeen))) { $firstSeen = $priorFirst }
            $priorLast = [string]$prior.last_seen
            if ($priorLast -and ((-not $lastSeen) -or ($priorLast -gt $lastSeen))) { $lastSeen = $priorLast }
            if ([int]$prior.count -gt $count) { $count = [int]$prior.count }
            if (-not $sample) { $sample = [string]$prior.sample_task_id }
            if ([bool]$prior.fixed) { $fixed = $true }
        }
        [void]$merged.Add([pscustomobject]@{
            signature      = [string]$entry.signature
            task_type      = [string]$entry.task_type
            agent          = [string]$entry.agent
            model          = [string]$entry.model
            reason_code    = [string]$entry.reason_code
            first_seen     = $firstSeen
            last_seen      = $lastSeen
            count          = $count
            sample_task_id = $sample
            fixed          = $fixed
        })
    }

    foreach ($signature in @($existing.Keys | Sort-Object)) {
        if ($freshBySignature.ContainsKey($signature)) { continue }
        $prior = $existing[$signature]
        [void]$merged.Add([pscustomobject]@{
            signature      = [string]$prior.signature
            task_type      = [string]$prior.task_type
            agent          = [string]$prior.agent
            model          = [string]$prior.model
            reason_code    = [string]$prior.reason_code
            first_seen     = [string]$prior.first_seen
            last_seen      = [string]$prior.last_seen
            count          = [int]$prior.count
            sample_task_id = [string]$prior.sample_task_id
            fixed          = [bool]$prior.fixed
        })
    }

    $ordered = @($merged | Sort-Object -Property @{ Expression = { [int]$_.count }; Descending = $true }, signature)
    $wrote = $false
    if ($ordered.Count -gt 0 -or $existing.Count -eq 0) {
        Write-FailureRegistry -Path $paths.Registry -Entries $ordered | Out-Null
        $wrote = $true
    }
    return [pscustomobject]@{
        ok                = $true
        mode              = 'record'
        registry          = $paths.Registry
        wrote             = $wrote
        signatures        = $ordered.Count
        occurrences       = $occurrences.Count
        added_signatures  = $added
    }
}

function Get-FailureRegistryEntries {
    param([string]$Root)
    $paths = Get-FailurePaths -Root $Root
    return @(Read-FailureRegistry -Path $paths.Registry)
}

function Get-FailureHints {
    param([string]$TaskType = '', [string]$AgentName = '', [string]$Root = '')
    $entries = @(Get-FailureRegistryEntries -Root $Root)
    $result = New-Object System.Collections.ArrayList
    foreach ($entry in $entries) {
        if (-not [string]::IsNullOrWhiteSpace($TaskType)) {
            if ([string]$entry.task_type -ne $TaskType) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($AgentName)) {
            if ([string]$entry.agent -ne $AgentName.ToLowerInvariant()) { continue }
        }
        [void]$result.Add($entry)
    }
    return @($result | Sort-Object -Property @{ Expression = { [int]$_.count }; Descending = $true }, last_seen)
}

function Get-FailureStats {
    param([string]$Root)
    $entries = @(Get-FailureRegistryEntries -Root $Root)
    $occurrences = 0
    $fixed = 0
    $byTaskType = @{}
    $byReason = @{}
    $agents = @{}
    foreach ($entry in $entries) {
        $occurrences += [int]$entry.count
        if ([bool]$entry.fixed) { $fixed++ }
        $taskType = [string]$entry.task_type
        if (-not $byTaskType.ContainsKey($taskType)) { $byTaskType[$taskType] = 0 }
        $byTaskType[$taskType] = [int]$byTaskType[$taskType] + [int]$entry.count
        $reason = [string]$entry.reason_code
        if (-not $byReason.ContainsKey($reason)) { $byReason[$reason] = 0 }
        $byReason[$reason] = [int]$byReason[$reason] + [int]$entry.count
        $agentName = [string]$entry.agent
        if (-not [string]::IsNullOrWhiteSpace($agentName)) { $agents[$agentName] = $true }
    }
    $typeRows = New-Object System.Collections.ArrayList
    foreach ($name in @($byTaskType.Keys | Sort-Object)) {
        [void]$typeRows.Add([pscustomobject]@{ task_type = $name; occurrences = [int]$byTaskType[$name] })
    }
    $reasonRows = New-Object System.Collections.ArrayList
    foreach ($name in @($byReason.Keys | Sort-Object)) {
        [void]$reasonRows.Add([pscustomobject]@{ reason_code = $name; occurrences = [int]$byReason[$name] })
    }
    return [pscustomobject]@{
        ok                  = $true
        mode                = 'stats'
        registry            = (Get-FailurePaths -Root $Root).Registry
        signatures          = $entries.Count
        occurrences         = $occurrences
        fixed_signatures    = $fixed
        open_signatures     = ($entries.Count - $fixed)
        agents              = @($agents.Keys | Sort-Object)
        by_task_type        = @($typeRows | Sort-Object -Property @{ Expression = { [int]$_.occurrences }; Descending = $true }, task_type)
        by_reason_code      = @($reasonRows | Sort-Object -Property @{ Expression = { [int]$_.occurrences }; Descending = $true }, reason_code)
    }
}

function ConvertTo-FailureJson {
    param($InputObject, [int]$Depth = 8)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

function ConvertTo-FailureJsonArray {
    param([object[]]$Items)
    $parts = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        [void]$parts.Add((ConvertTo-FailureJson -InputObject $item -Depth 6))
    }
    if ($parts.Count -eq 0) { return '[]' }
    return ('[' + ($parts -join ',') + ']')
}

function Format-FailureEntryLines {
    param([object[]]$Items)
    $lines = New-Object System.Collections.ArrayList
    foreach ($entry in @($Items)) {
        $state = 'open'
        if ([bool]$entry.fixed) { $state = 'fixed' }
        [void]$lines.Add(('  {0,-9} {1,4}  {2,-44} {3}' -f $state, [int]$entry.count, [string]$entry.signature, [string]$entry.last_seen))
        $agentName = [string]$entry.agent
        if ([string]::IsNullOrWhiteSpace($agentName)) { $agentName = '-' }
        [void]$lines.Add(('      agent={0} model={1} sample={2}' -f $agentName, [string]$entry.model, [string]$entry.sample_task_id))
    }
    return @($lines)
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        if ($FailureRecord) {
            $summary = Invoke-FailureRecord -Root $FailureRoot -MaxFiles $FailureMaxFiles
            if ($FailureJson) {
                Write-Output (ConvertTo-FailureJson -InputObject $summary -Depth 4)
            } else {
                Write-Host ('failure-memory: recorded {0} signature(s), {1} occurrence(s), added {2} new' -f $summary.signatures, $summary.occurrences, $summary.added_signatures) -ForegroundColor Cyan
                Write-Host ('  registry: ' + $summary.registry)
            }
        } elseif ($FailureStats) {
            $stats = Get-FailureStats -Root $FailureRoot
            if ($FailureJson) {
                Write-Output (ConvertTo-FailureJson -InputObject $stats -Depth 6)
            } else {
                Write-Host ('=== failure-memory stats: {0} signature(s), {1} occurrence(s), {2} fixed ===' -f $stats.signatures, $stats.occurrences, $stats.fixed_signatures) -ForegroundColor Cyan
                Write-Host ('  registry: ' + $stats.registry)
                if (@($stats.by_task_type).Count -gt 0) {
                    Write-Host '  by task type:'
                    foreach ($row in @($stats.by_task_type)) { Write-Host ('    {0,-14} {1}' -f $row.task_type, $row.occurrences) }
                }
                if (@($stats.by_reason_code).Count -gt 0) {
                    Write-Host '  top reasons:'
                    $topReasons = @($stats.by_reason_code | Select-Object -First 5)
                    foreach ($row in $topReasons) { Write-Host ('    {0,-32} {1}' -f $row.reason_code, $row.occurrences) }
                }
            }
        } elseif ($FailureHints) {
            $hints = @(Get-FailureHints -TaskType $FailureTaskType -AgentName $FailureAgent -Root $FailureRoot)
            if ($FailureJson) {
                Write-Output (ConvertTo-FailureJsonArray -Items $hints)
            } else {
                $label = $FailureTaskType
                if ([string]::IsNullOrWhiteSpace($label)) { $label = '<any>' }
                Write-Host ('=== failure hints for task_type=' + $label + ' (' + $hints.Count + ') ===') -ForegroundColor Cyan
                if ($hints.Count -eq 0) { Write-Host '  no prior failures recorded' } else { Format-FailureEntryLines -Items $hints | Write-Output }
            }
        } else {
            $entries = @(Get-FailureRegistryEntries -Root $FailureRoot)
            if ($FailureJson) {
                Write-Output (ConvertTo-FailureJsonArray -Items $entries)
            } else {
                Write-Host ('=== failure-memory: {0} signature(s) ===' -f $entries.Count) -ForegroundColor Cyan
                if ($entries.Count -eq 0) { Write-Host '  empty (run -Record to collect from evidence/dead-letter/KB/reviews)' } else { Format-FailureEntryLines -Items $entries | Write-Output }
            }
        }
    } catch {
        Write-Error ('failure-memory failed: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
