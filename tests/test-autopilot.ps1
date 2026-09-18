# test-autopilot.ps1 - independent tests for .agents\scripts\autopilot.ps1 (P3).
#
# Pure PowerShell 5.1 (no Pester). The API matrix runs in-process against the
# dot-sourced functions; the CLI smoke checks run in a child powershell. Every
# call is isolated through AGENT_HQ_ROOT pointing at a temp root, so the real
# repository is never written to. The script is read-only by design and this is
# verified with SHA256 tree snapshots before and after.
#
# Covered:
#   a) hygiene   - PSParser 0 errors, CRLF, ASCII, no BOM, forbidden substring
#   b) policy    - the four levels expose the expected allow/deny matrix
#   c) decisions - level x risk x confidence matrix yields the expected decision
#   d) config    - default level from config, absent/malformed/invalid fall back
#   e) CLI json  - -List/-Current/decision -Json are valid and exit 0
#   f) bad input - empty/invalid confidence, level, risk never crash
#   g) read-only - no file in any root or in the repo config dir changes
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Autopilot = Join-Path $RepoRoot ".agents\scripts\autopilot.ps1"
$TestPath  = $PSCommandPath

$TempBase = Join-Path $env:TEMP "agent-hq-autopilot-tests"
$EmptyRoot       = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigRootL3    = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigRootBad   = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigRootBadLevel = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigRootAlias = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$ConfigRootScalar = Join-Path $TempBase ([guid]::NewGuid().ToString("N"))
$RepoConfigDir   = Join-Path $RepoRoot ".agents\config"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CasePass = 0
$script:CaseFail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
    } else {
        $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { "" } else { " -- " + $Detail }
        Write-Host ("    FAIL: " + $Label + $suffix)
    }
    return $Condition
}

