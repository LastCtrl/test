# test-discovery.ps1 - native discovery test for the agent-hq fleet.
#
# Goal: prove that the opencode runtime REALLY sees every agent and every skill
# (not just that the files exist on disk), that agent names are unique, and that
# every skill referenced by "required_skills" resolves to an existing skill.
#
# The test drives the real `opencode` CLI from the repository root:
#   opencode debug config  -> resolved config; ".agent.<name>" == agent seen by runtime
#   opencode debug skill   -> resolved skill list exactly as the runtime sees it
#
# Sources of truth:
#   .opencode\agents\*.json        agent definitions (registry.json is legacy, excluded)
#   .agents\skills\*\SKILL.md      skill definitions (incl. superpowers\*\SKILL.md)
#   .opencode\agents\registry.json required_skills references (legacy registry)
#   agent-hq.json                  required_skills / skills references, when present
#
# Pure PowerShell 5.1, no Pester.
# Exit code: 0 when no check FAILed (SKIP is allowed), 1 when at least one FAILed.

$Here            = $PSScriptRoot
$RepoRoot        = Split-Path -Parent $Here
$AgentsDir       = Join-Path $RepoRoot ".opencode\agents"
$SkillsDir       = Join-Path $RepoRoot ".agents\skills"
$LegacyRegistry  = Join-Path $AgentsDir "registry.json"
$ProjectRegistry = Join-Path $RepoRoot "agent-hq.json"
$KnownBuiltins   = @("explore", "general")

$script:CountPass = 0
$script:CountFail = 0
$script:CountSkip = 0
$script:CountWarn = 0

# --- output helpers --------------------------------------------------------

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL", "SKIP", "WARN")][string]$Status,
        [string]$Detail = ""
    )
    switch ($Status) {
        "PASS" { $script:CountPass++ }
        "FAIL" { $script:CountFail++ }
        "SKIP" { $script:CountSkip++ }
        "WARN" { $script:CountWarn++ }
    }
    $line = "  [" + $Status + "] " + $Check
    if ($Detail) { $line = $line + " -- " + $Detail }
    $color = "Gray"
    if ($Status -eq "PASS") { $color = "Green" }
    elseif ($Status -eq "FAIL") { $color = "Red" }
    elseif ($Status -eq "SKIP") { $color = "Yellow" }
    elseif ($Status -eq "WARN") { $color = "DarkYellow" }
    Write-Host $line -ForegroundColor $color
}

# --- CLI helper ------------------------------------------------------------

function Invoke-OpenCodeJson {
    param([string[]]$Arguments)
    $text = ""
    $code = -1
    $errorText = ""
    Push-Location -LiteralPath $RepoRoot
    try {
        $text = (& opencode @Arguments 2>$null | Out-String)
        $code = $LASTEXITCODE
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        Pop-Location
    }
    $json = $null
    if ($text -and $text.Trim().Length -gt 0) {
        try { $json = $text | ConvertFrom-Json } catch { $json = $null }
    }
    return [pscustomobject]@{
        ExitCode  = $code
        Text      = $text
        Json      = $json
        ErrorText = $errorText
    }
}

# --- skill frontmatter helper ---------------------------------------------

function Get-SkillFrontmatter {
    param([string]$Path)
    $result = [pscustomobject]@{
        HasFrontmatter = $false
        Name           = ""
        Description    = ""
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 3) { return $result }
    if ($lines[0].Trim() -ne "---") { return $result }
    $result.HasFrontmatter = $true

    $descriptionParts = New-Object System.Collections.ArrayList
    $inDescription = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq "---") { break }

        if ($inDescription) {
            if ($line -match "^\s+\S") {
                [void]$descriptionParts.Add($line.Trim())
                continue
            }
            $inDescription = $false
        }
        if ($line -match "^name:\s*(.*)$") {
            $rawName = $Matches[1].Trim()
            $result.Name = $rawName.Trim('"').Trim("'").Trim()
        } elseif ($line -match "^description:\s*(.*)$") {
            $rawDescription = $Matches[1].Trim()
            if ($rawDescription -eq "" -or $rawDescription -eq "|" -or $rawDescription -eq ">") {
                $inDescription = $true
            } else {
                [void]$descriptionParts.Add($rawDescription.Trim('"').Trim("'").Trim())
            }
        }
    }
    $result.Description = ($descriptionParts -join " ").Trim()
    return $result
}

