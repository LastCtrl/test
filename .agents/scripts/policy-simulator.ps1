# policy-simulator.ps1 - simulate a proposed policy/config change WITHOUT applying it.
# Read-only for the real configs: every comparison runs in a temp overlay that is removed.

param(
    [Alias('Propose')]$SimPropose,
    [Alias('Inline')]$SimInline,
    [Alias('Simulate')][switch]$SimRun,
    [Alias('Diff')][switch]$SimDiff,
    [Alias('Json')][switch]$SimJson,
    [Alias('List')][switch]$SimList,
    [Alias('Baseline')][string]$SimBaseline,
    [Alias('Root')][string]$SimRoot,
    [Alias('Commands')][string[]]$SimCommands,
    [Alias('DefaultAction')][string]$SimDefaultAction = 'ask'
)

$script:SimScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:SimScriptRoot)) {
    $script:SimScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:SimValidActions = @('allow', 'ask', 'deny')
$script:SimActionRank = @{ 'allow' = 0; 'ask' = 1; 'deny' = 2 }

$bashLib = Join-Path $script:SimScriptRoot 'bash-policy.ps1'
if (Test-Path -LiteralPath $bashLib -PathType Leaf) {
    . $bashLib
}
$routerLib = Join-Path $script:SimScriptRoot 'model-router.ps1'
if (Test-Path -LiteralPath $routerLib -PathType Leaf) {
    . $routerLib
}

function Get-SimRepoRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($script:SimScriptRoot)) {
        return (Split-Path (Split-Path $script:SimScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Read-SimText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-SimMemberValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Read-SimJsonc {
    param([string]$Text)
    if (Get-Command ConvertFrom-BashPolicyJsonc -ErrorAction SilentlyContinue) {
        return (ConvertFrom-BashPolicyJsonc -Text $Text)
    }
    $clean = $Text
    if ($clean.Length -gt 0 -and $clean[0] -eq [char]0xFEFF) { $clean = $clean.Substring(1) }
    return ($clean | ConvertFrom-Json)
}

function Get-SimActionRank {
    param([string]$Action)
    $key = ([string]$Action).ToLowerInvariant()
    if ($script:SimActionRank.ContainsKey($key)) { return [int]$script:SimActionRank[$key] }
    return -1
}

function Test-SimValidAction {
    param([string]$Action)
    return ($script:SimValidActions -contains ([string]$Action).ToLowerInvariant())
}

function Test-SimGlob {
    param([string]$Pattern, [string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($null -eq $Pattern) { return $false }
    $regex = '^(?i)' + ([regex]::Escape($Pattern).Replace('\*', '.*')) + '$'
    try { return [regex]::IsMatch($Value, $regex) } catch { return $false }
}

function Get-SimRulePairs {
    param($Rules)
    if ($null -eq $Rules) { return @() }
    if (Get-Command Get-BashPolicyRulePairs -ErrorAction SilentlyContinue) {
        return @(Get-BashPolicyRulePairs -BashRuleObject $Rules)
    }
    if ($Rules -is [System.Collections.IDictionary]) {
        return @($Rules.Keys | ForEach-Object { [pscustomobject]@{ Pattern = [string]$_; Action = [string]$Rules[$_] } })
    }
    return @($Rules.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Pattern = [string]$_.Name; Action = [string]$_.Value } })
}

function New-SimRuleList {
    param($Pairs)
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @($Pairs)) {
        if ($null -eq $p) { continue }
        [void]$list.Add([pscustomobject]@{ Pattern = [string]$p.Pattern; Action = [string]$p.Action })
    }
    return ,$list
}

function Test-SimBashActions {
    param($Pairs)
    foreach ($p in @($Pairs)) {
        if (-not (Test-SimValidAction -Action $p.Action)) {
            throw ("rule '" + [string]$p.Pattern + "' has invalid action '" + [string]$p.Action + "' (expected allow/ask/deny)")
        }
    }
}

function Merge-SimBashRules {
    param($BasePairs, $Overrides, $Add, $Remove)

    $list = New-SimRuleList -Pairs $BasePairs

    if ($null -ne $Remove) {
        foreach ($item in @($Remove)) {
            $pattern = [string]$item
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            for ($i = $list.Count - 1; $i -ge 0; $i--) {
                if ($list[$i].Pattern -ceq $pattern) { $list.RemoveAt($i) }
            }
        }
    }

    $groups = @(@{ Object = $Overrides; Append = $false }, @{ Object = $Add; Append = $true })
    foreach ($group in $groups) {
        $source = $group.Object
        if ($null -eq $source) { continue }
        $keys = @()
        if ($source -is [System.Collections.IDictionary]) { $keys = @($source.Keys) }
        else { $keys = @($source.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            $pattern = [string]$key
            if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
            $action = [string](Get-SimMemberValue -Object $source -Name $pattern)
            $found = -1
            for ($i = 0; $i -lt $list.Count; $i++) {
                if ($list[$i].Pattern -ceq $pattern) { $found = $i; break }
            }
            if ($found -ge 0) {
                $list[$found] = [pscustomobject]@{ Pattern = $pattern; Action = $action }
            } else {
                [void]$list.Add([pscustomobject]@{ Pattern = $pattern; Action = $action })
            }
        }
    }

    return $list.ToArray()
}

function Get-SimProposedPairs {
    param($Doc, $BasePairs)

    $full = Get-SimMemberValue -Object $Doc -Name 'rules'
    if ($null -eq $full) { $full = Get-SimMemberValue -Object $Doc -Name 'bash' }
    if ($null -ne $full) {
        return @(Get-SimRulePairs -Rules $full)
    }
    $merged = Merge-SimBashRules -BasePairs $BasePairs `
        -Overrides (Get-SimMemberValue -Object $Doc -Name 'overrides') `
        -Add (Get-SimMemberValue -Object $Doc -Name 'add') `
        -Remove (Get-SimMemberValue -Object $Doc -Name 'remove')
    return @($merged)
}

function Compare-SimBashRules {
    param($BasePairs, $NewPairs)

    $baseMap = @{}
    foreach ($p in @($BasePairs)) { $baseMap[[string]$p.Pattern] = [string]$p.Action }
    $newMap = @{}
    foreach ($p in @($NewPairs)) { $newMap[[string]$p.Pattern] = [string]$p.Action }

    $added = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList

    foreach ($key in @($newMap.Keys)) {
        if (-not $baseMap.ContainsKey($key)) {
            [void]$added.Add([pscustomobject]@{ pattern = $key; action = $newMap[$key] })
        } elseif ($baseMap[$key] -cne $newMap[$key]) {
            [void]$changed.Add([pscustomobject]@{ pattern = $key; from = $baseMap[$key]; to = $newMap[$key] })
        }
    }
    foreach ($key in @($baseMap.Keys)) {
        if (-not $newMap.ContainsKey($key)) {
            [void]$removed.Add([pscustomobject]@{ pattern = $key; action = $baseMap[$key] })
        }
    }

    return [pscustomobject]@{
        added   = @($added.ToArray() | Sort-Object pattern)
        removed = @($removed.ToArray() | Sort-Object pattern)
        changed = @($changed.ToArray() | Sort-Object pattern)
    }
}

function Get-SimEffect {
    param([string]$Old, [string]$New)
    $o = Get-SimActionRank -Action $Old
    $n = Get-SimActionRank -Action $New
    if ($n -eq $o) { return 'unchanged' }
    if ($n -gt $o) { return 'hardened' }
    if (([string]$Old).ToLowerInvariant() -eq 'deny') { return 'regression' }
    return 'weakened'
}

function Resolve-SimBashAction {
    param($Pairs, [string]$Command, [string]$DefaultAction)
    $action = $DefaultAction
    if (-not (Test-SimValidAction -Action $action)) { $action = 'ask' }
    foreach ($p in @($Pairs)) {
        if (Test-SimGlob -Pattern $p.Pattern -Value $Command) { $action = [string]$p.Action }
    }
    return $action
}

function Get-SimDefaultCommands {
    return @(
        'git status',
        'git diff HEAD',
        'git log --oneline -5',
        'git push origin main',
        'git push --force origin main',
        'git clean -fd',
        'rm -rf /',
        'rm -r build',
        'Remove-Item -Recurse -Force temp',
        'Start-Process notepad',
        'schtasks /query',
        'reg add HKLM\Software\X /v Y',
        'Set-ItemProperty HKLM:\Software\X -Name Y -Value Z',
        'secedit /export',
        'gpedit.msc',
        'shutdown /s',
        'format C:',
        'Format-List',
        'Get-ChildItem .',
        'node script.js'
    )
}

function Get-SimBaselineBashRules {
    param([string]$Path)
    if (Get-Command Get-BashPolicyFromFile -ErrorAction SilentlyContinue) {
        $rules = Get-BashPolicyFromFile -Path $Path
        if ($null -ne $rules) { return $rules }
    }
    $doc = Read-SimJsonc -Text (Read-SimText -Path $Path)
    if ($null -eq $doc) { throw "baseline file is not valid JSON: $Path" }
    $perm = Get-SimMemberValue -Object $doc -Name 'permission'
    if ($null -ne $perm) {
        $bash = Get-SimMemberValue -Object $perm -Name 'bash'
        if ($null -ne $bash) { return $bash }
    }
    $rules = Get-SimMemberValue -Object $doc -Name 'rules'
    if ($null -ne $rules) { return $rules }
    throw "baseline has no permission.bash object: $Path"
}

function Invoke-SimBashChange {
    param($Doc, [string]$Root, [string]$Baseline, $Commands, [string]$DefaultAction)

    $basePath = $Baseline
    if ([string]::IsNullOrWhiteSpace($basePath)) { $basePath = Join-Path $Root 'opencode.json' }
    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
        throw "baseline config not found: $basePath"
    }

    $basePairs = @(Get-SimRulePairs -Rules (Get-SimBaselineBashRules -Path $basePath))
    $propPairs = @(Get-SimProposedPairs -Doc $Doc -BasePairs $basePairs)
    Test-SimBashActions -Pairs $propPairs
    Test-SimBashActions -Pairs $basePairs

    $diff = Compare-SimBashRules -BasePairs $basePairs -NewPairs $propPairs

    $commands = @()
    if ($null -ne $Commands -and @($Commands).Count -gt 0) { $commands = @($Commands) }
    elseif ($null -ne (Get-SimMemberValue -Object $Doc -Name 'commands')) { $commands = @(Get-SimMemberValue -Object $Doc -Name 'commands') }
    else { $commands = @(Get-SimDefaultCommands) }

    $rows = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $counts = @{ unchanged = 0; hardened = 0; weakened = 0; regression = 0 }
    $unsafe = $false

    foreach ($command in $commands) {
        $text = [string]$command
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $old = Resolve-SimBashAction -Pairs $basePairs -Command $text -DefaultAction $DefaultAction
        $new = Resolve-SimBashAction -Pairs $propPairs -Command $text -DefaultAction $DefaultAction
        $effect = Get-SimEffect -Old $old -New $new
        if ($counts.ContainsKey($effect)) { $counts[$effect] = [int]$counts[$effect] + 1 }
        $rowUnsafe = ($effect -eq 'regression') -or ($effect -eq 'weakened')
        if ($rowUnsafe) { $unsafe = $true }
        [void]$rows.Add([pscustomobject]@{
            command = $text
            baseline = $old
            proposed = $new
            effect = $effect
            unsafe = $rowUnsafe
        })
        if ($effect -eq 'regression') { [void]$warnings.Add('REGRESSION ' + $text + ': ' + $old + ' -> ' + $new) }
        elseif ($effect -eq 'weakened') { [void]$warnings.Add('WEAKENED ' + $text + ': ' + $old + ' -> ' + $new) }
    }

    foreach ($item in @($diff.removed)) {
        if ([string]$item.action -eq 'deny') {
            $unsafe = $true
            [void]$warnings.Add('DENY REMOVED: ' + [string]$item.pattern)
        }
    }
    foreach ($item in @($diff.changed)) {
        if (([string]$item.from -eq 'deny') -and ([string]$item.to -ne 'deny')) {
            $unsafe = $true
            [void]$warnings.Add('DENY DOWNGRADED: ' + [string]$item.pattern + ' ' + [string]$item.from + ' -> ' + [string]$item.to)
        }
    }

    $sawDeny = $false
    foreach ($p in $propPairs) {
        $action = ([string]$p.Action).ToLowerInvariant()
        if ($action -eq 'deny') { $sawDeny = $true }
        elseif ($sawDeny) {
            $unsafe = $true
            [void]$warnings.Add('ORDER: ' + [string]$p.Pattern + ' action ' + $action + ' appears after a deny rule')
        }
    }

    $diffs = @($rows.ToArray() | Where-Object { $_.effect -ne 'unchanged' })

    return [pscustomobject]@{
        ok              = $true
        kind            = 'bash'
        root            = $Root
        baseline_source = $basePath
        unsafe          = $unsafe
        rules_added     = @($diff.added)
        rules_removed   = @($diff.removed)
        rules_changed   = @($diff.changed)
        commands        = @($rows.ToArray())
        diffs           = @($diffs)
        counts          = [pscustomobject]@{
            unchanged  = [int]$counts['unchanged']
            hardened   = [int]$counts['hardened']
            weakened   = [int]$counts['weakened']
            regression = [int]$counts['regression']
        }
        warnings        = @($warnings.ToArray())
        error           = ''
    }
}

function Set-SimModelInText {
    param([string]$Text, [string]$Model)
    $pattern = '(?m)^(\s*"model"\s*:\s*)"([^"]*)"'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    $target = $Model
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        return $m.Groups[1].Value + '"' + $target + '"'
    }
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
    return $regex.Replace($Text, $evaluator, 1)
}

function Get-SimRouteSummary {
    param($Decision)
    $rejected = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Decision.candidates)) {
        if ([string]$candidate.decision -eq 'rejected') {
            [void]$rejected.Add([string]$candidate.model + ' [' + [string]$candidate.code + ']')
        }
    }
    return [pscustomobject]@{
        model    = [string]$Decision.model
        reason   = [string]$Decision.reason
        changed  = [bool]$Decision.changed
        mode     = [string]$Decision.decision_mode
        passport = [string]$Decision.passport
        rejected = @($rejected.ToArray())
    }
}

function Invoke-SimModelChange {
    param($Doc, [string]$Root, [string]$TaskType, [string]$MaxCostTier, [bool]$Optimize)

    $result = [pscustomobject]@{
        ok             = $false
        kind           = 'model'
        root           = $Root
        agent          = ''
        proposed_model = ''
        route_changed  = $false
        unsafe         = $false
        baseline       = $null
        proposed       = $null
        warnings       = @()
        error          = ''
    }

    if (-not (Get-Command Get-RouteDecision -ErrorAction SilentlyContinue)) {
        $result.error = 'model-router.ps1 is missing - model simulation unavailable'
        return $result
    }

    $agent = [string]$Doc.agent
    $newModel = [string]$Doc.model
    $result.agent = $agent
    $result.proposed_model = $newModel

    if ($agent -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        $result.error = "invalid or missing agent name: '" + $agent + "'"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($newModel)) {
        $result.error = 'missing model in the proposal'
        return $result
    }

    $agentRel = '.opencode\agents\' + $agent + '.json'
    $srcAgent = Join-Path $Root $agentRel
    if (-not (Test-Path -LiteralPath $srcAgent -PathType Leaf)) {
        $result.error = 'agent file not found: ' + $srcAgent
        return $result
    }

    $tempBase = Join-Path $env:TEMP ('agent-hq-policy-sim-' + [guid]::NewGuid().ToString('N'))
    try {
        $baseRoot = Join-Path $tempBase 'baseline'
        $propRoot = Join-Path $tempBase 'proposed'
        foreach ($overlay in @($baseRoot, $propRoot)) {
            New-Item -ItemType Directory -Path (Join-Path $overlay '.opencode\agents') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $overlay '.agents\config') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $overlay '.memory') -Force | Out-Null
        }

        $srcText = Read-SimText -Path $srcAgent
        $propText = Set-SimModelInText -Text $srcText -Model $newModel
        if ($null -eq $propText) {
            $result.error = 'agent file has no top-level model field: ' + $srcAgent
            return $result
        }

        $noBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $baseRoot $agentRel), $srcText, $noBom)
        [System.IO.File]::WriteAllText((Join-Path $propRoot $agentRel), $propText, $noBom)

        $cfgSrc = Join-Path $Root '.agents\config'
        if (Test-Path -LiteralPath $cfgSrc -PathType Container) {
            Copy-Item -Path (Join-Path $cfgSrc '*') -Destination (Join-Path $baseRoot '.agents\config') -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -Path (Join-Path $cfgSrc '*') -Destination (Join-Path $propRoot '.agents\config') -Recurse -Force -ErrorAction SilentlyContinue
        }
        $healthSrc = Join-Path $Root '.memory\model-health.json'
        if (Test-Path -LiteralPath $healthSrc -PathType Leaf) {
            Copy-Item -LiteralPath $healthSrc -Destination (Join-Path $baseRoot '.memory\model-health.json') -Force
            Copy-Item -LiteralPath $healthSrc -Destination (Join-Path $propRoot '.memory\model-health.json') -Force
        }

        $baseDecision = Get-RouteDecision -Agent $agent -Root $baseRoot -TaskType $TaskType -MaxCostTier $MaxCostTier -Optimize:$Optimize
        $propDecision = Get-RouteDecision -Agent $agent -Root $propRoot -TaskType $TaskType -MaxCostTier $MaxCostTier -Optimize:$Optimize

        $baseline = Get-SimRouteSummary -Decision $baseDecision
        $proposed = Get-SimRouteSummary -Decision $propDecision
        $result.baseline = $baseline
        $result.proposed = $proposed
        $result.route_changed = ($baseline.model -ne $proposed.model)

        $warnings = New-Object System.Collections.ArrayList
        if ([string]$propDecision.reason -match 'all-candidates') {
            $unsafe = $true
            [void]$warnings.Add('NO VIABLE MODEL: ' + [string]$propDecision.reason)
        }
        if (-not $result.route_changed) {
            [void]$warnings.Add('ROUTE UNCHANGED: the proposed model does not alter the selected route')
        }
        $result.warnings = @($warnings.ToArray())
        $result.ok = $true
        return $result
    }
    finally {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-SimTaskAction {
    param($TaskRule, [string]$Target, [string]$DefaultAction = 'deny')

    if ($null -eq $TaskRule) { return $DefaultAction }
    if ($TaskRule -is [string]) {
        $text = ([string]$TaskRule).Trim()
        if ($text.Length -eq 0) { return $DefaultAction }
        return $text
    }
    $exact = Get-SimMemberValue -Object $TaskRule -Name $Target
    if ($null -ne $exact) { return [string]$exact }
    $star = Get-SimMemberValue -Object $TaskRule -Name '*'
    if ($null -ne $star) { return [string]$star }
    return $DefaultAction
}

function Invoke-SimPermissionChange {
    param($Doc, [string]$Root)

    $result = [pscustomobject]@{
        ok        = $false
        kind      = 'permission'
        root      = $Root
        agent     = ''
        unsafe    = $false
        rows      = @()
        diffs     = @()
        counts    = $null
        warnings  = @()
        error     = ''
    }

    $agent = [string]$Doc.agent
    $result.agent = $agent
    if ($agent -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        $result.error = "invalid or missing agent name: '" + $agent + "'"
        return $result
    }

    $taskDoc = Get-SimMemberValue -Object $Doc -Name 'task'
    if ($null -eq $taskDoc) {
        $perm = Get-SimMemberValue -Object $Doc -Name 'permission'
        if ($null -ne $perm) { $taskDoc = Get-SimMemberValue -Object $perm -Name 'task' }
    }
    if ($null -eq $taskDoc) {
        $result.error = 'missing task mapping in the proposal'
        return $result
    }

    $cfgPath = Join-Path $Root 'opencode.json'
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
        $result.error = 'config not found: ' + $cfgPath
        return $result
    }

    $cfg = Read-SimJsonc -Text (Read-SimText -Path $cfgPath)
    $baseTask = $null
    $agentNames = @()
    if (($null -ne $cfg) -and ($null -ne $cfg.agent)) {
        $agentNames = @($cfg.agent.PSObject.Properties.Name)
        $agentProp = $cfg.agent.PSObject.Properties[$agent]
        if (($null -ne $agentProp) -and ($null -ne $agentProp.Value) -and ($null -ne $agentProp.Value.permission)) {
            $baseTask = $agentProp.Value.permission.task
        }
    }

    $targets = @()
    $declared = Get-SimMemberValue -Object $Doc -Name 'targets'
    if ($null -ne $declared) {
        foreach ($item in @($declared)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $targets += [string]$item }
        }
    }
    if ($targets.Count -eq 0) { $targets = @($agentNames | Sort-Object) }
    if ($targets.Count -eq 0) { $targets = @('*') }

    $rows = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $counts = @{ unchanged = 0; hardened = 0; weakened = 0; regression = 0 }
    $unsafe = $false

    foreach ($target in $targets) {
        $old = Resolve-SimTaskAction -TaskRule $baseTask -Target $target
        $new = Resolve-SimTaskAction -TaskRule $taskDoc -Target $target
        $effect = Get-SimEffect -Old $old -New $new
        if ($counts.ContainsKey($effect)) { $counts[$effect] = [int]$counts[$effect] + 1 }
        $forkBomb = (([string]$new).ToLowerInvariant() -eq 'allow') -and (($target -ceq $agent) -or ($target -match '(?i)^team-lead'))
        if ($forkBomb) { $unsafe = $true }
        if (($effect -eq 'regression') -or ($effect -eq 'weakened')) { $unsafe = $true }
        [void]$rows.Add([pscustomobject]@{
            target   = $target
            baseline = $old
            proposed = $new
            effect   = $effect
            unsafe   = (($effect -eq 'regression') -or ($effect -eq 'weakened') -or $forkBomb)
        })
        if ($effect -eq 'regression') { [void]$warnings.Add('REGRESSION ' + $target + ': ' + $old + ' -> ' + $new) }
        elseif ($effect -eq 'weakened') { [void]$warnings.Add('WEAKENED ' + $target + ': ' + $old + ' -> ' + $new) }
        if ($forkBomb) { [void]$warnings.Add('FORK-BOMB RISK: ' + $agent + ' may delegate to ' + $target) }
    }

    $diffs = @($rows.ToArray() | Where-Object { $_.effect -ne 'unchanged' })

    $result.rows = @($rows.ToArray())
    $result.diffs = @($diffs)
    $result.counts = [pscustomobject]@{
        unchanged  = [int]$counts['unchanged']
        hardened   = [int]$counts['hardened']
        weakened   = [int]$counts['weakened']
        regression = [int]$counts['regression']
    }
    $result.warnings = @($warnings.ToArray())
    $result.unsafe = $unsafe
    $result.ok = $true
    return $result
}

function Get-SimProposalKind {
    param($Doc)
    if ($null -eq $Doc) { return 'unknown' }
    $kind = [string](Get-SimMemberValue -Object $Doc -Name 'kind')
    if (-not [string]::IsNullOrWhiteSpace($kind)) {
        switch ($kind.ToLowerInvariant()) {
            'bash' { return 'bash' }
            'model' { return 'model' }
            'permission' { return 'permission' }
            'task' { return 'permission' }
            default { return 'unknown' }
        }
    }
    if (($null -ne (Get-SimMemberValue -Object $Doc -Name 'rules')) -or
        ($null -ne (Get-SimMemberValue -Object $Doc -Name 'bash')) -or
        ($null -ne (Get-SimMemberValue -Object $Doc -Name 'overrides'))) { return 'bash' }
    if ($null -ne (Get-SimMemberValue -Object $Doc -Name 'model')) { return 'model' }
    if ($null -ne (Get-SimMemberValue -Object $Doc -Name 'task')) { return 'permission' }
    return 'unknown'
}

function Invoke-PolicySimulation {
    param(
        [string]$Propose,
        [string]$Inline,
        [string]$Root,
        [string]$Baseline,
        [string[]]$Commands,
        [string]$DefaultAction,
        [string]$TaskType = '',
        [string]$MaxCostTier = 'any',
        [bool]$Optimize = $false
    )

    $repoRoot = Get-SimRepoRoot -Root $Root
    $doc = $null

    if (-not [string]::IsNullOrWhiteSpace($Inline)) {
        $text = [string]$Inline
        try { $doc = Read-SimJsonc -Text $text } catch { throw ('proposal JSON is invalid: ' + $_.Exception.Message) }
    } else {
        $path = [string]$Propose
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('proposal file not found: ' + $path) }
        $text = Read-SimText -Path $path
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('proposal file is empty: ' + $path) }
        try { $doc = Read-SimJsonc -Text $text } catch { throw ('proposal JSON is invalid: ' + $_.Exception.Message) }
    }

    if ($null -eq $doc) { throw 'proposal is not a JSON object' }

    $kind = Get-SimProposalKind -Doc $doc
    switch ($kind) {
        'bash' { return Invoke-SimBashChange -Doc $doc -Root $repoRoot -Baseline $Baseline -Commands $Commands -DefaultAction $DefaultAction }
        'model' {
            $taskType = [string](Get-SimMemberValue -Object $doc -Name 'task_type')
            if ([string]::IsNullOrWhiteSpace($taskType) -and -not [string]::IsNullOrWhiteSpace($TaskType)) { $taskType = $TaskType }
            $maxCost = [string](Get-SimMemberValue -Object $doc -Name 'max_cost_tier')
            if ([string]::IsNullOrWhiteSpace($maxCost)) { $maxCost = $MaxCostTier }
            $opt = $Optimize
            if ($null -ne (Get-SimMemberValue -Object $doc -Name 'optimize')) { $opt = [bool](Get-SimMemberValue -Object $doc -Name 'optimize') }
            return Invoke-SimModelChange -Doc $doc -Root $repoRoot -TaskType $taskType -MaxCostTier $maxCost -Optimize $opt
        }
        'permission' { return Invoke-SimPermissionChange -Doc $doc -Root $repoRoot }
        default {
            $shown = [string](Get-SimMemberValue -Object $doc -Name 'kind')
            throw ("unsupported proposal kind: '" + $shown + "' (use -List to see the supported kinds)")
        }
    }
}

function Show-SimSupportedKinds {
    Write-Host ''
    Write-Host 'policy-simulator.ps1 - supported proposal kinds' -ForegroundColor Cyan
    Write-Host '  bash       proposed bash rules: "rules" (full), or "overrides"/"add"/"remove" (patch)'
    Write-Host '  model      proposed agent model: "agent" + "model" [+ "task_type" / "max_cost_tier" / "optimize"]'
    Write-Host '  permission proposed callee map: "agent" + "task" (object or allow/ask/deny) [+ "targets"]'
    Write-Host ''
    Write-Host 'Common CLI: -Propose <file> | -Inline <json> | -Baseline <config> | -Root <repo>'
    Write-Host '            -Simulate -Diff -Json -List -Commands a,b -DefaultAction ask'
    Write-Host 'Exit: 0 ok (a regression is reported, not fatal), 2 usage, 1 bad input.'
    Write-Host ''
}

function Show-SimUsage {
    Write-Host 'Usage: policy-simulator.ps1 (-Propose <file> | -Inline <json>) [-Simulate] [-Diff] [-Json]' -ForegroundColor Yellow
    Write-Host '       policy-simulator.ps1 -List'
}

function Write-SimBashHuman {
    param($Result, [bool]$Diff)
    Write-Host ('kind    : bash')
    Write-Host ('root    : ' + $Result.root)
    Write-Host ('baseline: ' + $Result.baseline_source)
    Write-Host ('unsafe  : ' + $Result.unsafe) -ForegroundColor $(if ($Result.unsafe) { 'Red' } else { 'Gray' })

    Write-Host '-- rules diff --'
    if (@($Result.rules_added).Count -eq 0) { Write-Host '  added   : none' }
    else { foreach ($i in @($Result.rules_added)) { Write-Host ('  added   : ' + $i.pattern + ' = ' + $i.action) } }
    if (@($Result.rules_removed).Count -eq 0) { Write-Host '  removed : none' }
    else { foreach ($i in @($Result.rules_removed)) { Write-Host ('  removed : ' + $i.pattern + ' (was ' + $i.action + ')') } }
    if (@($Result.rules_changed).Count -eq 0) { Write-Host '  changed : none' }
    else { foreach ($i in @($Result.rules_changed)) { Write-Host ('  changed : ' + $i.pattern + ' : ' + $i.from + ' -> ' + $i.to) } }

    $shown = @($Result.commands)
    if ($Diff) { $shown = @($Result.diffs) }
    Write-Host ('-- command effects (shown ' + $shown.Count + ' of ' + @($Result.commands).Count + ') --')
    if ($shown.Count -eq 0) { Write-Host '  (no changes)' }
    foreach ($row in $shown) {
        $color = 'Gray'
        if ($row.effect -eq 'regression') { $color = 'Red' }
        elseif ($row.effect -eq 'weakened') { $color = 'Yellow' }
        elseif ($row.effect -eq 'hardened') { $color = 'Green' }
        Write-Host (('  {0,-42} {1,-6} -> {2,-6} {3}' -f $row.command, $row.baseline, $row.proposed, $row.effect)) -ForegroundColor $color
    }

    Write-Host ('counts  : unchanged=' + $Result.counts.unchanged + ' hardened=' + $Result.counts.hardened + ' weakened=' + $Result.counts.weakened + ' regression=' + $Result.counts.regression)
    if (@($Result.warnings).Count -gt 0) {
        Write-Host '-- warnings --' -ForegroundColor Red
        foreach ($w in @($Result.warnings)) { Write-Host ('  ' + $w) -ForegroundColor Red }
    }
}

function Write-SimModelHuman {
    param($Result)
    Write-Host ('kind    : model')
    Write-Host ('root    : ' + $Result.root)
    Write-Host ('agent   : ' + $Result.agent)
    if (-not $Result.ok) { Write-Host ('error   : ' + $Result.error) -ForegroundColor Red; return }
    Write-Host ('baseline: ' + $Result.baseline.model + '  (' + $Result.baseline.reason + ', mode=' + $Result.baseline.mode + ', passport=' + $Result.baseline.passport + ')')
    Write-Host ('proposed: ' + $Result.proposed.model + '  (' + $Result.proposed.reason + ', mode=' + $Result.proposed.mode + ', passport=' + $Result.proposed.passport + ')')
    Write-Host ('route_changed : ' + $Result.route_changed)
    Write-Host ('rejected (baseline): ' + (($Result.baseline.rejected) -join ', '))
    Write-Host ('rejected (proposed): ' + (($Result.proposed.rejected) -join ', '))
    if (@($Result.warnings).Count -gt 0) {
        Write-Host '-- warnings --' -ForegroundColor Yellow
        foreach ($w in @($Result.warnings)) { Write-Host ('  ' + $w) -ForegroundColor Yellow }
    }
}

function Write-SimPermissionHuman {
    param($Result, [bool]$Diff)
    Write-Host ('kind    : permission')
    Write-Host ('root    : ' + $Result.root)
    Write-Host ('agent   : ' + $Result.agent)
    if (-not $Result.ok) { Write-Host ('error   : ' + $Result.error) -ForegroundColor Red; return }
    Write-Host ('unsafe  : ' + $Result.unsafe) -ForegroundColor $(if ($Result.unsafe) { 'Red' } else { 'Gray' })

    $shown = @($Result.rows)
    if ($Diff) { $shown = @($Result.diffs) }
    Write-Host ('-- callee effects (shown ' + $shown.Count + ' of ' + @($Result.rows).Count + ') --')
    if ($shown.Count -eq 0) { Write-Host '  (no changes)' }
    foreach ($row in $shown) {
        $color = 'Gray'
        if ($row.effect -eq 'regression') { $color = 'Red' }
        elseif ($row.effect -eq 'weakened') { $color = 'Yellow' }
        elseif ($row.effect -eq 'hardened') { $color = 'Green' }
        Write-Host (('  {0,-24} {1,-6} -> {2,-6} {3}' -f $row.target, $row.baseline, $row.proposed, $row.effect)) -ForegroundColor $color
    }
    Write-Host ('counts  : unchanged=' + $Result.counts.unchanged + ' hardened=' + $Result.counts.hardened + ' weakened=' + $Result.counts.weakened + ' regression=' + $Result.counts.regression)
    if (@($Result.warnings).Count -gt 0) {
        Write-Host '-- warnings --' -ForegroundColor Red
        foreach ($w in @($Result.warnings)) { Write-Host ('  ' + $w) -ForegroundColor Red }
    }
}

function Write-SimResult {
    param($Result, [bool]$Json, [bool]$Diff)
    if ($Json) {
        Write-Output (ConvertTo-Json -InputObject $Result -Depth 12)
        return
    }
    Write-Host ''
    Write-Host '=== policy simulator (read-only) ===' -ForegroundColor Cyan
    if (-not $Result.ok) {
        Write-Host ('kind    : ' + $Result.kind)
        Write-Host ('error   : ' + $Result.error) -ForegroundColor Red
        return
    }
    switch ($Result.kind) {
        'bash' { Write-SimBashHuman -Result $Result -Diff $Diff }
        'model' { Write-SimModelHuman -Result $Result }
        'permission' { Write-SimPermissionHuman -Result $Result -Diff $Diff }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    $jsonMode = [bool]$SimJson
    try {
        if ($SimList) {
            Show-SimSupportedKinds
            exit 0
        }

        $proposeBound = ($null -ne $SimPropose)
        $inlineBound = ($null -ne $SimInline)
        $hasPropose = -not [string]::IsNullOrWhiteSpace([string]$SimPropose)
        $hasInline = -not [string]::IsNullOrWhiteSpace([string]$SimInline)

        if ($proposeBound -and -not $hasPropose) { throw 'empty -Propose value' }
        if ($inlineBound -and -not $hasInline) { throw 'empty -Inline value' }

        if (-not $hasPropose -and -not $hasInline) {
            Show-SimUsage
            exit 2
        }
        if ($hasPropose -and $hasInline) {
            throw 'pass either -Propose or -Inline, not both'
        }

        $result = Invoke-PolicySimulation -Propose $SimPropose -Inline $SimInline `
            -Root $SimRoot -Baseline $SimBaseline -Commands $SimCommands `
            -DefaultAction $SimDefaultAction
        Write-SimResult -Result $result -Json $jsonMode -Diff:([bool]$SimDiff)

        if ($result.unsafe -and -not $jsonMode) {
            Write-Host ''
            Write-Host 'VERDICT: UNSAFE - the proposal weakens at least one restriction.' -ForegroundColor Red
        } elseif (-not $jsonMode) {
            Write-Host ''
            Write-Host 'VERDICT: no weakening detected in the simulated set.' -ForegroundColor Green
        }
        $exitCode = 0
    }
    catch {
        if ($jsonMode) {
            $err = [pscustomobject]@{ ok = $false; kind = 'error'; error = $_.Exception.Message }
            Write-Output (ConvertTo-Json -InputObject $err -Depth 6)
        } else {
            Write-Host ('policy-simulator failed: ' + $_.Exception.Message) -ForegroundColor Red
        }
        $exitCode = 1
    }
    exit $exitCode
}