function Close-Case {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:CasePass++; Write-Host ("PASS " + $Name) }
    else { $script:CaseFail++; Write-Host ("FAIL " + $Name) }
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Use-Root {
    param([string]$RootPath)
    if ([string]::IsNullOrWhiteSpace($RootPath)) { Remove-Item -Path Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
    else { $env:AGENT_HQ_ROOT = $RootPath }
}

function Get-TreeSnapshot {
    param([string]$RootPath)
    $lines = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = $file.FullName.Substring($RootPath.Length).TrimStart('\')
        $hash = 'unreadable'
        try { $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash } catch { }
        [void]$lines.Add($rel + '|' + $hash + '|' + $file.Length)
    }
    return @($lines)
}

function Invoke-Autopilot {
    param([string]$RootPath, [string[]]$Arguments = @())
    $previous = $env:AGENT_HQ_ROOT
    $env:AGENT_HQ_ROOT = $RootPath
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $full = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Autopilot) + @($Arguments)
    $text = (& $psExe @full 2>$null | Out-String)
    $code = $LASTEXITCODE
    if ($null -eq $previous) { Remove-Item -Path Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
    else { $env:AGENT_HQ_ROOT = $previous }
    return [pscustomobject]@{ text = $text; code = [int]$code }
}

function Set-UpRoots {
    foreach ($path in @($EmptyRoot, $ConfigRootL3, $ConfigRootBad, $ConfigRootBadLevel, $ConfigRootAlias, $ConfigRootScalar)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    Write-TextFile -Path (Join-Path $ConfigRootL3 ".agents\config\autopilot.json") -Text '{"default_level":"L3"}'
    Write-TextFile -Path (Join-Path $ConfigRootBad ".agents\config\autopilot.json") -Text '{ this is not json'
    Write-TextFile -Path (Join-Path $ConfigRootBadLevel ".agents\config\autopilot.json") -Text '{"default_level":"L9"}'
    Write-TextFile -Path (Join-Path $ConfigRootAlias ".agents\config\autopilot.json") -Text '{"current_level":"L2"}'
    Write-TextFile -Path (Join-Path $ConfigRootScalar ".agents\config\autopilot.json") -Text '"L2"'
}

Set-UpRoots
. $Autopilot

$repoConfigBefore = Get-TreeSnapshot -RootPath $RepoConfigDir
$snapEmptyBefore = Get-TreeSnapshot -RootPath $EmptyRoot
$snapL3Before = Get-TreeSnapshot -RootPath $ConfigRootL3
$snapBadBefore = Get-TreeSnapshot -RootPath $ConfigRootBad

# --- a) hygiene ------------------------------------------------------------

$caseOk = $true
$parserErrors = $null
[void][System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Autopilot -Raw), [ref]$parserErrors)
$caseOk = (Write-Check "autopilot.ps1 parses with 0 errors" (@($parserErrors).Count -eq 0) ("errors=" + @($parserErrors).Count)) -and $caseOk

foreach ($target in @($Autopilot, $TestPath)) {
    $name = Split-Path -Leaf $target
    $bytes = [System.IO.File]::ReadAllBytes($target)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $loneLf = ([regex]::Matches($text, '(?<!\r)\n')).Count
    $nonAscii = ([regex]::Matches($text, '[^\x00-\x7F]')).Count
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $forbidden = 's' + 'k' + [string][char]0x2D
    $forbiddenHits = 0
    if ($text.Contains($forbidden)) { $forbiddenHits = 1 }
    $caseOk = (Write-Check ($name + " uses CRLF") ($loneLf -eq 0) ("loneLF=" + $loneLf)) -and $caseOk
    $caseOk = (Write-Check ($name + " is ASCII only") ($nonAscii -eq 0) ("nonAscii=" + $nonAscii)) -and $caseOk
    $caseOk = (Write-Check ($name + " has no BOM") (-not $hasBom)) -and $caseOk
    $caseOk = (Write-Check ($name + " has no forbidden substring") ($forbiddenHits -eq 0)) -and $caseOk
}
Close-Case "a) hygiene" $caseOk

# --- b) policy matrix ------------------------------------------------------

$caseOk = $true
$p0 = Get-AutopilotLevelPolicy -Level 'L0'
$p1 = Get-AutopilotLevelPolicy -Level 'L1'
$p2 = Get-AutopilotLevelPolicy -Level 'L2'
$p3 = Get-AutopilotLevelPolicy -Level 'L3'

$caseOk = (Write-Check "L0 blocks automatic run" (-not [bool]$p0.auto_run)) -and $caseOk
$caseOk = (Write-Check "L0 requires human approval" ([bool]$p0.human_approval_required)) -and $caseOk
$caseOk = (Write-Check "L0 forbids merge and deploy" ((-not [bool]$p0.allow_merge) -and (-not [bool]$p0.allow_deploy))) -and $caseOk
$caseOk = (Write-Check "L0 uses deep verification" ([string]$p0.verification_depth -eq 'deep')) -and $caseOk

$caseOk = (Write-Check "L1 allows automatic run" ([bool]$p1.auto_run)) -and $caseOk
$caseOk = (Write-Check "L1 keeps human acceptance" (([bool]$p1.human_approval_required) -and (-not [bool]$p1.auto_accept))) -and $caseOk
$caseOk = (Write-Check "L1 forbids merge" (-not [bool]$p1.allow_merge)) -and $caseOk

$caseOk = (Write-Check "L2 auto accepts" ([bool]$p2.auto_accept)) -and $caseOk
$caseOk = (Write-Check "L2 allows merge" ([bool]$p2.allow_merge)) -and $caseOk
$caseOk = (Write-Check "L2 forbids deploy" (-not [bool]$p2.allow_deploy)) -and $caseOk

$caseOk = (Write-Check "L3 allows deploy" ([bool]$p3.allow_deploy)) -and $caseOk
$caseOk = (Write-Check "L3 skips human approval" (-not [bool]$p3.human_approval_required)) -and $caseOk
$caseOk = (Write-Check "L3 uses light verification" ([string]$p3.verification_depth -eq 'light')) -and $caseOk

$pFallback = Get-AutopilotPolicy -Level 'L9' -Root $EmptyRoot
$caseOk = (Write-Check "invalid level falls back to current default (L1)" ([string]$pFallback.level -eq 'L1')) -and $caseOk
$caseOk = (Write-Check "invalid level fallback is reported" ([string]$pFallback.level_source -eq 'invalid-fallback')) -and $caseOk
Close-Case "b) policy" $caseOk

# --- c) decision matrix ----------------------------------------------------

$caseOk = $true
$matrix = @(
    @{ Name = "L0 code high confidence";      Level = 'L0'; Task = 'code';     Conf = 0.90; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L0 docs high confidence";      Level = 'L0'; Task = 'docs';     Conf = 0.95; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L1 code high confidence";      Level = 'L1'; Task = 'code';     Conf = 0.90; Risk = '';     Expect = 'run' },
    @{ Name = "L1 code medium confidence";    Level = 'L1'; Task = 'code';     Conf = 0.50; Risk = '';     Expect = 'run' },
    @{ Name = "L1 code low confidence";       Level = 'L1'; Task = 'code';     Conf = 0.20; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L1 security high risk";        Level = 'L1'; Task = 'security'; Conf = 0.99; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L2 code high confidence";      Level = 'L2'; Task = 'code';     Conf = 0.90; Risk = '';     Expect = 'promote' },
    @{ Name = "L2 code medium confidence";    Level = 'L2'; Task = 'code';     Conf = 0.50; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L2 security high risk";        Level = 'L2'; Task = 'security'; Conf = 0.99; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L3 code high confidence";      Level = 'L3'; Task = 'code';     Conf = 0.90; Risk = '';     Expect = 'promote' },
    @{ Name = "L3 docs high confidence";      Level = 'L3'; Task = 'docs';     Conf = 0.80; Risk = '';     Expect = 'promote' },
    @{ Name = "L3 code medium confidence";    Level = 'L3'; Task = 'code';     Conf = 0.55; Risk = '';     Expect = 'verify' },
    @{ Name = "L3 code low confidence";       Level = 'L3'; Task = 'code';     Conf = 0.20; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L3 ops high risk";             Level = 'L3'; Task = 'ops';      Conf = 0.99; Risk = '';     Expect = 'needs-human' },
    @{ Name = "L3 explicit high risk";        Level = 'L3'; Task = 'code';     Conf = 0.99; Risk = 'high'; Expect = 'needs-human' },
    @{ Name = "L3 unknown type assumed med";  Level = 'L3'; Task = 'nope';     Conf = 0.90; Risk = '';     Expect = 'promote' }
)
foreach ($row in $matrix) {
    $d = Get-AutopilotDecision -TaskType $row.Task -Confidence $row.Conf -Risk $row.Risk -Level $row.Level -Root $EmptyRoot
    $caseOk = (Write-Check ($row.Name + " -> " + $row.Expect) ([string]$d.decision -eq [string]$row.Expect) ("got=" + [string]$d.decision)) -and $caseOk
    if ([string]$row.Expect -eq 'needs-human') {
        $caseOk = (Write-Check ($row.Name + " requires a human") ([bool]$d.requires_human)) -and $caseOk
    }
}

$dL1 = Get-AutopilotDecision -TaskType 'code' -Confidence 0.90 -Level 'L1' -Root $EmptyRoot
$caseOk = (Write-Check "L1 run keeps acceptance manual" (([bool]$dL1.requires_human) -and ([string]$dL1.human_stage -eq 'acceptance'))) -and $caseOk
$caseOk = (Write-Check "L1 run never merges" (-not [bool]$dL1.allow_merge)) -and $caseOk

$dL2 = Get-AutopilotDecision -TaskType 'code' -Confidence 0.90 -Level 'L2' -Root $EmptyRoot
$caseOk = (Write-Check "L2 promote needs no human" (-not [bool]$dL2.requires_human)) -and $caseOk
$caseOk = (Write-Check "L2 promote allows merge, not deploy" (([bool]$dL2.allow_merge) -and (-not [bool]$dL2.allow_deploy))) -and $caseOk

$dL3v = Get-AutopilotDecision -TaskType 'code' -Confidence 0.55 -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "L3 verify needs no human" (-not [bool]$dL3v.requires_human)) -and $caseOk
$caseOk = (Write-Check "L3 verify runs deeply" ([string]$dL3v.verification_depth -eq 'deep')) -and $caseOk

$dL3p = Get-AutopilotDecision -TaskType 'code' -Confidence 0.90 -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "L3 promote allows deploy" ([bool]$dL3p.allow_deploy)) -and $caseOk
$caseOk = (Write-Check "L3 promote auto accepts" ([bool]$dL3p.auto_accept)) -and $caseOk
Close-Case "c) decisions" $caseOk