# --- required_skills helpers ----------------------------------------------

function Test-StringArray {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -isnot [System.Collections.IEnumerable]) { return $false }
    $items = @($Value)
    if ($items.Count -eq 0) { return $false }
    foreach ($item in $items) {
        if ($item -isnot [string]) { return $false }
    }
    return $true
}

function Get-SkillReference {
    param($Node, [string]$NodePath = "", [int]$Depth = 0)
    $result = New-Object System.Collections.ArrayList
    if ($null -eq $Node -or $Depth -gt 12) { return $result }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $childPath = if ($NodePath) { $NodePath + "." + $key } else { [string]$key }
            foreach ($item in (Get-SkillReference -Node $Node[$key] -NodePath $childPath -Depth ($Depth + 1))) {
                [void]$result.Add($item)
            }
        }
        return $result
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $childPath = if ($NodePath) { $NodePath + "." + $prop.Name } else { $prop.Name }
            if (($prop.Name -eq "required_skills" -or $prop.Name -eq "skills") -and (Test-StringArray $prop.Value)) {
                foreach ($value in @($prop.Value)) {
                    [void]$result.Add([pscustomobject]@{ Owner = $NodePath; Skill = $value })
                }
            } else {
                foreach ($item in (Get-SkillReference -Node $prop.Value -NodePath $childPath -Depth ($Depth + 1))) {
                    [void]$result.Add($item)
                }
            }
        }
        return $result
    }
    return $result
}

# ===========================================================================
# Main
# ===========================================================================

Write-Host "=== agent-hq native discovery test ==="
Write-Host ("Repo root  : " + $RepoRoot)
Write-Host ("Agents dir : " + $AgentsDir)
Write-Host ("Skills dir : " + $SkillsDir)
Write-Host ""

if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    Write-Host ("FATAL: agents dir not found: " + $AgentsDir)
    exit 1
}
if (-not (Test-Path -LiteralPath $SkillsDir -PathType Container)) {
    Write-Host ("FATAL: skills dir not found: " + $SkillsDir)
    exit 1
}
$openCodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
if ($null -eq $openCodeCommand) {
    Write-Host "FATAL: 'opencode' CLI not found in PATH"
    exit 1
}

Write-Host "-- Check 1: runtime CLI works (opencode debug config) --"
$configResult = Invoke-OpenCodeJson -Arguments @("debug", "config")
$agentTable = $null
if ($configResult.ExitCode -eq 0 -and $null -ne $configResult.Json) {
    $agentTable = $configResult.Json.agent
}
if ($configResult.ExitCode -eq 0) {
    Add-Result "opencode debug config exit code is 0" "PASS" ("exit=" + $configResult.ExitCode + ", output=" + $configResult.Text.Length + " chars")
} else {
    $suffix = ""
    if ($configResult.ErrorText) { $suffix = ", error=" + $configResult.ErrorText }
    Add-Result "opencode debug config exit code is 0" "FAIL" ("exit=" + $configResult.ExitCode + $suffix)
}
if ($null -ne $agentTable -and @($agentTable.PSObject.Properties).Count -gt 0) {
    $runtimeAgents = @($agentTable.PSObject.Properties.Name)
    Add-Result "debug config returns parseable JSON with a non-empty .agent map" "PASS" ($runtimeAgents.Count.ToString() + " runtime agent key(s)")
} else {
    $runtimeAgents = @()
    Add-Result "debug config returns parseable JSON with a non-empty .agent map" "FAIL" "cannot read .agent from config output"
}
Write-Host ""

Write-Host "-- Check 2: agent source files --"
$sourceAgents = New-Object System.Collections.ArrayList
$agentFilesWithoutName = New-Object System.Collections.ArrayList
$agentFileErrors = New-Object System.Collections.ArrayList
$agentFiles = @(Get-ChildItem -LiteralPath $AgentsDir -Filter "*.json" -File | Sort-Object Name)
foreach ($file in $agentFiles) {
    if ($file.Name -ieq "registry.json") { continue }
    $json = $null
    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [void]$agentFileErrors.Add($file.Name + " (" + $_.Exception.Message + ")")
        continue
    }
    $name = [string]$json.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        [void]$agentFilesWithoutName.Add($file.Name)
        continue
    }
    [void]$sourceAgents.Add([pscustomobject]@{ Name = $name; File = $file.Name })
}

