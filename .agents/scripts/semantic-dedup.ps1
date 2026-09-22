# semantic-dedup.ps1 - P3 semantic duplicate detection for the agent-hq bus.
# Read-only: scans .memory\inbox, .memory\dead-letter, .memory\archive and
# projects\*\queue.json, canonicalises payload text and groups near-duplicates by
# token Jaccard similarity. It NEVER deletes, moves or blocks a message.
# Integration hook: dot-source and call Test-IsDuplicate -Text <payload> -Root <root>
# (e.g. from message-queue before enqueue). Not wired into any caller yet.
param(
    [Alias('Scan')][switch]$SemanticScan,
    [Alias('IsDuplicate')][switch]$SemanticIsDuplicate,
    [Alias('List')][switch]$SemanticList,
    [Alias('Json')][switch]$SemanticJson,
    [Alias('Text')][string]$SemanticText = '',
    [Alias('Threshold')][double]$SemanticThreshold = 0.8,
    [Alias('Include')][string[]]$SemanticInclude = @(),
    [Alias('Exclude')][string[]]$SemanticExclude = @(),
    [Alias('Root')][string]$SemanticRoot = ''
)

$script:SemanticScriptRoot = $PSScriptRoot

function Get-SemanticRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($script:SemanticScriptRoot) { return (Split-Path (Split-Path $script:SemanticScriptRoot -Parent) -Parent) }
    return (Get-Location).Path
}

function Get-SemanticThreshold {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return 0.8 }
    if ($Value -lt 0.0) { return 0.0 }
    if ($Value -gt 1.0) { return 1.0 }
    return $Value
}

function Format-SemanticNumber {
    param([double]$Value)
    return $Value.ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Expand-SemanticFilter {
    param([string[]]$Values)
    $out = @()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        foreach ($part in ([string]$value -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed -ne '') { $out += $trimmed }
        }
    }
    return @($out)
}

function Test-SemanticAgentAllowed {
    param([string]$Agent, [string[]]$Include, [string[]]$Exclude)
    $name = if ($null -eq $Agent) { '' } else { [string]$Agent }
    $inc = @(Expand-SemanticFilter -Values $Include)
    if ($inc.Count -gt 0 -and -not ($inc -contains $name)) { return $false }
    $exc = @(Expand-SemanticFilter -Values $Exclude)
    if ($exc -contains $name) { return $false }
    return $true
}

# Canonical form: lowercase, paths/guids removed, punctuation -> spaces (letters and
# digits kept), then every token containing a digit is dropped (ids/numbers/versions)
# so "Deploy X #123" and "deploy x #456" collapse to the same token set.
function Get-SemanticCanonicalText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = ([string]$Text).ToLowerInvariant()
    $s = [regex]::Replace($s, '[a-z]:\\[^\s]*', ' ')
    $s = [regex]::Replace($s, '(?:\.{0,2}/)[^\s]*', ' ')
    $s = [regex]::Replace($s, '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', ' ')
    $s = [regex]::Replace($s, '[^\p{L}\p{Nd}]+', ' ')
    $parts = @()
    foreach ($piece in ($s -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($piece)) { continue }
        if ($piece -match '\d') { continue }
        $parts += $piece
    }
    return (($parts -join ' ').Trim())
}

function Get-SemanticTokens {
    param([string]$Text)
    $canonical = Get-SemanticCanonicalText -Text $Text
    if ([string]::IsNullOrWhiteSpace($canonical)) { return @() }
    return @($canonical -split ' ' | Where-Object { $_ -ne '' } | Sort-Object -Unique)
}

function Get-SemanticTokenSimilarity {
    param([string[]]$TokensA, [string[]]$TokensB)
    if ($null -eq $TokensA -or $null -eq $TokensB) { return 0.0 }
    if ($TokensA.Length -eq 0 -or $TokensB.Length -eq 0) { return 0.0 }
    $index = @{}
    foreach ($word in $TokensB) { if (-not $index.ContainsKey($word)) { $index[$word] = $true } }
    $inter = 0
    foreach ($word in $TokensA) { if ($index.ContainsKey($word)) { $inter++ } }
    $union = $TokensA.Length + $TokensB.Length - $inter
    if ($union -le 0) { return 0.0 }
    return [math]::Round($inter / [double]$union, 4)
}