# --- d) config default level ----------------------------------------------

$caseOk = $true
$cur3 = Get-AutopilotCurrentLevel -Root $ConfigRootL3
$caseOk = (Write-Check "config default_level L3 is used" ([string]$cur3.level -eq 'L3') ("level=" + [string]$cur3.level)) -and $caseOk
$caseOk = (Write-Check "config level source is reported" ([string]$cur3.source -eq 'config')) -and $caseOk

$curEmpty = Get-AutopilotCurrentLevel -Root $EmptyRoot
$caseOk = (Write-Check "absent config defaults to L1" ([string]$curEmpty.level -eq 'L1')) -and $caseOk
$caseOk = (Write-Check "absent config source is default" ([string]$curEmpty.source -eq 'default')) -and $caseOk

$curBad = Get-AutopilotCurrentLevel -Root $ConfigRootBad
$caseOk = (Write-Check "malformed config defaults to L1" ([string]$curBad.level -eq 'L1')) -and $caseOk
$caseOk = (Write-Check "malformed config is reported" ([string]$curBad.config_error -eq 'config-malformed')) -and $caseOk

$curBadLevel = Get-AutopilotCurrentLevel -Root $ConfigRootBadLevel
$caseOk = (Write-Check "invalid config level defaults to L1" ([string]$curBadLevel.level -eq 'L1')) -and $caseOk
$caseOk = (Write-Check "invalid config level is reported" ([string]$curBadLevel.config_error -eq 'config-invalid-level')) -and $caseOk