if ($sourceAgents.Count -gt 0) {
    Add-Result "agent definition files discovered" "PASS" ($sourceAgents.Count.ToString() + " agent file(s) with a 'name' field (registry.json excluded)")
} else {
    Add-Result "agent definition files discovered" "FAIL" "no usable .opencode\agents\*.json with a 'name' field"
}
if ($agentFileErrors.Count -eq 0) {
    Add-Result "every agent json parses" "PASS" ($agentFiles.Count.ToString() + " json file(s) parsed")
} else {
    Add-Result "every agent json parses" "FAIL" ($agentFileErrors -join "; ")
}
if ($agentFilesWithoutName.Count -eq 0) {
    Add-Result "every agent json has a non-empty 'name'" "PASS" "0 file(s) missing 'name'"
} else {
    Add-Result "every agent json has a non-empty 'name'" "FAIL" ($agentFilesWithoutName -join ", ")
}
Write-Host ""

Write-Host "-- Check 3: agents visible to the runtime (debug config .agent) --"
$sourceNames = @($sourceAgents | ForEach-Object { $_.Name })
$missingAgents = @($sourceNames | Where-Object { $runtimeAgents -notcontains $_ })
$visibleCount = $sourceNames.Count - $missingAgents.Count
if ($missingAgents.Count -eq 0) {
    Add-Result "every source agent is present in runtime .agent" "PASS" ($visibleCount.ToString() + "/" + $sourceNames.Count + " visible")
} else {
    Add-Result "every source agent is present in runtime .agent" "FAIL" ("missing: " + ($missingAgents -join ", "))
}
if ($visibleCount -eq $sourceNames.Count) {
    Add-Result "runtime agent count matches source agent count" "PASS" ("sources=" + $sourceNames.Count + ", matched=" + $visibleCount + ", runtime keys=" + $runtimeAgents.Count)
} else {
    Add-Result "runtime agent count matches source agent count" "FAIL" ("sources=" + $sourceNames.Count + ", matched=" + $visibleCount)
}
$extraAgents = @($runtimeAgents | Where-Object { $sourceNames -notcontains $_ -and $KnownBuiltins -notcontains $_ })
if ($extraAgents.Count -gt 0) {
    $extraDetail = @()
    foreach ($extra in $extraAgents) {
        $mdPath = Join-Path $AgentsDir ($extra + ".md")
        if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
            $extraDetail += ($extra + " (from " + $mdPath.Substring($RepoRoot.Length).TrimStart('\') + ")")
        } else {
            $extraDetail += $extra
        }
    }
    Add-Result "runtime exposes only declared agents (builtins aside)" "WARN" ("undeclared runtime agent(s): " + ($extraDetail -join "; "))
} else {
    Add-Result "runtime exposes only declared agents (builtins aside)" "PASS" "no undeclared runtime agent"
}
Write-Host ""

Write-Host "-- Check 4: agent name uniqueness --"
$duplicateAgentNames = @($sourceNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name + " x" + $_.Count })
if ($duplicateAgentNames.Count -eq 0) {
    Add-Result "agent names are unique across .opencode\agents\*.json" "PASS" ($sourceNames.Count.ToString() + " distinct name(s)")
} else {
    Add-Result "agent names are unique across .opencode\agents\*.json" "FAIL" ($duplicateAgentNames -join ", ")
}
Write-Host ""