function Get-SemanticSimilarity {
    param([string]$TextA, [string]$TextB)
    $tokensA = @(Get-SemanticTokens -Text $TextA)
    $tokensB = @(Get-SemanticTokens -Text $TextB)
    return (Get-SemanticTokenSimilarity -TokensA $tokensA -TokensB $tokensB)
}

function Read-SemanticJsonFile {
    param([string]$Path)
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-SemanticPayload {
    param([string]$Path, [string[]]$Fields)
    $doc = Read-SemanticJsonFile -Path $Path
    if ($null -ne $doc) {
        foreach ($field in $Fields) {
            $value = $doc.$field
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
        return ''
    }
    try {
        return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
    } catch {
        return ''
    }
}

function New-SemanticItem {
    param([string]$Source, [string]$Agent, [string]$Id, [string]$Path, [string]$Text)
    $tokens = @(Get-SemanticTokens -Text $Text)
    if ($tokens.Count -eq 0) { return $null }
    return [pscustomobject]@{
        source    = $Source
        agent     = $Agent
        id        = $Id
        path      = $Path
        text      = [string]$Text
        canonical = (Get-SemanticCanonicalText -Text $Text)
        tokens    = $tokens
    }
}

function Get-SemanticItems {
    param([string]$Root, [string[]]$Include = @(), [string[]]$Exclude = @())
    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Root)) { return @() }
    $memory = Join-Path $Root '.memory'

    $inbox = Join-Path $memory 'inbox'
    if (Test-Path -LiteralPath $inbox -PathType Container) {
        foreach ($agentDir in @(Get-ChildItem -LiteralPath $inbox -Directory -ErrorAction SilentlyContinue)) {
            if ($agentDir.Name -eq '.gitkeep') { continue }
            $agent = $agentDir.Name
            if (-not (Test-SemanticAgentAllowed -Agent $agent -Include $Include -Exclude $Exclude)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $agentDir.FullName -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $text = Get-SemanticPayload -Path $file.FullName -Fields @('payload')
                $item = New-SemanticItem -Source 'inbox' -Agent $agent -Id $file.BaseName -Path $file.FullName -Text $text
                if ($null -ne $item) { [void]$items.Add($item) }
            }
        }
    }

    foreach ($spec in @(
        @{ Source = 'dead-letter'; Dir = (Join-Path $memory 'dead-letter') },
        @{ Source = 'archive'; Dir = (Join-Path $memory 'archive') }
    )) {
        $dir = $spec.Dir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $doc = Read-SemanticJsonFile -Path $file.FullName
            $agent = 'unknown'
            if ($null -ne $doc -and -not [string]::IsNullOrWhiteSpace([string]$doc.to)) { $agent = [string]$doc.to }
            if (-not (Test-SemanticAgentAllowed -Agent $agent -Include $Include -Exclude $Exclude)) { continue }
            $text = Get-SemanticPayload -Path $file.FullName -Fields @('payload')
            $item = New-SemanticItem -Source $spec.Source -Agent $agent -Id $file.BaseName -Path $file.FullName -Text $text
            if ($null -ne $item) { [void]$items.Add($item) }
        }
    }

    $projects = Join-Path $Root 'projects'
    if (Test-Path -LiteralPath $projects -PathType Container) {
        foreach ($projDir in @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue)) {
            $queue = Join-Path $projDir.FullName 'queue.json'
            if (-not (Test-Path -LiteralPath $queue -PathType Leaf)) { continue }
            $doc = Read-SemanticJsonFile -Path $queue
            if ($null -eq $doc -or $null -eq $doc.tasks) { continue }
            $index = 0
            foreach ($entry in @($doc.tasks)) {
                $index++
                if ($null -eq $entry) { continue }
                $agent = ''
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.assigned_agent)) { $agent = [string]$entry.assigned_agent }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.agent)) { $agent = [string]$entry.agent }
                else { $agent = 'unassigned' }
                if (-not (Test-SemanticAgentAllowed -Agent $agent -Include $Include -Exclude $Exclude)) { continue }
                $parts = @()
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.title)) { $parts += [string]$entry.title }
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.description)) { $parts += [string]$entry.description }
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.payload)) { $parts += [string]$entry.payload }
                $id = if (-not [string]::IsNullOrWhiteSpace([string]$entry.id)) { [string]$entry.id } else { $projDir.Name + '#' + $index }
                $item = New-SemanticItem -Source 'project' -Agent $agent -Id $id -Path $queue -Text ($parts -join ' ')
                if ($null -ne $item) { [void]$items.Add($item) }
            }
        }
    }

    return @($items)
}