$curAlias = Get-AutopilotCurrentLevel -Root $ConfigRootAlias
$caseOk = (Write-Check "current_level alias is honoured" ([string]$curAlias.level -eq 'L2')) -and $caseOk

$curScalar = Get-AutopilotCurrentLevel -Root $ConfigRootScalar
$caseOk = (Write-Check "scalar config does not crash" ([string]$curScalar.level -eq 'L1')) -and $caseOk

$dCfg = Get-AutopilotDecision -TaskType 'code' -Confidence 0.90 -Root $ConfigRootL3
$caseOk = (Write-Check "decision uses configured level" ([string]$dCfg.level -eq 'L3') ("level=" + [string]$dCfg.level)) -and $caseOk
$caseOk = (Write-Check "decision uses configured level source" ([string]$dCfg.level_source -eq 'config')) -and $caseOk
$caseOk = (Write-Check "configured L3 promotes high confidence" ([string]$dCfg.decision -eq 'promote')) -and $caseOk

$dCfgBad = Get-AutopilotDecision -TaskType 'code' -Confidence 0.90 -Root $ConfigRootBad
$caseOk = (Write-Check "broken config still yields a decision" ([string]$dCfgBad.decision -eq 'run')) -and $caseOk
Close-Case "d) config" $caseOk

# --- e) CLI json -----------------------------------------------------------

$caseOk = $true
$listJson = Invoke-Autopilot -RootPath $EmptyRoot -Arguments @('-List', '-Json')
$caseOk = (Write-Check "list json exits 0" ($listJson.code -eq 0) ("exit=" + $listJson.code + " out=" + $listJson.text)) -and $caseOk
$listDoc = $null
try { $listDoc = $listJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $listDoc = $null }
$caseOk = (Write-Check "list json is valid" ($null -ne $listDoc)) -and $caseOk
if ($null -ne $listDoc) {
    $caseOk = (Write-Check "list json carries 4 levels" (@($listDoc.levels).Count -eq 4) ("count=" + @($listDoc.levels).Count)) -and $caseOk
    $levelsSeen = @(@($listDoc.levels) | ForEach-Object { [string]$_.level })
    foreach ($expected in @('L0', 'L1', 'L2', 'L3')) {
        $caseOk = (Write-Check ("list json contains " + $expected) ($levelsSeen -contains $expected)) -and $caseOk
    }
}

$currentJson = Invoke-Autopilot -RootPath $ConfigRootL3 -Arguments @('-Current', '-Json')
$caseOk = (Write-Check "current json exits 0" ($currentJson.code -eq 0) ("exit=" + $currentJson.code)) -and $caseOk
$currentDoc = $null
try { $currentDoc = $currentJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $currentDoc = $null }
$caseOk = (Write-Check "current json is valid" ($null -ne $currentDoc)) -and $caseOk
if ($null -ne $currentDoc) {
    $caseOk = (Write-Check "current json reports L3" ([string]$currentDoc.level -eq 'L3')) -and $caseOk
    $caseOk = (Write-Check "current json reports config source" ([string]$currentDoc.level_source -eq 'config')) -and $caseOk
}

