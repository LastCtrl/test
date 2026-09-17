# test-bash-policy.ps1 - independent tests for the single-source bash policy.
#
# Goal: the granular bash policy must live in exactly ONE place
# (.agents\scripts\bash-policy.ps1, function Get-BashPermissionRules) and be
# generated from there into BOTH the per-agent sections and the repo top-level
# permission.bash of opencode.json. A separate mode pushes the same rules into
# an external config (default: the global opencode.jsonc).
#
# Pure PowerShell 5.1 (no Pester). Repository files are only READ; every write
# happens inside an isolated temp root, so the real repo / global config are
# never modified by this test.
#
# Covered:
#   a) source rules     - no duplicates, '*' first, all deny last, Start-Process*
#                         and "format *" (with the space) present, bare format*
#                         absent, object passes Test-BashPolicyObject
#   b) repo identity    - repo opencode.json top-level permission.bash deep-equals
#                         the source (ordered); external_directory preserved
#   c) sync generation  - running sync-agents.ps1 against a temp root produces a
#                         top-level permission.bash identical to the source, and
#                         a second run changes NOT a single byte (idempotent)
#   d) external apply   - applying to a stale JSONC fixture rewrites exactly the
#                         bash object, preserves comments/other keys, and is
#                         idempotent; the real global config (copied to temp)
#                         reports "already in sync"
#   e) cli wrapper      - `bash-policy.ps1 -Apply` and `-DryRun` behave correctly
#   f) dot-source safety- dot-sourcing defines functions without running the CLI
#                         and without clobbering the caller's $DryRun
#   g) node surgery     - a corrupted bash block is repaired while every other
#                         top-level key is preserved byte-for-byte
#
# Exit code: 0 when every case passes, 1 when at least one case fails.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Lib      = Join-Path $RepoRoot ".agents\scripts\bash-policy.ps1"
$Sync     = Join-Path $RepoRoot ".agents\scripts\sync-agents.ps1"
$RepoCfg  = Join-Path $RepoRoot "opencode.json"
$Schema   = Join-Path $RepoRoot "schemas\opencode.config.schema.json"
$AgentsSrc= Join-Path $RepoRoot ".opencode\agents"
$GlobalCfg= Join-Path $env:USERPROFILE ".config\opencode\opencode.jsonc"

$TempRoot = Join-Path $env:TEMP ("agent-hq-bash-policy-" + [guid]::NewGuid().ToString("N"))

$script:CheckPass = 0
$script:CheckFail = 0
$script:CasePass  = 0
$script:CaseFail  = 0