Write-Host "-- Check 5: skill files and frontmatter --"
$skillFiles = @(Get-ChildItem -LiteralPath $SkillsDir -Recurse -Filter "SKILL.md" -File | Sort-Object FullName)
$skills = New-Object System.Collections.ArrayList
foreach ($file in $skillFiles) {
    $relativeDir = $file.Directory.FullName.Substring($SkillsDir.Length).TrimStart('\')
    $segments = @($relativeDir -split "\\" | Where-Object { $_ -ne "" })
    $leafName = $segments[$segments.Count - 1]
    $canonicalName = ($segments -join "-")
    $frontmatter = Get-SkillFrontmatter -Path $file.FullName
    [void]$skills.Add([pscustomobject]@{
        Path           = $file.FullName
        RelativeDir    = $relativeDir
        LeafName       = $leafName
        CanonicalName  = $canonicalName
        Name           = $frontmatter.Name
        Description    = $frontmatter.Description
        HasFrontmatter = $frontmatter.HasFrontmatter
    })
}

if ($skills.Count -gt 0) {
    Add-Result "SKILL.md files discovered" "PASS" ($skills.Count.ToString() + " file(s)")
} else {
    Add-Result "SKILL.md files discovered" "FAIL" ("no SKILL.md under " + $SkillsDir)
}
$noFrontmatter = @($skills | Where-Object { -not $_.HasFrontmatter } | ForEach-Object { $_.RelativeDir })
$emptyName = @($skills | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.RelativeDir })
$emptyDescription = @($skills | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) } | ForEach-Object { $_.RelativeDir })
if ($noFrontmatter.Count -eq 0) {
    Add-Result "every SKILL.md starts with a '---' frontmatter block" "PASS" ($skills.Count.ToString() + " checked")
} else {
    Add-Result "every SKILL.md starts with a '---' frontmatter block" "FAIL" ("no frontmatter: " + ($noFrontmatter -join ", "))
}
if ($emptyName.Count -eq 0) {
    Add-Result "every skill has a non-empty 'name'" "PASS" ($skills.Count.ToString() + " checked")
} else {
    Add-Result "every skill has a non-empty 'name'" "FAIL" ("empty name: " + ($emptyName -join ", "))
}
if ($emptyDescription.Count -eq 0) {
    Add-Result "every skill has a non-empty 'description'" "PASS" ($skills.Count.ToString() + " checked")
} else {
    Add-Result "every skill has a non-empty 'description'" "FAIL" ("empty description: " + ($emptyDescription -join ", "))
}
Write-Host ""

Write-Host "-- Check 6: skill name matches its folder --"
# Naming convention: a skill's `name` is its path below .agents\skills with path
# separators replaced by '-'. Top-level skills therefore equal their folder name
# (windows-safety), while nested ones are <parent>-<leaf> (superpowers\test ->
# superpowers-test). This is exactly what `opencode debug skill` reports, so a
# leaf-folder-only comparison would wrongly flag the superpowers skills.
$canonicalMatches = @($skills | Where-Object { $_.Name -eq $_.CanonicalName })
$leafOnlyMatches = @($skills | Where-Object { $_.Name -ne $_.CanonicalName -and $_.Name -eq $_.LeafName })
$nameFolderMismatch = @($skills | Where-Object { $_.Name -ne $_.CanonicalName -and $_.Name -ne $_.LeafName })
$mismatchDetail = @()
foreach ($badSkill in $nameFolderMismatch) {
    $mismatchDetail += ($badSkill.Name + " (folder '" + $badSkill.RelativeDir + "' -> expected '" + $badSkill.CanonicalName + "' or '" + $badSkill.LeafName + "')")
}
$detailText = ($canonicalMatches.Count.ToString() + " via canonical relative-path name, " + $leafOnlyMatches.Count.ToString() + " via leaf folder name")
if ($nameFolderMismatch.Count -eq 0) {
    Add-Result "skill 'name' matches the skill folder" "PASS" $detailText
} else {
    Add-Result "skill 'name' matches the skill folder" "FAIL" (($mismatchDetail -join "; ") + " [" + $detailText + "]")
}
if ($leafOnlyMatches.Count -gt 0) {
    Add-Result "nested skills use <parent>-<leaf> naming (superpowers convention)" "WARN" (($leafOnlyMatches | ForEach-Object { $_.RelativeDir + " -> " + $_.Name }) -join "; ")
} else {
    Add-Result "nested skills use <parent>-<leaf> naming (superpowers convention)" "PASS" ($canonicalMatches.Count.ToString() + " skill(s) use relative-path naming")
}
Write-Host ""

Write-Host "-- Check 7: skill name uniqueness --"
$skillNames = @($skills | ForEach-Object { $_.Name })
$duplicateSkillNames = @($skillNames | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name + " x" + $_.Count })
if ($duplicateSkillNames.Count -eq 0) {
    Add-Result "skill names are unique" "PASS" ($skillNames.Count.ToString() + " distinct name(s)")
} else {
    Add-Result "skill names are unique" "FAIL" ($duplicateSkillNames -join ", ")
}
Write-Host ""