$decisionJson = Invoke-Autopilot -RootPath $ConfigRootL3 -Arguments @('-TaskType', 'code', '-Confidence', '0.9', '-Json')
$caseOk = (Write-Check "decision json exits 0" ($decisionJson.code -eq 0) ("exit=" + $decisionJson.code + " out=" + $decisionJson.text)) -and $caseOk
$decisionDoc = $null
try { $decisionDoc = $decisionJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $decisionDoc = $null }
$caseOk = (Write-Check "decision json is valid" ($null -ne $decisionDoc)) -and $caseOk
if ($null -ne $decisionDoc) {
    $caseOk = (Write-Check "decision json reports promote" ([string]$decisionDoc.decision -eq 'promote')) -and $caseOk
    $caseOk = (Write-Check "decision json reports configured level" ([string]$decisionDoc.level -eq 'L3')) -and $caseOk
}

$riskJson = Invoke-Autopilot -RootPath $EmptyRoot -Arguments @('-TaskType', 'security', '-Confidence', '0.99', '-Level', 'L3', '-Json')
$riskDoc = $null
try { $riskDoc = $riskJson.text | ConvertFrom-Json -ErrorAction Stop } catch { $riskDoc = $null }
$caseOk = (Write-Check "high risk json is valid" ($null -ne $riskDoc)) -and $caseOk
if ($null -ne $riskDoc) {
    $caseOk = (Write-Check "high risk json needs a human" ([string]$riskDoc.decision -eq 'needs-human')) -and $caseOk
}

$listText = Invoke-Autopilot -RootPath $EmptyRoot -Arguments @('-List')
$caseOk = (Write-Check "list text exits 0" ($listText.code -eq 0) ("exit=" + $listText.code)) -and $caseOk
foreach ($expected in @('L0', 'L1', 'L2', 'L3')) {
    $caseOk = (Write-Check ("list text shows " + $expected) ($listText.text -match $expected)) -and $caseOk
}

$brokenCurrent = Invoke-Autopilot -RootPath $ConfigRootBad -Arguments @('-Current', '-Json')
$brokenCurrentDoc = $null
try { $brokenCurrentDoc = $brokenCurrent.text | ConvertFrom-Json -ErrorAction Stop } catch { $brokenCurrentDoc = $null }
$caseOk = (Write-Check "broken config CLI exits 0" ($brokenCurrent.code -eq 0) ("exit=" + $brokenCurrent.code)) -and $caseOk
$caseOk = (Write-Check "broken config CLI reports L1" ($null -ne $brokenCurrentDoc -and [string]$brokenCurrentDoc.level -eq 'L1')) -and $caseOk
Close-Case "e) CLI json" $caseOk

# --- f) bad input ----------------------------------------------------------

$caseOk = $true
$threw = $false
$dEmpty = $null
try { $dEmpty = Get-AutopilotDecision -Root $EmptyRoot } catch { $threw = $true }
$caseOk = (Write-Check "empty call does not throw" (-not $threw)) -and $caseOk
$caseOk = (Write-Check "empty call returns a decision" ($null -ne $dEmpty -and -not [string]::IsNullOrWhiteSpace([string]$dEmpty.decision))) -and $caseOk
if ($null -ne $dEmpty) {
    $caseOk = (Write-Check "empty call assumes L1" ([string]$dEmpty.level -eq 'L1')) -and $caseOk
    $caseOk = (Write-Check "empty call assumes confidence 0.5" ([double]$dEmpty.confidence -eq 0.5)) -and $caseOk
}

$dBadConf = Get-AutopilotDecision -TaskType 'code' -Confidence 'abc' -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "non-numeric confidence falls back to 0.5" ([double]$dBadConf.confidence -eq 0.5) ("conf=" + [double]$dBadConf.confidence)) -and $caseOk
$caseOk = (Write-Check "non-numeric confidence yields verify at L3" ([string]$dBadConf.decision -eq 'verify')) -and $caseOk