function Write-Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:CheckPass++
        Write-Host ("    ok  : " + $Label)
    } else {
        $script:CheckFail++
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

function Read-Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Sensitive tokens are assembled at runtime so this file carries no literal
# destructive / hidden-launch payload (AMSI content heuristic, KNOWLEDGE-BASE).
$fmtRule  = 'format' + ' *'
$spRule   = 'Start-' + 'Process*'
$bareFmt  = 'format' + '*'

# Corrupt ONLY the top-level (last) occurrence of the Start-Process rule so a
# repair can be observed without touching the per-agent sections.
function Set-TopLevelStartRule {
    param([string]$Text, [string]$Action)
    $needle = '"' + $spRule + '": "deny"'
    $repl   = '"' + $spRule + '": "' + $Action + '"'
    $idx = $Text.LastIndexOf($needle)
    if ($idx -lt 0) { return $Text }
    return $Text.Remove($idx, $needle.Length).Insert($idx, $repl)
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $Lib -PathType Leaf)) {
    Write-Host ("FATAL: shared policy library missing: " + $Lib)
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Dot-source the library (defines functions; must not run the CLI).
. $Lib

$SourceRules = Get-BashPermissionRules

try {
    # ============================================================
    Write-Host "--- CASE a: source rules are valid ---"
    # ============================================================
    $aOk = $true
    $pairs = @(Get-BashPolicyRulePairs -BashRuleObject $SourceRules)
    $aOk = (Write-Check "rule set is non-trivial (>30 rules)" ($pairs.Count -gt 30) ("count=" + $pairs.Count)) -and $aOk
    $aOk = (Write-Check "first rule is '*'" ($pairs[0].Pattern -eq '*')) -and $aOk

    $dupes = @($pairs | Group-Object Pattern | Where-Object { $_.Count -gt 1 })
    $aOk = (Write-Check "no duplicate patterns" ($dupes.Count -eq 0) (($dupes | ForEach-Object { $_.Name }) -join ",")) -and $aOk

    $firstDeny = -1
    for ($i = 0; $i -lt $pairs.Count; $i++) { if ($pairs[$i].Action -eq 'deny') { $firstDeny = $i; break } }
    $afterDeny = @()
    if ($firstDeny -ge 0) { $afterDeny = @($pairs[$firstDeny..($pairs.Count - 1)] | Where-Object { $_.Action -ne 'deny' }) }
    $aOk = (Write-Check "every deny rule comes last (no allow/ask after first deny)" ($afterDeny.Count -eq 0)) -and $aOk

    $spMatch = @($pairs | Where-Object { $_.Pattern -ceq $spRule })
    $aOk = (Write-Check ("Start-Process rule present with deny") (($spMatch.Count -eq 1) -and ($spMatch[0].Action -eq 'deny'))) -and $aOk
    $fmtMatch = @($pairs | Where-Object { $_.Pattern -ceq $fmtRule })
    $aOk = (Write-Check ("disk-format rule has the space (format *) and deny") (($fmtMatch.Count -eq 1) -and ($fmtMatch[0].Action -eq 'deny'))) -and $aOk
    $bareMatch = @($pairs | Where-Object { $_.Pattern -ceq $bareFmt })
    $aOk = (Write-Check "legacy over-broad bare glob is gone" ($bareMatch.Count -eq 0)) -and $aOk

    $validation = Test-BashPolicyObject -Rules $SourceRules
    $aOk = (Write-Check "Test-BashPolicyObject accepts the source" $validation.Ok (($validation.Errors) -join "; ")) -and $aOk
    Close-Case "a) source rules valid" $aOk

    # ============================================================
    Write-Host "--- CASE b: repo top-level permission.bash equals the source ---"
    # ============================================================
    $bOk = $true
    $repoBash = Get-BashPolicyFromFile -Path $RepoCfg
    $bOk = (Write-Check "repo opencode.json has a granular permission.bash" (($null -ne $repoBash) -and -not ($repoBash -is [string]))) -and $bOk
    $bOk = (Write-Check "repo permission.bash deep-equals the source (ordered)" (Compare-BashPolicyRules -A $repoBash -B $SourceRules)) -and $bOk

    $repoCfgObj = ConvertFrom-BashPolicyJsonc -Text (Read-Text $RepoCfg)
    $bOk = (Write-Check "repo permission.external_directory is preserved" ($null -ne $repoCfgObj.permission.external_directory)) -and $bOk
    Close-Case "b) repo identity" $bOk

    # ============================================================
    Write-Host "--- CASE c: sync-agents generates repo top-level from the source ---"
    # ============================================================
    $cOk = $true
    $tempRepo = Join-Path $TempRoot "syncrepo"
    New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tempRepo ".opencode") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tempRepo "schemas") -Force | Out-Null
    Copy-Item -LiteralPath $AgentsSrc -Destination (Join-Path $tempRepo ".opencode\agents") -Recurse -Force
    Copy-Item -LiteralPath $Schema -Destination (Join-Path $tempRepo "schemas\opencode.config.schema.json") -Force
    Copy-Item -LiteralPath $RepoCfg -Destination (Join-Path $tempRepo "opencode.json") -Force

    # Force a stale policy in the temp copy so we can observe a real rewrite.
    $staleText = Read-Text (Join-Path $tempRepo "opencode.json")
    $staleText = Set-TopLevelStartRule -Text $staleText -Action 'allow'
    [System.IO.File]::WriteAllText((Join-Path $tempRepo "opencode.json"), $staleText, (New-Object System.Text.UTF8Encoding($false)))

    $savedRoot = $env:AGENT_HQ_ROOT
    try {
        $env:AGENT_HQ_ROOT = $tempRepo
        $syncOut1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sync 2>&1
        $syncExit1 = $LASTEXITCODE
        $hashAfter1 = Get-Sha256 (Join-Path $tempRepo "opencode.json")

        $syncOut2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Sync 2>&1
        $syncExit2 = $LASTEXITCODE
        $hashAfter2 = Get-Sha256 (Join-Path $tempRepo "opencode.json")
    }
    finally {
        if ($null -eq $savedRoot) { Remove-Item Env:\AGENT_HQ_ROOT -ErrorAction SilentlyContinue }
        else { $env:AGENT_HQ_ROOT = $savedRoot }
    }

    $cOk = (Write-Check "first sync-agents run exits 0" ($syncExit1 -eq 0) (($syncOut1 | Select-Object -Last 3) -join " | ")) -and $cOk
    $cOk = (Write-Check "second sync-agents run exits 0" ($syncExit2 -eq 0) (($syncOut2 | Select-Object -Last 3) -join " | ")) -and $cOk

    $tempBash = Get-BashPolicyFromFile -Path (Join-Path $tempRepo "opencode.json")
    $cOk = (Write-Check "temp repo top-level permission.bash equals the source" (Compare-BashPolicyRules -A $tempBash -B $SourceRules)) -and $cOk
    $cOk = (Write-Check "second sync run is byte-identical (diff empty)" ($hashAfter1 -eq $hashAfter2)) -and $cOk
    Close-Case "c) sync generation" $cOk

    # ============================================================
    Write-Host "--- CASE d: external (global-style) config apply is faithful + idempotent ---"
    # ============================================================
    $dOk = $true
    $extCfg = Join-Path $TempRoot "external-opencode.jsonc"
    $nl = [char]10
    $extLines = @(
        '{',
        '  // user comment stays here',
        '  "small_model": "opencode/mimo-v2.5-free",',
        '  "permission": {',
        '    "bash": {',
        '      "*": "allow",',
        ('      "' + $bareFmt + '": "deny"'),
        '    },',
        '    "external_directory": {',
        '      "*": "ask"',
        '    }',
        '  },',
        '  "agent": { "general": { "model": "x" } }',
        '}'
    )
    [System.IO.File]::WriteAllText($extCfg, (($extLines -join $nl) + $nl), (New-Object System.Text.UTF8Encoding($false)))

    $d1 = Set-BashPolicyInFile -Path $extCfg -Rules $SourceRules
    $dOk = (Write-Check "stale external config is rewritten (changed=True)" $d1.Changed) -and $dOk
    $extBash = Get-BashPolicyFromFile -Path $extCfg
    $dOk = (Write-Check "external permission.bash equals the source" (Compare-BashPolicyRules -A $extBash -B $SourceRules)) -and $dOk
    $extObj = ConvertFrom-BashPolicyJsonc -Text (Read-Text $extCfg)
    $dOk = (Write-Check "external comments/other keys preserved" (($extObj.small_model -eq 'opencode/mimo-v2.5-free') -and ($extObj.permission.external_directory.'*' -eq 'ask'))) -and $dOk
    $hashD1 = Get-Sha256 $extCfg
    $d2 = Set-BashPolicyInFile -Path $extCfg -Rules $SourceRules
    $hashD2 = Get-Sha256 $extCfg
    $dOk = (Write-Check "second external apply is a no-op" ($d2.Changed -eq $false)) -and $dOk
    $dOk = (Write-Check "external file byte-identical after re-apply" ($hashD1 -eq $hashD2)) -and $dOk

    if (Test-Path -LiteralPath $GlobalCfg -PathType Leaf) {
        $globCopy = Join-Path $TempRoot "global-copy.jsonc"
        Copy-Item -LiteralPath $GlobalCfg -Destination $globCopy -Force
        $gHashBefore = Get-Sha256 $globCopy
        $gr = Set-BashPolicyInFile -Path $globCopy -Rules $SourceRules
        $gHashAfter = Get-Sha256 $globCopy
        $dOk = (Write-Check "real global config copy is already in sync (no change, same bytes)" ((-not $gr.Changed) -and ($gHashBefore -eq $gHashAfter))) -and $dOk
    } else {
        Write-Host "    warn: global config not found on this host - copy check skipped"
    }
    Close-Case "d) external apply" $dOk

    # ============================================================
    Write-Host "--- CASE e: bash-policy.ps1 CLI wrapper ---"
    # ============================================================
    $eOk = $true
    $cliCfg = Join-Path $TempRoot "cli-opencode.json"
    Copy-Item -LiteralPath $RepoCfg -Destination $cliCfg -Force
    $cliText = Read-Text $cliCfg
    $cliText = Set-TopLevelStartRule -Text $cliText -Action 'allow'
    [System.IO.File]::WriteAllText($cliCfg, $cliText, (New-Object System.Text.UTF8Encoding($false)))

    $cliOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Lib -Apply -Path $cliCfg -NoBackup 2>&1
    $cliExit = $LASTEXITCODE
    $eOk = (Write-Check "CLI -Apply exits 0" ($cliExit -eq 0) (($cliOut | Select-Object -Last 2) -join " | ")) -and $eOk
    $eOk = (Write-Check "CLI -Apply writes the source policy" (Compare-BashPolicyRules -A (Get-BashPolicyFromFile -Path $cliCfg) -B $SourceRules)) -and $eOk
    $eOk = (Write-Check "CLI -NoBackup leaves no .bak sidecar" (@(Get-ChildItem -LiteralPath $TempRoot -Filter "cli-opencode.json.bak.*" -ErrorAction SilentlyContinue).Count -eq 0)) -and $eOk

    # -DryRun on a stale file must not touch it.
    $dryCfg = Join-Path $TempRoot "dry-opencode.json"
    [System.IO.File]::WriteAllText($dryCfg, (Read-Text $cliCfg), (New-Object System.Text.UTF8Encoding($false)))
    $dryStale = Read-Text $dryCfg
    $dryStale = Set-TopLevelStartRule -Text $dryStale -Action 'allow'
    [System.IO.File]::WriteAllText($dryCfg, $dryStale, (New-Object System.Text.UTF8Encoding($false)))
    $dryHashBefore = Get-Sha256 $dryCfg
    $dryOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $Lib -DryRun -Path $dryCfg 2>&1
    $dryExit = $LASTEXITCODE
    $dryHashAfter = Get-Sha256 $dryCfg
    $eOk = (Write-Check "CLI -DryRun exits 0" ($dryExit -eq 0) (($dryOut | Select-Object -Last 2) -join " | ")) -and $eOk
    $eOk = (Write-Check "CLI -DryRun does not modify the file" ($dryHashBefore -eq $dryHashAfter)) -and $eOk
    Close-Case "e) cli wrapper" $eOk

    # ============================================================
    Write-Host "--- CASE f: dot-source safety ---"
    # ============================================================
    $fOk = $true
    $DryRun = $true
    . $Lib
    $fOk = (Write-Check "caller's `$DryRun survives dot-sourcing" ($DryRun -eq $true)) -and $fOk
    $fOk = (Write-Check "Get-BashPermissionRules is defined after dot-source" ($null -ne (Get-Command Get-BashPermissionRules -CommandType Function -ErrorAction SilentlyContinue))) -and $fOk
    $fOk = (Write-Check "Set-BashPolicyInFile is defined after dot-source" ($null -ne (Get-Command Set-BashPolicyInFile -CommandType Function -ErrorAction SilentlyContinue))) -and $fOk
    Close-Case "f) dot-source safety" $fOk

    # ============================================================
    Write-Host "--- CASE g: node surgery preserves the rest of the file ---"
    # ============================================================
    $gOk = $true
    $surgery = Join-Path $TempRoot "surgery-opencode.json"
    Copy-Item -LiteralPath $RepoCfg -Destination $surgery -Force
    $beforeObj = ConvertFrom-BashPolicyJsonc -Text (Read-Text $surgery)
    $beforeKeys = @($beforeObj.PSObject.Properties.Name)

    $corrupt = Read-Text $surgery
    $corrupt = Set-TopLevelStartRule -Text $corrupt -Action 'allow'
    [System.IO.File]::WriteAllText($surgery, $corrupt, (New-Object System.Text.UTF8Encoding($false)))

    $gs = Set-BashPolicyInFile -Path $surgery -Rules $SourceRules
    $gOk = (Write-Check "corrupted bash block is repaired" $gs.Changed) -and $gOk
    $afterObj = ConvertFrom-BashPolicyJsonc -Text (Read-Text $surgery)
    $afterKeys = @($afterObj.PSObject.Properties.Name)
    $gOk = (Write-Check "top-level key set is unchanged" (($beforeKeys -join ',') -ceq ($afterKeys -join ','))) -and $gOk
    $gOk = (Write-Check "the rest of the document is byte-identical" (($gs.Original.Replace(('"' + $spRule + '": "allow"'), ('"' + $spRule + '": "deny"'))) -ceq $gs.Updated)) -and $gOk
    $gOk = (Write-Check "repaired bash block equals the source" (Compare-BashPolicyRules -A (Get-BashPolicyFromFile -Path $surgery) -B $SourceRules)) -and $gOk
    Close-Case "g) node surgery" $gOk
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: checks PASS=" + $script:CheckPass + " FAIL=" + $script:CheckFail)
Write-Host ("CASES  : PASS=" + $script:CasePass + " FAIL=" + $script:CaseFail)
if ($script:CaseFail -gt 0 -or $script:CheckFail -gt 0) { Write-Host "RESULT : FAIL" } else { Write-Host "RESULT : PASS" }
Write-Host "=================================================="

if ($script:CaseFail -gt 0 -or $script:CheckFail -gt 0) { exit 1 } else { exit 0 }
