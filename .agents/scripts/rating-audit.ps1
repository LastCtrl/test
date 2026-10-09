<#
.SYNOPSIS
  rating-audit.ps1 - honest re-grading of agent ratings per AGENTS.md 7.1 (anti-inflation).

.DESCRIPTION
  Reads .memory/ratings.jsonl and correlates each record with FACTUAL signals
  (not self-grades) inside a +/- window of days:
    - CONTEXT-BUFFER.md : reviewer verdicts REJECT/APPROVE, rework/iteration markers
    - KNOWLEDGE-BASE.md : BUG-* major/minor/critical defects attributed to the agent
    - .memory/failure-memory.jsonl : failure signatures per agent
    - .memory/dead-letter/*.json   : tasks that failed after retries
  Then computes grade_honest. Read-only except the output file. Deterministic,
  idempotent (same input -> byte-identical output).

.RUBRIC (AGENTS.md 7.1)
  base 9;  -2 per major;  -0.5 per minor;  -1 per extra fix iteration;
  -3..-5 for a false DONE / unresolved REJECT;  clamp 1..10.
  No factual signal in the window  =>  grade_honest = null (never invented).

.NOTES
  Script source is kept PURE ASCII on purpose: PowerShell 5.1 reads BOM-less
  .ps1 as cp1251, and Cyrillic literals would break parsing (see BUG-003).
  Cyrillic regex tokens are therefore written as .NET \uXXXX escapes.
  Output file is UTF-8 BOM + CRLF + ASCII-escaped JSON lines.
#>
[CmdletBinding()]
param(
  [int]$WindowDays = 3,
  [string]$Root,
  [string]$RatingsPath,
  [string]$ContextPath,
  [string]$KbPath,
  [string]$FailurePath,
  [string]$DeadLetterDir,
  [string]$OutputPath,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths
if (-not $Root) {
  $here = $PSScriptRoot
  if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $Root = (Resolve-Path (Join-Path $here '..\..')).Path
}
if (-not $RatingsPath)   { $RatingsPath   = Join-Path $Root '.memory\ratings.jsonl' }
if (-not $ContextPath)   { $ContextPath   = Join-Path $Root 'CONTEXT-BUFFER.md' }
if (-not $KbPath)        { $KbPath        = Join-Path $Root 'KNOWLEDGE-BASE.md' }
if (-not $FailurePath)   { $FailurePath   = Join-Path $Root '.memory\failure-memory.jsonl' }
if (-not $DeadLetterDir) { $DeadLetterDir = Join-Path $Root '.memory\dead-letter' }
if (-not $OutputPath)    { $OutputPath    = Join-Path $Root '.memory\ratings-audited.jsonl' }

# ------------------------------------------------------- Cyrillic regex tokens
# .NET regex interprets \uXXXX even when the source string is ASCII.
$P_ATTEMPT = '\u043F\u043E\u043F\u044B\u0442\u043A\u0430'              # popytka
$P_FIX     = '\u0444\u0438\u043A\u0441'                               # fiks
$P_REWORK  = '\u0434\u043E\u0440\u0430\u0431\u043E\u0442\u043A\u0430'  # dorabotka
$P_REREV   = '\u0440\u0435-\u0440\u0435\u0432\u044C\u044E'            # re-revyu
$P_ACCEPT  = '\u043F\u0440\u0438\u043D\u044F\u0442\u043E'              # prinyato
$P_FALSE   = '\u043B\u043E\u0436\u043D'                               # lozhn-
# negation immediately after a false-DONE claim: "... net" / "... ne ..." /
# "... otsutstvuet" -- an honest report of the ABSENCE of a false DONE.
$P_FDNEG   = '(?:\u043D\u0435\u0442|\u043D\u0435\b|\u043E\u0442\u0441\u0443\u0442\u0441\u0442\u0432)'
$P_NOZMIN  = '\u0431\u0435\u0437\s*\u0438\u0437\u043C\u0435\u043D\u0435\u043D'    # "bez izmenen"
$P_NESOOT  = '\u043D\u0435\s+\u0441\u043E\u043E\u0442\u0432\u0435\u0442\u0441\u0442\u0432\u0443' # "ne sootvetstvu"
$P_OTCHET  = '\u043E\u0442\u0447[\u0435\u0451]\u0442'                 # "otchyot"/"otchet"
$P_AGENT   = '\u0430\u0433\u0435\u043D\u0442'                          # "agent"
$P_AGENTA  = '\u0430\u0433\u0435\u043D\u0442\u0430'                    # "agenta"

$RX_ATTEMPT   = "(?:$P_ATTEMPT|\battempt)\s*\u2116?\s*(\d+)(?![0-9/])"
$RX_REWORK    = "($P_FIX|$P_REWORK|$P_REREV|\bretry\b)"
$RX_REJECT    = '\bREJECT\b'
$RX_APPROVE   = '\bAPPROVE\b|\bPASSED\b|\bPASS\b|' + $P_ACCEPT
# false-DONE trigger: ONLY an explicit, non-negated claim about a specific agent.
# The old "ne vypolnen" branch was removed on purpose: it matched QA/infra notes
# ("kriteriy ... NE vypolnen", "priyomka NE vypolnena: spawn ...") which are NOT
# false DONEs. The detector identifier "falseDone" is excluded by requiring a
# separator ("false[-\s]+DONE").
$RX_FALSEDONE = "(?:$P_FALSE\w*\s*DONE(?!\s*$P_FDNEG)|false[-\s]+DONE(?!\s*$P_FDNEG)|DONE\s+$P_NOZMIN\w*|$P_OTCHET\s+$P_NESOOT\w*)"
# subject of a false-DONE claim (used to attribute it to ONE agent, not to every
# agent merely mentioned on the same line):
#   A) "<agent>=N (false-DONE ...)"   B) "[agent] <agent>: false-DONE"
$RX_FD_SUBJ_A = "(?<a>[\w\u002D]+)\s*=\s*\d+\s*\(\s*" + $RX_FALSEDONE
$RX_FD_SUBJ_B = "(?:(?:$P_AGENT|$P_AGENTA)\s+)?(?<a>[\w\u002D]+)\s*[:\u2013\u2014-]\s*" + $RX_FALSEDONE

# ---------------------------------------------------------------- helpers
function Read-Utf8Text([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
}

function Normalize-Agent([string]$a) {
  if ([string]::IsNullOrWhiteSpace($a)) { return '' }
  return ($a -replace '\s*\(.*$', '').Trim()
}

function Get-NameRx([string]$name) {
  return '(?<![\w\u002D])' + [regex]::Escape($name) + '(?![\w\u002D])'
}

function Get-FalseDoneSubjects([string]$line) {
  # Returns the agent names that are the SUBJECT of a false-DONE claim in $line.
  # Empty when the line only reports the absence of one, or mentions a false DONE
  # in an infra/criterion context (those are filtered out by RX_FALSEDONE).
  $subs = New-Object System.Collections.ArrayList
  foreach ($rx in @($RX_FD_SUBJ_A, $RX_FD_SUBJ_B)) {
    foreach ($m in [regex]::Matches($line, $rx, 'IgnoreCase')) { [void]$subs.Add($m.Groups['a'].Value) }
  }
  return @($subs)
}

function Get-DateOnly([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $m = [regex]::Match($s, '\d{4}-\d{2}-\d{2}')
  if (-not $m.Success) { return $null }
  $d = [datetime]::MinValue
  if ([datetime]::TryParseExact($m.Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

function Test-Window([datetime]$d, [datetime]$center, [int]$days) {
  return ([Math]::Abs(($d - $center).TotalDays) -le $days)
}

function Convert-ToAscii([string]$s) {
  if ($null -eq $s) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -lt 128) { [void]$sb.Append($ch) }
    else { [void]$sb.Append(('\u{0:x4}' -f $code)) }
  }
  return $sb.ToString()
}

function Round2([double]$v) { return [Math]::Round($v, 2) }

# ---------------------------------------------------------------- load ratings
$raw = Read-Utf8Text $RatingsPath
if ($null -eq $raw) { throw "missing ratings file: $RatingsPath" }
$ratingRecords = New-Object System.Collections.ArrayList
foreach ($line in ($raw -split "`r?`n")) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try { $o = $line | ConvertFrom-Json } catch { continue }
  [void]$ratingRecords.Add($o)
}

# ------------------------------------------------- parse CONTEXT-BUFFER blocks
$blocks = New-Object System.Collections.ArrayList
$ctx = Read-Utf8Text $ContextPath
if ($ctx) {
  $rx = [regex]'(?m)\[(\d{4}-\d{2}-\d{2})(?:[ T][^\]]*)?\]\s*(\S+)\s*(?:->|\u2192)\s*'
  $ms = $rx.Matches($ctx)
  for ($i = 0; $i -lt $ms.Count; $i++) {
    $start = $ms[$i].Index + $ms[$i].Length
    $end = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $ctx.Length }
    [void]$blocks.Add([pscustomobject]@{
      Date   = (Get-DateOnly $ms[$i].Groups[1].Value)
      Author = (Normalize-Agent $ms[$i].Groups[2].Value)
      Text   = $ctx.Substring($start, $end - $start)
    })
  }
}

# ------------------------------------------------- parse KNOWLEDGE-BASE bugs
$bugs = New-Object System.Collections.ArrayList
$kb = Read-Utf8Text $KbPath
if ($kb) {
  $secs = [regex]::Split($kb, '(?m)^### ')
  foreach ($sec in $secs) {
    if ($sec -notmatch '^BUG-') { continue }
    $id = ($sec -split ':')[0].Trim()
    $sev = 'minor'
    if ($sec -match '(?m)\*\*Severity\*\*:\s*([A-Za-z]+)') { $sev = $Matches[1].ToLowerInvariant() }
    elseif ($sec -match '(?i)\((critical|major|minor)') { $sev = $Matches[1].ToLowerInvariant() }
    $date = $null
    if ($sec -match '(?m)\*\*Date\*\*:\s*(\d{4}-\d{2}-\d{2})') { $date = Get-DateOnly $Matches[1] }
    else { $date = Get-DateOnly $sec }
    # searchable body: drop the discoverer block and the discoverer role (finds != causes)
    $search = [regex]::Replace($sec, '(?is)\*{0,2}\s*Discovered by\*{0,2}\s*:.*$', ' ')
    $search = [regex]::Replace($search, 'qa-engineer(?:-\d+)?', ' ')
    [void]$bugs.Add([pscustomobject]@{ Id = $id; Severity = $sev; Date = $date; Text = $search })
  }
}

# ------------------------------------------------- parse failure-memory
$fm = New-Object System.Collections.ArrayList
$fmRaw = Read-Utf8Text $FailurePath
if ($fmRaw) {
  foreach ($line in ($fmRaw -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    [void]$fm.Add($o)
  }
}

# ------------------------------------------------- parse dead-letter
$dl = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $DeadLetterDir) {
  foreach ($f in (Get-ChildItem -LiteralPath $DeadLetterDir -Filter '*.json' -File)) {
    try { $o = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    [void]$dl.Add([pscustomobject]@{
      To   = (Normalize-Agent $o.to)
      Date = (Get-DateOnly ([string]$o.finishedAt))
    })
  }
}

# ---------------------------------------------------------------- audit loop
$audited = New-Object System.Collections.ArrayList
$stat = [ordered]@{ total = 0; matched = 0; no_signal = 0 }
$sumOldAll = 0.0; $sumOldMatched = 0.0; $sumHon = 0.0; $matchedN = 0

foreach ($r in $ratingRecords) {
  $stat.total++
  $agent = Normalize-Agent ([string]$r.agent)
  $center = Get-DateOnly ([string]$r.date)
  $old = [double]$r.grade
  $sumOldAll += $old

  $rec = [pscustomobject][ordered]@{
    model = [string]$r.model; agent = [string]$r.agent; task_type = [string]$r.task_type
    date = [string]$r.date; grade_old = $old; grade_honest = $null
    iterations = 0; defects_major = 0; defects_minor = 0; reason = ''
  }
  if (-not $agent -or -not $center) { [void]$audited.Add($rec); $stat.no_signal++; continue }

  $nameRx = Get-NameRx $agent
  $refBlocks = @()
  foreach ($b in $blocks) { if ($b.Date -and (Test-Window $b.Date $center $WindowDays) -and $b.Text -match $nameRx) { $refBlocks += $b } }

  # -- CONTEXT-BUFFER verdicts from reviewers (author != agent), LINE-scoped to
  #    avoid cross-attributing one summary block to every agent it mentions.
  $cbReject = 0; $cbApprove = 0; $falseDone = $false; $hasRework = $false; $maxAttempt = 0
  foreach ($b in $refBlocks) {
    $authoredByAgent = ($b.Author -eq $agent)
    foreach ($ln in ($b.Text -split "`r?`n")) {
      if ($ln -notmatch $nameRx) { continue }
      if (-not $authoredByAgent) {
        $cbReject  += ([regex]::Matches($ln, $RX_REJECT)).Count
        $cbApprove += ([regex]::Matches($ln, $RX_APPROVE, 'IgnoreCase')).Count
      }
      # false-DONE is attributed ONLY to the named subject of the claim
      # (e.g. "dev-1=6 (lozhnyy DONE...)" flags dev-1, never the other agents
      #  merely mentioned on the same line). Negated/infra mentions are already
      #  excluded by RX_FALSEDONE.
      foreach ($fdSub in (Get-FalseDoneSubjects $ln)) {
        if ((Normalize-Agent $fdSub) -ieq $agent) { $falseDone = $true; break }
      }
    }
    if ($authoredByAgent) {
      foreach ($m in [regex]::Matches($b.Text, $RX_ATTEMPT, 'IgnoreCase')) { $n = [int]$m.Groups[1].Value; if ($n -gt $maxAttempt) { $maxAttempt = $n } }
      if ($b.Text -match $RX_REWORK) { $hasRework = $true }
    }
  }

  # -- KNOWLEDGE-BASE defects attributed to this agent
  $kbMajor = 0; $kbMinor = 0
  foreach ($bug in $bugs) {
    if (-not $bug.Date) { continue }
    if (-not (Test-Window $bug.Date $center $WindowDays)) { continue }
    if ($bug.Text -notmatch $nameRx) { continue }
    if ($bug.Severity -eq 'critical' -or $bug.Severity -eq 'major') { $kbMajor++ } else { $kbMinor++ }
  }

  # -- failure-memory
  #    NOTE: failure-memory.jsonl `agent` is the DISCOVERER for kb-* signatures and
  #    the REVIEWER (author) for reviewer-reject signatures -- NOT the producer of
  #    the defect. Penalising by it would blame QA for finding bugs. So kb-* is
  #    skipped (KNOWLEDGE-BASE source already covers it, discoverer-stripped) and
  #    reviewer-reject is skipped (a reviewer issuing a reject is doing their job).
  #    Only genuine producer failures are counted here.
  $fmMajor = 0; $fmMinor = 0; $fmUnresolved = 0
  foreach ($e in $fm) {
    if ((Normalize-Agent ([string]$e.agent)) -ne $agent) { continue }
    $rc = ([string]$e.reason_code).ToLowerInvariant()
    if ($rc -like 'kb-*' -or $rc -eq 'reviewer-reject') { continue }
    $f = Get-DateOnly ([string]$e.first_seen); $l = Get-DateOnly ([string]$e.last_seen)
    if (-not $f -and -not $l) { continue }
    if (-not $f) { $f = $l }; if (-not $l) { $l = $f }
    if (-not ($f -le $center.AddDays($WindowDays) -and $l -ge $center.AddDays(-$WindowDays))) { continue }
    if ($rc -match 'major|critical') { $fmMajor++ } else { $fmMinor++ }
    if (-not [bool]$e.fixed) { $fmUnresolved += [int]$e.count }
  }

  # -- dead-letter
  $dlFail = 0
  foreach ($d in $dl) { if ($d.To -eq $agent -and $d.Date -and (Test-Window $d.Date $center $WindowDays)) { $dlFail++ } }

  $hasSignal = ($refBlocks.Count -gt 0) -or ($kbMajor + $kbMinor -gt 0) -or ($fmMajor + $fmMinor -gt 0) -or ($fmUnresolved -gt 0) -or ($dlFail -gt 0)
  if (-not $hasSignal) { [void]$audited.Add($rec); $stat.no_signal++; continue }

  # -- iterations: explicit "popytka N" number takes precedence, otherwise one
  #    extra round if any rework marker is present; a dead-letter means the task
  #    needed a retry (>=2 attempts), but it is often infra-caused (e.g. "agent
  #    not found" fallback), so it only forces 2 attempts, not a heavy defect.
  $iterations = $maxAttempt
  if ($iterations -lt 1) { $iterations = $(if ($hasRework) { 2 } else { 1 }) }
  if ($dlFail -gt 0 -and $iterations -lt 2) { $iterations = 2 }
  $extra = [Math]::Max(0, $iterations - 1)
  if ($extra -gt 2) { $extra = 2 }

  # -- resolved / unresolved rejects
  $resolvedRejects = 0; $unresolved = 0
  if ($cbApprove -gt 0) { $resolvedRejects = $cbReject } else { $unresolved += $cbReject }
  $unresolved += $fmUnresolved

  # -- rubric
  $major = $kbMajor + $fmMajor
  $minor = $kbMinor + $fmMinor
  $grade = 9.0
  $grade -= 2.0 * $major
  $grade -= 0.5 * $minor
  $grade -= 1.0 * $extra
  if ($resolvedRejects -gt 0) { $grade -= 1.0 }
  if ($unresolved -gt 0) { $grade -= [Math]::Min(5.0, 2.0 + $unresolved) }
  if ($falseDone) { $grade -= 3.0 }
  if ($grade -gt 10) { $grade = 10 }; if ($grade -lt 1) { $grade = 1 }

  $rec.grade_honest = Round2 $grade
  $rec.iterations = $iterations
  $rec.defects_major = $major
  $rec.defects_minor = $minor
  $rec.reason = ('cb:rej={0},appr={1};kb:maj={2},min={3};fm:maj={4},min={5},unres={6};dl:fail={7};iter={8};falseDone={9}' -f `
      $cbReject, $cbApprove, $kbMajor, $kbMinor, $fmMajor, $fmMinor, $fmUnresolved, $dlFail, $iterations, ([int]$falseDone))

  [void]$audited.Add($rec)
  $stat.matched++; $matchedN++
  $sumOldMatched += $old; $sumHon += $rec.grade_honest
}

# ---------------------------------------------------------------- summary
function Avg([double]$sum, [int]$n) { if ($n -le 0) { return $null }; return [Math]::Round($sum / $n, 3) }

$matchedRecs = @($audited | Where-Object { $null -ne $_.grade_honest })

$topInflated = @($matchedRecs |
  ForEach-Object { [pscustomobject]@{ model = $_.model; agent = $_.agent; date = $_.date; grade_old = $_.grade_old; grade_honest = $_.grade_honest; delta = (Round2 ($_.grade_old - $_.grade_honest)); reason = $_.reason } } |
  Sort-Object -Property @{ Expression = 'delta'; Descending = $true }, agent, date |
  Select-Object -First 10)

$byModel = @($matchedRecs | Group-Object model | ForEach-Object {
  $g = $_.Group
  [pscustomobject]@{ model = $_.Name; n = $g.Count
    avg_old = (Avg (($g | Measure-Object grade_old -Sum).Sum) $g.Count)
    avg_honest = (Avg (($g | Measure-Object grade_honest -Sum).Sum) $g.Count) } } |
  Sort-Object -Property @{ Expression = 'n'; Descending = $true })

$byAgent = @($matchedRecs | Group-Object agent | ForEach-Object {
  $g = $_.Group
  [pscustomobject]@{ agent = $_.Name; n = $g.Count
    avg_old = (Avg (($g | Measure-Object grade_old -Sum).Sum) $g.Count)
    avg_honest = (Avg (($g | Measure-Object grade_honest -Sum).Sum) $g.Count) } } |
  Sort-Object -Property @{ Expression = 'n'; Descending = $true })

$report = [ordered]@{
  window_days  = $WindowDays
  counts       = [ordered]@{ total = $stat.total; matched = $stat.matched; no_signal = $stat.no_signal }
  averages     = [ordered]@{
    old_all      = (Avg $sumOldAll $stat.total)
    old_matched  = (Avg $sumOldMatched $matchedN)
    honest_match = (Avg $sumHon $matchedN)
    delta        = $(if ($matchedN -gt 0) { Round2 ($sumOldMatched / $matchedN - $sumHon / $matchedN) } else { $null })
  }
  top_inflated = $topInflated
  by_model     = $byModel
  by_agent     = $byAgent
  records      = @($audited)
}

# ---------------------------------------------------------------- write file (atomic)
$sb = New-Object System.Text.StringBuilder
foreach ($rec in $audited) {
  [void]$sb.Append((Convert-ToAscii (ConvertTo-Json -InputObject $rec -Compress -Depth 5)))
  [void]$sb.Append("`r`n")
}
$enc = New-Object System.Text.UTF8Encoding($true)
$tmp = "$OutputPath.tmp"
[IO.File]::WriteAllText($tmp, $sb.ToString(), $enc)
Move-Item -LiteralPath $tmp -Destination $OutputPath -Force

# ---------------------------------------------------------------- output
if ($Json) {
  # PS 5.1 ConvertTo-Json chokes on the top-level OrderedDictionary aggregate
  # (ConvertToFinalInvalidCastException); assembling from components is safe.
  $js = New-Object System.Text.StringBuilder
  [void]$js.Append('{"window_days":').Append($WindowDays)
  foreach ($k in @('counts', 'averages', 'top_inflated', 'by_model', 'by_agent', 'records')) {
    [void]$js.Append(',"').Append($k).Append('":')
    [void]$js.Append((ConvertTo-Json -InputObject $report[$k] -Compress -Depth 5))
  }
  [void]$js.Append('}')
  Write-Output (Convert-ToAscii $js.ToString())
  return
}

$avg = $report.averages
Write-Output '=== Rating Audit (honest re-grade, AGENTS.md 7.1) ==='
Write-Output ("window: +/-{0} days | source: {1}" -f $WindowDays, $RatingsPath)
Write-Output ("records: {0} (matched: {1}, no-signal/null: {2})" -f $stat.total, $stat.matched, $stat.no_signal)
Write-Output ("avg old (all):     {0}" -f $avg.old_all)
Write-Output ("avg old (matched): {0}" -f $avg.old_matched)
Write-Output ("avg honest:        {0}" -f $avg.honest_match)
Write-Output ("avg delta:         {0}" -f $avg.delta)
Write-Output ''
Write-Output '--- Top-10 inflated (grade_old - grade_honest) ---'
Write-Output ('{0,-34} {1,-12} {2,-10} {3,5} {4,7} {5,7}  {6}' -f 'model','agent','date','old','honest','delta','reason')
foreach ($t in $topInflated) {
  Write-Output ('{0,-34} {1,-12} {2,-10} {3,5} {4,7} {5,7}  {6}' -f $t.model, $t.agent, $t.date, $t.grade_old, $t.grade_honest, $t.delta, $t.reason)
}
Write-Output ''
Write-Output '--- By model (matched) ---'
Write-Output ('{0,-34} {1,4} {2,9} {3,11}' -f 'model','n','avg_old','avg_honest')
foreach ($m in $byModel) { Write-Output ('{0,-34} {1,4} {2,9} {3,11}' -f $m.model, $m.n, $m.avg_old, $m.avg_honest) }
Write-Output ''
Write-Output '--- By agent (matched) ---'
Write-Output ('{0,-22} {1,4} {2,9} {3,11}' -f 'agent','n','avg_old','avg_honest')
foreach ($a in $byAgent) { Write-Output ('{0,-22} {1,4} {2,9} {3,11}' -f $a.agent, $a.n, $a.avg_old, $a.avg_honest) }
Write-Output ''
Write-Output ("written: {0}" -f $OutputPath)