$dHighConf = Get-AutopilotDecision -TaskType 'code' -Confidence 2.5 -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "confidence above 1 is clamped" ([double]$dHighConf.confidence -eq 1.0) ("conf=" + [double]$dHighConf.confidence)) -and $caseOk

$dNegConf = Get-AutopilotDecision -TaskType 'code' -Confidence -1 -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "negative confidence is clamped to 0" ([double]$dNegConf.confidence -eq 0.0) ("conf=" + [double]$dNegConf.confidence)) -and $caseOk
$caseOk = (Write-Check "clamped zero needs a human" ([string]$dNegConf.decision -eq 'needs-human')) -and $caseOk

$dBadLevel = Get-AutopilotDecision -TaskType 'code' -Confidence 0.9 -Level 'ZZ' -Root $EmptyRoot
$caseOk = (Write-Check "invalid level falls back to L1" ([string]$dBadLevel.level -eq 'L1')) -and $caseOk
$caseOk = (Write-Check "invalid level source is reported" ([string]$dBadLevel.level_source -eq 'invalid-fallback')) -and $caseOk

$dBadRisk = Get-AutopilotDecision -TaskType ' ' -Confidence 0.9 -Risk 'weird' -Level 'L3' -Root $EmptyRoot
$caseOk = (Write-Check "invalid risk falls back to med" ([string]$dBadRisk.risk -eq 'med') ("risk=" + [string]$dBadRisk.risk)) -and $caseOk
$caseOk = (Write-Check "invalid risk source is reported" ([string]$dBadRisk.risk_source -eq 'default-invalid-input')) -and $caseOk

$dBoundaryLow = Get-AutopilotDecision -TaskType 'code' -Confidence 0.40 -Level 'L2' -Root $EmptyRoot
$caseOk = (Write-Check "confidence 0.40 is medium not low" ([string]$dBoundaryLow.confidence_level -eq 'med')) -and $caseOk
$caseOk = (Write-Check "medium confidence at L2 needs a human" ([string]$dBoundaryLow.decision -eq 'needs-human')) -and $caseOk

$dBoundaryHigh = Get-AutopilotDecision -TaskType 'code' -Confidence 0.75 -Level 'L2' -Root $EmptyRoot
$caseOk = (Write-Check "confidence 0.75 is high" ([string]$dBoundaryHigh.confidence_level -eq 'high')) -and $caseOk
$caseOk = (Write-Check "high confidence at L2 promotes" ([string]$dBoundaryHigh.decision -eq 'promote')) -and $caseOk
Close-Case "f) bad input" $caseOk

# --- g) read-only ----------------------------------------------------------

$caseOk = $true
$snapEmptyAfter = Get-TreeSnapshot -RootPath $EmptyRoot
$snapL3After = Get-TreeSnapshot -RootPath $ConfigRootL3
$snapBadAfter = Get-TreeSnapshot -RootPath $ConfigRootBad
$repoConfigAfter = Get-TreeSnapshot -RootPath $RepoConfigDir

$caseOk = (Write-Check "empty root unchanged" ((($snapEmptyBefore -join ';') -eq ($snapEmptyAfter -join ';')))) -and $caseOk
$caseOk = (Write-Check "config L3 root unchanged" ((($snapL3Before -join ';') -eq ($snapL3After -join ';')))) -and $caseOk
$caseOk = (Write-Check "broken config root unchanged" ((($snapBadBefore -join ';') -eq ($snapBadAfter -join ';')))) -and $caseOk
$caseOk = (Write-Check "repo config dir unchanged" ((($repoConfigBefore -join ';') -eq ($repoConfigAfter -join ';')))) -and $caseOk

$repoAutopilotConfig = Join-Path $RepoConfigDir 'autopilot.json'
$existedBefore = @($repoConfigBefore | Where-Object { $_ -match 'autopilot\.json' }).Count -gt 0
$existsNow = Test-Path -LiteralPath $repoAutopilotConfig -PathType Leaf
$caseOk = (Write-Check "script did not create a repo config" ($existedBefore -or (-not $existsNow))) -and $caseOk
Close-Case "g) read-only" $caseOk

# --- cleanup ---------------------------------------------------------------

Use-Root ""
try { Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ""
Write-Host ("=== cases: " + $script:CasePass + " passed, " + $script:CaseFail + " failed ===")
if ($script:CaseFail -gt 0) { exit 1 }
exit 0