function ConvertTo-SemanticMemberView {
    param($Item)
    return [pscustomobject]@{
        source    = $Item.source
        agent     = $Item.agent
        id        = $Item.id
        path      = $Item.path
        text      = $Item.text
        canonical = $Item.canonical
    }
}

# Greedy clustering: a candidate joins a cluster when it is similar to ANY member
# (so A~B, B~C chains group together even when A!~C).
function Find-SemanticDuplicateGroups {
    param([object[]]$Items, [double]$Threshold = 0.8)
    $groups = New-Object System.Collections.ArrayList
    if ($null -eq $Items) { return @($groups) }
    if ($Items.Count -lt 2) { return @($groups) }
    $used = @($false) * $Items.Count
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($used[$i]) { continue }
        $cluster = @($i)
        $used[$i] = $true
        for ($j = $i + 1; $j -lt $Items.Count; $j++) {
            if ($used[$j]) { continue }
            $linked = $false
            foreach ($member in $cluster) {
                $sim = Get-SemanticTokenSimilarity -TokensA $Items[$member].tokens -TokensB $Items[$j].tokens
                if ($sim -ge $Threshold) { $linked = $true; break }
            }
            if ($linked) { $cluster += $j; $used[$j] = $true }
        }
        if ($cluster.Count -gt 1) {
            $score = 0.0
            $members = @()
            foreach ($member in $cluster) {
                $members += $Items[$member]
                foreach ($other in $cluster) {
                    if ($other -le $member) { continue }
                    $pairScore = Get-SemanticTokenSimilarity -TokensA $Items[$member].tokens -TokensB $Items[$other].tokens
                    if ($pairScore -gt $score) { $score = $pairScore }
                }
            }
            [void]$groups.Add([pscustomobject]@{ size = $cluster.Count; score = $score; members = $members })
        }
    }
    return @($groups)
}

function ConvertTo-SemanticGroupView {
    param($Group)
    return [pscustomobject]@{
        size    = $Group.size
        score   = $Group.score
        members = @($Group.members | ForEach-Object { ConvertTo-SemanticMemberView -Item $_ })
    }
}

function Get-SemanticScan {
    param([string]$Root, [double]$Threshold = 0.8, [string[]]$Include = @(), [string[]]$Exclude = @())
    $items = @(Get-SemanticItems -Root $Root -Include $Include -Exclude $Exclude)
    $groups = @(Find-SemanticDuplicateGroups -Items $items -Threshold $Threshold)
    return [pscustomobject]@{
        threshold   = $Threshold
        item_count  = $items.Count
        group_count = $groups.Count
        groups      = $groups
        items       = $items
    }
}

function Test-IsDuplicate {
    param([string]$Text, [string]$Root, [double]$Threshold = 0.8, [string[]]$Include = @(), [string[]]$Exclude = @())
    $items = @(Get-SemanticItems -Root $Root -Include $Include -Exclude $Exclude)
    $tokens = @(Get-SemanticTokens -Text $Text)
    $bestScore = 0.0
    $bestItem = $null
    if ($tokens.Count -gt 0) {
        foreach ($item in $items) {
            $sim = Get-SemanticTokenSimilarity -TokensA $tokens -TokensB $item.tokens
            if ($sim -gt $bestScore) { $bestScore = $sim; $bestItem = $item }
        }
    }
    $isDuplicate = ($null -ne $bestItem) -and ($bestScore -ge $Threshold)
    $matchView = $null
    if ($null -ne $bestItem) { $matchView = ConvertTo-SemanticMemberView -Item $bestItem }
    return [pscustomobject]@{
        text         = [string]$Text
        is_duplicate = $isDuplicate
        similarity   = $bestScore
        threshold    = $Threshold
        compared     = $items.Count
        match        = $matchView
    }
}

