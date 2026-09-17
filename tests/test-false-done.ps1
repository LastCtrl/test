# test-false-done.ps1 - P0-B regression harness for "false DONE" terminal paths.
#
# Goal: a script must report success ONLY when the result is verified on disk
# (Test-Path / valid JSON / real exit code), and must never swallow a failure.
#
# Pure PowerShell 5.1 (no Pester). ASCII-only on purpose (AMSI / codepage safety).
# Isolation:
#   - message-queue.ps1 and run-poller.ps1 honor $env:AGENT_HQ_ROOT -> temp roots;
#   - agent-registry.ps1 / project-queue.ps1 derive the project root from their own
#     location -> driven through a temp mirror tree (.agents\scripts + .memory + ...).
#
# Exit code: 0 when every check passes, 1 when at least one check fails.

$ErrorActionPreference = 'Continue'

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Scripts  = Join-Path $RepoRoot '.agents\scripts'
$TempBase = Join-Path $env:TEMP 'agent-hq-tests-falsedone'

$MqScript  = Join-Path $Scripts 'message-queue.ps1'
$RpScript  = Join-Path $Scripts 'run-poller.ps1'
$RegScript = Join-Path $Scripts 'agent-registry.ps1'
$PqScript  = Join-Path $Scripts 'project-queue.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Results = @()

function Add-Result {
    param([string]$Id, [bool]$Pass, [string]$Note)
    $script:Results += [pscustomobject]@{ Id = $Id; Pass = $Pass; Note = $Note }
    $tag = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} - {2}" -f $tag, $Id, $Note)
}

function New-Root {
    $root = Join-Path $TempBase ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    return $root
}

# Runs a script in a child PS 5.1 process; returns exit code + merged output.
function Invoke-Ps1 {
    param([string]$ScriptPath, [string[]]$ScriptArgs)
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ScriptArgs)
    $text = & powershell @argv 2>&1 | Out-String
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $text }
}

function New-MirrorRoot {
    $root = New-Root
    foreach ($rel in @('.agents\scripts', '.memory', '.opencode\agents', 'projects')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force
    }
    Copy-Item -LiteralPath $RegScript -Destination (Join-Path $root '.agents\scripts\agent-registry.ps1') -Force
    Copy-Item -LiteralPath $PqScript  -Destination (Join-Path $root '.agents\scripts\project-queue.ps1') -Force
    $src = [ordered]@{
        agents = [ordered]@{
            'real-agent' = [ordered]@{
                role           = 'developer'
                specialization = @{ primary = @('dev'); secondary = @() }
            }
        }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $root '.opencode\agents\registry.json'),
        ($src | ConvertTo-Json -Depth 8 -Compress),
        $Utf8NoBom)
    return $root
}