Write-Host "-- Check 8: skills visible to the runtime (opencode debug skill) --"
$skillResult = Invoke-OpenCodeJson -Arguments @("debug", "skill")
$runtimeSkillNames = @()
if ($skillResult.ExitCode -eq 0 -and $null -ne $skillResult.Json) {
    $runtimeSkillNames = @($skillResult.Json | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    Add-Result "opencode debug skill exits 0 and lists skills" "PASS" ($runtimeSkillNames.Count.ToString() + " runtime skill(s)")
} else {
    Add-Result "opencode debug skill exits 0 and lists skills" "FAIL" ("exit=" + $skillResult.ExitCode)
}
$missingSkills = @($skillNames | Where-Object { $runtimeSkillNames -notcontains $_ })
if ($skillNames.Count -gt 0 -and $missingSkills.Count -eq 0) {
    Add-Result "every file-based skill is visible in the runtime" "PASS" ($skillNames.Count.ToString() + "/" + $skillNames.Count + " visible")
} elseif ($missingSkills.Count -gt 0) {
    Add-Result "every file-based skill is visible in the runtime" "FAIL" ("not in runtime: " + ($missingSkills -join ", "))
}
$runtimeOnlySkills = @($runtimeSkillNames | Where-Object { $skillNames -notcontains $_ })
if ($runtimeOnlySkills.Count -gt 0) {
    Add-Result "runtime-only skills (built-in / external)" "WARN" ($runtimeOnlySkills -join ", ")
}
Write-Host ""

Write-Host "-- Check 9: required_skills references --"
$references = New-Object System.Collections.ArrayList
foreach ($registryPath in @($LegacyRegistry, $ProjectRegistry)) {
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { continue }
    $registryJson = $null
    try {
        $registryJson = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Add-Result ("registry parse: " + (Split-Path -Leaf $registryPath)) "FAIL" $_.Exception.Message
        continue
    }
    $fileReferences = Get-SkillReference -Node $registryJson
    foreach ($reference in $fileReferences) {
        [void]$references.Add([pscustomobject]@{
            File  = Split-Path -Leaf $registryPath
            Owner = $reference.Owner
            Skill = $reference.Skill
        })
    }
}
if ($references.Count -eq 0) {
    Add-Result "required_skills point to existing skills" "SKIP" "no required_skills/skills field found in registry.json or agent-hq.json"
} else {
    $knownSkillNames = @($skillNames + $runtimeSkillNames | Sort-Object -Unique)
    $danglingReferences = @($references | Where-Object { $knownSkillNames -notcontains $_.Skill })
    if ($danglingReferences.Count -eq 0) {
        Add-Result "required_skills point to existing skills" "PASS" ($references.Count.ToString() + " reference(s) resolved against " + $knownSkillNames.Count + " known skill(s)")
    } else {
        $groups = @($danglingReferences | Group-Object -Property Skill | Sort-Object Name)
        $details = @()
        foreach ($group in $groups) {
            $owners = @($group.Group | ForEach-Object { $_.Owner } | Sort-Object -Unique)
            $details += ($group.Name + " <- " + ($owners -join ", "))
        }
        Add-Result "required_skills point to existing skills" "FAIL" ($danglingReferences.Count.ToString() + " dangling reference(s) in " + (($danglingReferences | ForEach-Object { $_.File } | Sort-Object -Unique) -join "/") + ": " + ($details -join "; "))
    }
    Add-Result "required_skills references found" "PASS" ($references.Count.ToString() + " reference(s) in " + (($references | ForEach-Object { $_.File } | Sort-Object -Unique) -join ", "))
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: PASS=" + $script:CountPass + " FAIL=" + $script:CountFail + " SKIP=" + $script:CountSkip + " WARN=" + $script:CountWarn)
if ($script:CountFail -gt 0) {
    Write-Host "RESULT : FAIL"
} else {
    Write-Host "RESULT : PASS"
}
Write-Host "=================================================="

if ($script:CountFail -gt 0) { exit 1 } else { exit 0 }