function ConvertTo-AsciiJson {
    param($Object)
    $json = ''
    try { $json = ConvertTo-Json -InputObject $Object -Depth 8 } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 128) { [void]$builder.Append($ch) } else { [void]$builder.AppendFormat('\u{0:x4}', $code) }
    }
    return $builder.ToString()
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        $root = Get-SemanticRoot -Root $SemanticRoot
        $threshold = Get-SemanticThreshold -Value $SemanticThreshold
        if ($SemanticIsDuplicate) {
            $result = Test-IsDuplicate -Text $SemanticText -Root $root -Threshold $threshold -Include $SemanticInclude -Exclude $SemanticExclude
            if ($SemanticJson) {
                Write-Output (ConvertTo-AsciiJson -Object $result)
            } elseif ($result.is_duplicate) {
                Write-Host ('DUPLICATE similarity={0} threshold={1} matched={2} {3}/{4}' -f (Format-SemanticNumber -Value $result.similarity), (Format-SemanticNumber -Value $result.threshold), $result.match.source, $result.match.agent, $result.match.id)
            } else {
                Write-Host ('UNIQUE similarity={0} threshold={1} compared={2}' -f (Format-SemanticNumber -Value $result.similarity), (Format-SemanticNumber -Value $result.threshold), $result.compared)
            }
        } elseif ($SemanticList) {
            $scan = Get-SemanticScan -Root $root -Threshold $threshold -Include $SemanticInclude -Exclude $SemanticExclude
            if ($SemanticJson) {
                $view = [pscustomobject]@{
                    threshold  = $scan.threshold
                    item_count = $scan.item_count
                    items      = @($scan.items | ForEach-Object { ConvertTo-SemanticMemberView -Item $_ })
                }
                Write-Output (ConvertTo-AsciiJson -Object $view)
            } else {
                Write-Host ('=== semantic dedup inventory: {0} item(s), threshold={1} ===' -f $scan.item_count, (Format-SemanticNumber -Value $scan.threshold))
                foreach ($item in $scan.items) {
                    Write-Host ('  [{0}] {1} {2} : {3}' -f $item.source, $item.agent, $item.id, $item.canonical)
                }
            }
        } else {
            $scan = Get-SemanticScan -Root $root -Threshold $threshold -Include $SemanticInclude -Exclude $SemanticExclude
            if ($SemanticJson) {
                $view = [pscustomobject]@{
                    threshold   = $scan.threshold
                    item_count  = $scan.item_count
                    group_count = $scan.group_count
                    groups      = @($scan.groups | ForEach-Object { ConvertTo-SemanticGroupView -Group $_ })
                }
                Write-Output (ConvertTo-AsciiJson -Object $view)
            } else {
                Write-Host ('=== semantic dedup scan: {0} duplicate group(s), {1} item(s), threshold={2} ===' -f $scan.group_count, $scan.item_count, (Format-SemanticNumber -Value $scan.threshold))
                if ($scan.group_count -eq 0) { Write-Host '  no duplicates' }
                $number = 0
                foreach ($group in $scan.groups) {
                    $number++
                    Write-Host ('  [{0}] size={1} score={2}' -f $number, $group.size, (Format-SemanticNumber -Value $group.score))
                    foreach ($member in $group.members) {
                        Write-Host ('      [{0}] {1} {2} : {3}' -f $member.source, $member.agent, $member.id, $member.canonical)
                    }
                }
            }
        }
    } catch {
        Write-Error ('semantic-dedup failed: ' + $_.Exception.Message)
        $exitCode = 1
    }
    exit $exitCode
}