function Remove-RootSafe {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# message-queue.ps1
# ---------------------------------------------------------------------------

# C1: honest send -> exit 0, file exists, content is valid JSON.
$root = New-Root
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.memory\inbox\testagent') -Force
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'send', '-From', 'lead', '-To', 'testagent', '-Type', 'task', '-Priority', 'normal', '-Payload', 'hello')
    $outbox = Join-Path $root '.memory\outbox'
    $files = @(Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $jsonOk = $false
    if ($files.Count -eq 1) {
        try {
            $obj = ConvertFrom-Json ([System.IO.File]::ReadAllText($files[0].FullName, $Utf8NoBom))
            $jsonOk = ($obj.to -eq 'testagent' -and $obj.from -eq 'lead')
        } catch { $jsonOk = $false }
    }
    Add-Result 'mq-send-ok' ($r.Exit -eq 0 -and $files.Count -eq 1 -and $jsonOk) ("exit=$($r.Exit) files=$($files.Count) jsonOk=$jsonOk")
} catch {
    Add-Result 'mq-send-ok' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C2: outbox path blocked by a FILE -> must fail, must NOT create/claim anything.
$root = New-Root
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.memory') -Force
    [System.IO.File]::WriteAllText((Join-Path $root '.memory\outbox'), 'blocked', $Utf8NoBom)
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'send', '-To', 'testagent', '-Type', 'task', '-Payload', 'hello')
    # No .json artefact may exist anywhere under outbox (it is a file, so none can).
    $artefact = Test-Path -LiteralPath (Join-Path $root '.memory\outbox') -PathType Container
    $claimedFail = ($r.Out -match 'FAILED')
    Add-Result 'mq-send-blocked' ($r.Exit -ne 0 -and (-not $artefact) -and $claimedFail) ("exit=$($r.Exit) outboxIsDir=$artefact failedMarker=$claimedFail")
} catch {
    Add-Result 'mq-send-blocked' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C3: send without -To -> must fail (no message object, no file).
$root = New-Root
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.memory\inbox\testagent') -Force
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'send', '-Type', 'task', '-Payload', 'hello')
    $files = @(Get-ChildItem -LiteralPath (Join-Path $root '.memory\outbox') -Filter *.json -File -ErrorAction SilentlyContinue)
    Add-Result 'mq-send-no-recipient' ($r.Exit -ne 0 -and $files.Count -eq 0) ("exit=$($r.Exit) files=$($files.Count)")
} catch {
    Add-Result 'mq-send-no-recipient' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C4: receive with invalid JSON -> must fail (no silent "read ok").
$root = New-Root
try {
    $inbox = Join-Path $root '.memory\inbox\testagent'
    $null = New-Item -ItemType Directory -Path $inbox -Force
    [System.IO.File]::WriteAllText((Join-Path $inbox 'bad.json'), 'this is not json', $Utf8NoBom)
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'receive', '-AgentName', 'testagent')
    Add-Result 'mq-receive-bad-json' ($r.Exit -ne 0 -and ($r.Out -match 'FAILED')) ("exit=$($r.Exit) failedMarker=$($r.Out -match 'FAILED')")
} catch {
    Add-Result 'mq-receive-bad-json' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C5: archive without -Days -> must fail and archive nothing.
$root = New-Root
try {
    $outbox = Join-Path $root '.memory\outbox'
    $null = New-Item -ItemType Directory -Path $outbox -Force
    $sentinel = Join-Path $outbox 'sentinel.json'
    [System.IO.File]::WriteAllText($sentinel, '{"id":"sentinel"}', $Utf8NoBom)
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'archive')
    $doneClaim = ($r.Out -match 'complete')
    $sentinelKept = Test-Path -LiteralPath $sentinel -PathType Leaf
    Add-Result 'mq-archive-no-days' ($r.Exit -ne 0 -and (-not $doneClaim) -and $sentinelKept) ("exit=$($r.Exit) doneClaim=$doneClaim sentinelKept=$sentinelKept")
} catch {
    Add-Result 'mq-archive-no-days' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C6: unknown action -> must fail.
$root = New-Root
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.memory') -Force
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @('-Action', 'bogus-action')
    Add-Result 'mq-unknown-action' ($r.Exit -ne 0) ("exit=$($r.Exit)")
} catch {
    Add-Result 'mq-unknown-action' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C6b: no-action scan with missing inbox -> must fail (nothing was scanned).
$root = New-Root
try {
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $MqScript -ScriptArgs @()
    Add-Result 'mq-scan-missing-inbox' ($r.Exit -ne 0) ("exit=$($r.Exit)")
} catch {
    Add-Result 'mq-scan-missing-inbox' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# ---------------------------------------------------------------------------
# run-poller.ps1
# ---------------------------------------------------------------------------

# C7: missing inbox dir -> must fail (no cheerful completion).
$root = New-Root
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.memory') -Force
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $RpScript -ScriptArgs @()
    Add-Result 'rp-missing-inbox' ($r.Exit -ne 0) ("exit=$($r.Exit)")
} catch {
    Add-Result 'rp-missing-inbox' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# C8: 2 real messages -> honest count, never "0 messages processed".
$root = New-Root
try {
    $inbox = Join-Path $root '.memory\inbox\testagent'
    $null = New-Item -ItemType Directory -Path $inbox -Force
    [System.IO.File]::WriteAllText((Join-Path $inbox 'm1.json'), '{"id":"m1"}', $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $inbox 'm2.json'), '{"id":"m2"}', $Utf8NoBom)
    $env:AGENT_HQ_ROOT = $root
    $r = Invoke-Ps1 -ScriptPath $RpScript -ScriptArgs @('-DryRun')
    $honest = ($r.Out -match 'found 2 message')
    $zeroClaim = ($r.Out -match '0 messages processed')
    Add-Result 'rp-honest-count' ($r.Exit -eq 0 -and $honest -and (-not $zeroClaim)) ("exit=$($r.Exit) honest=$honest zeroClaim=$zeroClaim")
} catch {
    Add-Result 'rp-honest-count' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue
    Remove-RootSafe $root
}

# ---------------------------------------------------------------------------
# agent-registry.ps1 (temp mirror)
# ---------------------------------------------------------------------------

$mirror = New-MirrorRoot
try {
    $regLocal = Join-Path $mirror '.agents\scripts\agent-registry.ps1'
    $regFile  = Join-Path $mirror '.memory\agent-registry.json'

    # C9: -Init -> exit 0 and a valid registry on disk.
    $r = Invoke-Ps1 -ScriptPath $regLocal -ScriptArgs @('-Init')
    $regValid = $false
    if (Test-Path -LiteralPath $regFile) {
        try {
            $reg = ConvertFrom-Json ([System.IO.File]::ReadAllText($regFile, $Utf8NoBom))
            $regValid = ($null -ne $reg.agents)
        } catch { $regValid = $false }
    }
    Add-Result 'reg-init' ($r.Exit -eq 0 -and $regValid) ("exit=$($r.Exit) valid=$regValid")

    # C10: -List on a valid registry -> exit 0.
    $r = Invoke-Ps1 -ScriptPath $regLocal -ScriptArgs @('-List', '-Status', 'free')
    Add-Result 'reg-list-ok' ($r.Exit -eq 0 -and ($r.Out -match 'real-agent')) ("exit=$($r.Exit) lists-agent=$($r.Out -match 'real-agent')")

    # C11: -Acquire with unknown specialization -> exit 2 (documented contract).
    $r = Invoke-Ps1 -ScriptPath $regLocal -ScriptArgs @('-Acquire', '-Specialization', 'nonexistent-xyz', '-Project', 'demo')
    Add-Result 'reg-acquire-none' ($r.Exit -eq 2) ("exit=$($r.Exit)")

    # C12: corrupted registry -> -List MUST fail (no false "empty list" success).
    [System.IO.File]::WriteAllText($regFile, '{ this is not valid json', $Utf8NoBom)
    $r = Invoke-Ps1 -ScriptPath $regLocal -ScriptArgs @('-List')
    Add-Result 'reg-list-corrupt' ($r.Exit -ne 0) ("exit=$($r.Exit)")
} catch {
    Add-Result 'reg-block' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-RootSafe $mirror
}

# ---------------------------------------------------------------------------
# project-queue.ps1 (temp mirror)
# ---------------------------------------------------------------------------

$mirror = New-MirrorRoot
try {
    $regLocal = Join-Path $mirror '.agents\scripts\agent-registry.ps1'
    $pqLocal  = Join-Path $mirror '.agents\scripts\project-queue.ps1'
    $queueFile = Join-Path $mirror 'projects\demo\queue.json'

    $null = New-Item -ItemType Directory -Path (Join-Path $mirror 'projects\demo') -Force
    [System.IO.File]::WriteAllText($queueFile, '{"tasks":[]}', $Utf8NoBom)
    $null = Invoke-Ps1 -ScriptPath $regLocal -ScriptArgs @('-Init')

    # C13: full Add -> Next -> Complete -> List cycle -> all exit 0, list shows done.
    $add = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Add', '-Project', 'demo', '-Title', 'case task', '-Priority', 'critical')
    $taskId = ''
    if ($add.Out -match 'tq-\d{3}') { $taskId = $Matches[0] }
    $next = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Next', '-Project', 'demo')
    $complete = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Complete', '-Project', 'demo', '-Task', $taskId)
    $list = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-List', '-Project', 'demo')
    $cycleOk = ($add.Exit -eq 0 -and $taskId -ne '' -and $next.Exit -eq 0 -and ($next.Out -match [regex]::Escape($taskId)) -and $complete.Exit -eq 0 -and $list.Exit -eq 0 -and ($list.Out -match 'done'))
    Add-Result 'pq-cycle' $cycleOk ("add=$($add.Exit) id=$taskId next=$($next.Exit) complete=$($complete.Exit) list=$($list.Exit)")

    # C14: complete a non-existent task -> must fail.
    $r = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Complete', '-Project', 'demo', '-Task', 'tq-999')
    Add-Result 'pq-complete-missing' ($r.Exit -ne 0) ("exit=$($r.Exit)")

    # C15: assigned agent that does not exist -> release fails -> Complete must NOT exit 0.
    $add2 = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Add', '-Project', 'demo', '-Title', 'release case', '-Priority', 'normal', '-Agent', 'ghost-agent')
    $id2 = ''
    if ($add2.Out -match 'tq-\d{3}') { $id2 = $Matches[0] }
    if ($id2 -eq '') {
        Add-Result 'pq-release-fail' $false ("could not add task: exit=$($add2.Exit) out=$($add2.Out.Trim())")
    } else {
        $r = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-Complete', '-Project', 'demo', '-Task', $id2)
        Add-Result 'pq-release-fail' ($r.Exit -ne 0) ("exit=$($r.Exit) id=$id2")
    }

    # C16: StaleCheck on a task with unparseable started_at -> must NOT report clean success.
    $queueObj = ConvertFrom-Json ([System.IO.File]::ReadAllText($queueFile, $Utf8NoBom))
    $tasks = @($queueObj.tasks)
    $tasks += [pscustomobject]@{
        id = 'tq-900'; title = 'stale case'; priority = 'normal'; status = 'in_progress'
        assigned_agent = $null; created_at = '2026-09-01T00:00:00.000'; started_at = 'not-a-date'
        completed_at = $null; retries = 0
    }
    $queueObj.tasks = $tasks
    [System.IO.File]::WriteAllText($queueFile, ($queueObj | ConvertTo-Json -Depth 10 -Compress), $Utf8NoBom)
    $r = Invoke-Ps1 -ScriptPath $pqLocal -ScriptArgs @('-StaleCheck', '-Project', 'demo')
    Add-Result 'pq-stalecheck-bad-started-at' ($r.Exit -ne 0) ("exit=$($r.Exit)")
} catch {
    Add-Result 'pq-block' $false ("exception: " + $_.Exception.Message)
} finally {
    Remove-RootSafe $mirror
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("SUMMARY: passed={0} failed={1} total={2}" -f ($script:Results.Count - $failed.Count), $failed.Count, $script:Results.Count)

Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
