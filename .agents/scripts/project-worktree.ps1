# project-worktree.ps1 - Per-project isolation boundary (P1-2).
#
# Provides: per-project git worktree (.agents\worktrees\<name> on branch
# project/<name>), the canonical per-project CONTEXT-BUFFER path, a filesystem
# boundary check and a guarded buffer writer that refuses cross-project writes.
#
# Dot-source compatible: it only DEFINES functions; it never calls exit and
# never emits output on its own. A CLI is available when invoked directly.
#
# Layout (root = $env:AGENT_HQ_ROOT or <repo>):
#   <root>\projects\<name>\CONTEXT-BUFFER.md   <- canonical project buffer
#   <root>\.agents\worktrees\<name>            <- project worktree (branch project/<name>)
#
# Naming: Test-ProjectName (below) is the single whitelist shared with
# create-project.ps1 / project-queue.ps1. It accepts Unicode letters (Cyrillic
# included), digits, '_', '-' and single spaces, while rejecting path traversal,
# Windows-invalid characters, reserved device names and trailing spaces/dots.
# Only a git ref name is transformed (a space there is percent-encoded as %20);
# the worktree path and the CONTEXT-BUFFER always keep the original name.

# NOTE: no top-level param() block on purpose. Dot-sourcing a script that
# declares parameters would bind (and reset) same-named variables in the
# caller's scope - project-queue.ps1 has $Project/$List of its own. The CLI is
# parsed manually from $args below instead.

$ProjectWorktreeScriptRoot = $PSScriptRoot
$IsProjectWorktreeDotSourced = ($MyInvocation.InvocationName -eq '.')

# ---------------------------------------------------------------------------
# Root resolution: explicit -Root wins, then $env:AGENT_HQ_ROOT, then this
# script's location (<root>\.agents\scripts), then the current directory.
# Resolved at call time so env changes after dot-sourcing are honoured.
# ---------------------------------------------------------------------------
function Get-ProjectIsolationRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }

    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }

    if (-not [string]::IsNullOrWhiteSpace($ProjectWorktreeScriptRoot)) {
        return (Split-Path (Split-Path $ProjectWorktreeScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

# --- Project-name validation (SINGLE source of truth) -----------------------
# Used by this helper, create-project.ps1 and project-queue.ps1 so the whitelist
# can never drift between the three entry points.
#
# Allowed : Unicode letters (\p{L} - Cyrillic/Latin/...), digits (\p{Nd}), '_',
#           '-' and single spaces (real repositories contain names that start
#           with a Cyrillic letter, e.g. "1c-centr1507" where the "c" is the
#           Cyrillic "es" - see tests/test-soak-5projects.ps1).
# Blocked : path separators and every Windows-invalid character (the char class
#           itself: / \ . : * ? " < > |), a leading space or dot, a trailing
#           space, '..' (path traversal), reserved device names
#           (CON/PRN/AUX/NUL/COM1..9/LPT1..9) and names longer than 63 chars.
#
# Test-ProjectName is a pure predicate (never throws) so callers can decide
# between exit 1 (CLI) and throw (queue helper). Pass [ref]$Reason to get a
# human-readable explanation.
$ProjectNamePattern = '^[\p{L}\p{Nd}](?:[\p{L}\p{Nd} _\-]{0,62})$'
$ProjectNameMaxLength = 63
$ReservedProjectNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

function Test-ProjectName {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProjectName,
        [ref]$Reason
    )

    if ($null -ne $Reason) { $Reason.Value = "" }

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        if ($null -ne $Reason) { $Reason.Value = "name is empty or whitespace" }
        return $false
    }
    if ($ProjectName.Length -gt $ProjectNameMaxLength) {
        if ($null -ne $Reason) { $Reason.Value = "name is longer than $ProjectNameMaxLength characters" }
        return $false
    }
    if ($ProjectName -notmatch $ProjectNamePattern) {
        if ($null -ne $Reason) {
            $Reason.Value = "only letters (any language), digits, '_', '-' and single spaces are allowed; " +
                "the name must start with a letter or a digit and must not contain / \ . : * ? "" < > |"
        }
        return $false
    }
    # The contract promises SINGLE spaces; the character class alone would also
    # accept "a  b", so consecutive spaces are rejected explicitly (the name may
    # not end with a space - checked below - and cannot start with one because of
    # the anchor, so a run of two spaces is the only remaining gap).
    if ($ProjectName.Contains('  ')) {
        if ($null -ne $Reason) { $Reason.Value = "only single spaces are allowed (consecutive spaces found)" }
        return $false
    }
    if ($ProjectName.Contains('..')) {
        if ($null -ne $Reason) { $Reason.Value = "'..' is not allowed (path traversal)" }
        return $false
    }
    if ($ProjectName.EndsWith(' ') -or $ProjectName.EndsWith('.')) {
        if ($null -ne $Reason) { $Reason.Value = "the name must not end with a space or a dot" }
        return $false
    }
    if ($ReservedProjectNames -contains $ProjectName.ToUpperInvariant()) {
        if ($null -ne $Reason) { $Reason.Value = "'$ProjectName' is a reserved Windows device name" }
        return $false
    }
    return $true
}

function Assert-ProjectName {
    param([Parameter(Mandatory = $true)][string]$ProjectName)
    $nameReason = ""
    if (-not (Test-ProjectName -ProjectName $ProjectName -Reason ([ref]$nameReason))) {
        throw "Invalid project name '$ProjectName': $nameReason"
    }
    return $true
}

# --- git invocation -----------------------------------------------------------

# Normalise a path for case-insensitive comparison (absolute, backslashes).
function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    try { return [System.IO.Path]::GetFullPath($Path.Trim().Trim('"')) } catch { return $Path.Trim() }
}

function Get-ProjectDir {
    param([string]$Project, [string]$Root)
    Assert-ProjectName -ProjectName $Project | Out-Null
    $base = Get-ProjectIsolationRoot -Root $Root
    $projectsRoot = Join-Path $base "projects"
    $full = [System.IO.Path]::GetFullPath((Join-Path $projectsRoot $Project))
    $boundary = [System.IO.Path]::GetFullPath($projectsRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path traversal detected: '$Project' escapes the projects root"
    }
    return $full
}

function Get-ProjectContextBufferPath {
    param([string]$Project, [string]$Root)
    return (Join-Path (Get-ProjectDir -Project $Project -Root $Root) "CONTEXT-BUFFER.md")
}

function Get-ProjectWorktreePath {
    param([string]$Project, [string]$Root)
    Assert-ProjectName -ProjectName $Project | Out-Null
    $base = Get-ProjectIsolationRoot -Root $Root
    $worktreesRoot = Join-Path $base ".agents\worktrees"
    $full = [System.IO.Path]::GetFullPath((Join-Path $worktreesRoot $Project))
    $boundary = [System.IO.Path]::GetFullPath($worktreesRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path traversal detected: '$Project' escapes the worktrees root"
    }
    return $full
}

# Branch for a project worktree. A git ref may not contain a space, so a space is
# percent-encoded as %20 (git rejects an unencoded space inside a ref name itself:
# measured exit code 128). '%' cannot appear in a project name (see
# Test-ProjectName), so the mapping is injective: two different projects can
# never end up sharing one branch. Names without spaces keep the historical
# "project/<name>" form verbatim (Cyrillic included), so existing branches and
# all current worktrees stay unchanged.
function Get-ProjectWorktreeBranch {
    param([string]$Project)

    if ($Project -notmatch '[^\p{L}\p{Nd}_\-]') {
        return ("project/" + $Project)
    }
    # Only a space can reach this branch (the whitelist rejects every other
    # character that git forbids in a ref), so encoding the space is enough.
    return ("project/" + $Project.Replace(' ', '%20'))
}

# True when $Path lives inside projects\<Project>\ or .agents\worktrees\<Project>\.
function Test-ProjectPathBoundary {
    param([string]$Project, [string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $full = Get-NormalizedPath -Path $Path
    $bases = @()
    try { $bases += (Get-ProjectDir -Project $Project -Root $Root) } catch { return $false }
    # The worktree path is a SECONDARY boundary: if it cannot be resolved (invalid
    # name / traversal) the projects\<name>\ boundary above has already decided the
    # answer, so the failure is swallowed on purpose - but it is traced instead of
    # being silently ignored.
    try {
        $bases += (Get-ProjectWorktreePath -Project $Project -Root $Root)
    } catch {
        Write-Verbose "project boundary: worktree path unavailable for '$Project': $($_.Exception.Message)"
    }

    foreach ($b in $bases) {
        $boundary = (Get-NormalizedPath -Path $b).TrimEnd('\') + '\'
        if ($full.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# A leak = a path that is claimed to belong to $Project but lies outside it.
function Test-ProjectContextLeak {
    param([string]$Project, [string]$Path, [string]$Root)
    return (-not (Test-ProjectPathBoundary -Project $Project -Path $Path -Root $Root))
}

# --- git helpers -----------------------------------------------------------

# Run a git command and capture BOTH stdout and stderr in ONE stream without
# letting the caller's $ErrorActionPreference turn git's stderr into a
# terminating error. On PowerShell 5.1 a native command that writes to stderr
# while EAP is 'Stop' raises a NativeCommandError - and git prints its progress
# ("Preparing worktree ...") to stderr even on SUCCESS. Because create-project.ps1
# sets $ErrorActionPreference='Stop' before dot-sourcing this helper, the former
# `& git ... 2>&1` made New-ProjectWorktree treat a SUCCESSFUL registration as a
# failure: mode='directory' plus a bogus "git worktree add failed" reason while
# the worktree really existed (BUG-025). The preference is lowered only for the
# duration of the call and restored afterwards.
# Returns { ExitCode; Output }; stderr lines are part of Output.
function Invoke-GitCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$GitArguments
    )

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @()
    $exitCode = 1
    try {
        $output = @(& git -C $Root @GitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output }
}

function Test-IsGitRepository {
    param([string]$Root)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = @(& git -C $Root rev-parse --is-inside-work-tree 2>$null)
        return ($LASTEXITCODE -eq 0 -and ($out -join "").Trim() -eq "true")
    } catch { return $false }
}

function Test-GitRepositoryHasHead {
    param([string]$Root)
    try {
        $null = & git -C $Root rev-parse --verify --quiet HEAD 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-GitBranchExists {
    param([string]$Root, [string]$Branch)
    try {
        $null = & git -C $Root show-ref --verify --quiet ("refs/heads/" + $Branch) 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Parse `git worktree list --porcelain` into { Path, Branch } objects.
# NOTE: for non-ASCII (Cyrillic) paths this listing is NOT reliable - PowerShell
# 5.1 decodes native-command stdout with the console code page, so the path comes
# back as mojibake. Registration is therefore resolved from the filesystem by
# Get-ProjectWorktreeRegistration (see Get-LinkedWorktreeInfo); this function is
# kept for diagnostics.
function Get-RepositoryWorktrees {
    param([string]$Root)
    $result = @()
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $result }

    try { $lines = @(& git -C $Root worktree list --porcelain 2>$null) } catch { return $result }
    if ($LASTEXITCODE -ne 0) { return $result }

    $currentPath = $null
    $currentBranch = ""
    foreach ($line in $lines) {
        if ($line -like "worktree *") {
            if ($currentPath) {
                $result += [PSCustomObject]@{ Path = $currentPath; Branch = $currentBranch }
            }
            $currentPath = $line.Substring(9).Trim()
            $currentBranch = ""
        } elseif ($line -like "branch *") {
            $currentBranch = ($line.Substring(7).Trim()) -replace '^refs/heads/', ''
        }
    }
    if ($currentPath) {
        $result += [PSCustomObject]@{ Path = $currentPath; Branch = $currentBranch }
    }
    return $result
}

# Read what a linked git worktree points at, straight from the filesystem:
#   <worktree>\.git  -> "gitdir: <repo>\.git\worktrees\<id>"
#   <id>\HEAD        -> "ref: refs/heads/<branch>"
# Both files are raw UTF-8, so a Cyrillic branch/path survives. This deliberately
# avoids parsing the stdout of `git worktree list`: PowerShell 5.1 decodes native
# command output with the console code page (cp866/cp1251 here), which turns a
# real Cyrillic path into mojibake and made the worktree look "not registered"
# (a bug caught by tests/test-soak-5projects.ps1).
function Get-LinkedWorktreeInfo {
    param([string]$WorktreePath)

    $info = [PSCustomObject]@{ linked = $false; git_dir = ""; branch = "" }
    $dotGit = Join-Path $WorktreePath ".git"
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return $info }

    $pointer = ""
    try { $pointer = [System.IO.File]::ReadAllText($dotGit, (New-Object System.Text.UTF8Encoding($false))) } catch { return $info }

    $pointerMatch = [regex]::Match($pointer, 'gitdir:\s*(\S.*)')
    if (-not $pointerMatch.Success) { return $info }

    $gitDir = $pointerMatch.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($gitDir)) { return $info }
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $WorktreePath $gitDir }
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) { return $info }

    $info.linked = $true
    $info.git_dir = [System.IO.Path]::GetFullPath($gitDir)

    $headFile = Join-Path $gitDir "HEAD"
    if (Test-Path -LiteralPath $headFile -PathType Leaf) {
        $head = ""
        try { $head = [System.IO.File]::ReadAllText($headFile, (New-Object System.Text.UTF8Encoding($false))) } catch { $head = "" }
        $headMatch = [regex]::Match($head.Trim(), '^ref:\s*refs/heads/(.+)$')
        if ($headMatch.Success) { $info.branch = $headMatch.Groups[1].Value.Trim() }
    }
    return $info
}

function Get-ProjectWorktreeRegistration {
    param([string]$Project, [string]$Root)
    $base = Get-ProjectIsolationRoot -Root $Root
    $path = Get-ProjectWorktreePath -Project $Project -Root $base
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }

    $info = Get-LinkedWorktreeInfo -WorktreePath $path
    if (-not $info.linked) { return $null }

    # It must be a worktree of THIS repository, not of some other checkout.
    $worktreesRoot = [System.IO.Path]::GetFullPath((Join-Path $base ".git\worktrees")).TrimEnd('\') + '\'
    if (-not (($info.git_dir.TrimEnd('\') + '\').StartsWith($worktreesRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
        return $null
    }
    return [PSCustomObject]@{ Path = $path; Branch = $info.branch }
}

# --- public API ------------------------------------------------------------

function Get-ProjectWorktree {
    param([string]$Project, [string]$Root)
    Assert-ProjectName -ProjectName $Project | Out-Null
    $base = Get-ProjectIsolationRoot -Root $Root
    $path = Get-ProjectWorktreePath -Project $Project -Root $base
    $branch = Get-ProjectWorktreeBranch -Project $Project
    $exists = Test-Path -LiteralPath $path -PathType Container
    $registration = $null
    if ($exists) { $registration = Get-ProjectWorktreeRegistration -Project $Project -Root $base }

    return [PSCustomObject]@{
        project           = $Project
        path              = $path
        branch            = $branch
        exists            = $exists
        registered        = ($null -ne $registration)
        registered_branch = if ($registration) { $registration.Branch } else { "" }
    }
}

function New-ProjectWorktree {
    param([string]$Project, [string]$Root)

    Assert-ProjectName -ProjectName $Project | Out-Null
    $base = Get-ProjectIsolationRoot -Root $Root
    $path = Get-ProjectWorktreePath -Project $Project -Root $base
    $branch = Get-ProjectWorktreeBranch -Project $Project

    $result = [PSCustomObject]@{
        project = $Project
        path    = $path
        branch  = $branch
        mode    = ""
        created = $false
        ok      = $false
        reason  = ""
    }

    # Idempotency: an existing worktree for this branch is a success.
    if (Test-Path -LiteralPath $path -PathType Container) {
        $registration = Get-ProjectWorktreeRegistration -Project $Project -Root $base
        if ($null -ne $registration) {
            if ($registration.Branch -ieq $branch) {
                $result.mode = "git-worktree"
                $result.ok = $true
                $result.reason = "already exists for branch '$branch' (idempotent)"
            } else {
                $result.reason = "path '$path' is a worktree of branch '$($registration.Branch)', not '$branch'"
            }
            return $result
        }
        # A plain directory (previous stub or unrelated folder): keep, never clobber.
        $result.mode = "directory"
        $result.ok = $true
        $result.reason = "directory already exists (idempotent, not a registered git worktree)"
        return $result
    }

    $parent = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $canUseGit = (Test-IsGitRepository -Root $base) -and (Test-GitRepositoryHasHead -Root $base)
    if ($canUseGit) {
        $branchExists = Test-GitBranchExists -Root $base -Branch $branch
        if ($branchExists) {
            $gitArgs = @('worktree', 'add', $path, $branch)
        } else {
            $gitArgs = @('worktree', 'add', '-b', $branch, $path)
        }
        # BUG-025: Invoke-GitCapture lowers $ErrorActionPreference for the call,
        # so git's stderr progress no longer looks like a terminating error when
        # the caller runs with EAP='Stop'.
        $gitRun = Invoke-GitCapture -Root $base -GitArguments $gitArgs
        $gitOutput = @($gitRun.Output)
        $exitCode = $gitRun.ExitCode
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $path -PathType Container)) {
            $result.mode = "git-worktree"
            $result.created = $true
            $result.ok = $true
            $result.reason = "created git worktree on branch '$branch'"
            return $result
        }
        $gitMessage = (($gitOutput | ForEach-Object { [string]$_ }) -join " ").Trim()
        if ([string]::IsNullOrWhiteSpace($gitMessage)) { $gitMessage = "git worktree add exit code $exitCode" }
        $result.reason = "git worktree add failed: $gitMessage"
    } else {
        $result.reason = "repository has no git HEAD; using a plain directory"
    }

    try {
        New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        $result.mode = "directory"
        $result.created = $true
        $result.ok = $true
    } catch {
        $result.ok = $false
        $result.reason = "failed to create worktree directory: $($_.Exception.Message)"
    }
    return $result
}

function Remove-ProjectWorktree {
    param([string]$Project, [string]$Root)

    Assert-ProjectName -ProjectName $Project | Out-Null
    $base = Get-ProjectIsolationRoot -Root $Root
    $path = Get-ProjectWorktreePath -Project $Project -Root $base
    $branch = Get-ProjectWorktreeBranch -Project $Project

    $result = [PSCustomObject]@{
        project = $Project
        path    = $path
        branch  = $branch
        removed = $false
        ok      = $false
        reason  = ""
    }

    if (-not (Test-Path -LiteralPath $path)) {
        $result.ok = $true
        $result.reason = "not present (idempotent)"
        return $result
    }

    $registration = Get-ProjectWorktreeRegistration -Project $Project -Root $base
    if ($null -ne $registration) {
        # BUG-025 class: run through Invoke-GitCapture so a caller with
        # $ErrorActionPreference='Stop' does not turn git's stderr into a
        # terminating error (the removal is best-effort either way).
        $null = Invoke-GitCapture -Root $base -GitArguments @('worktree', 'remove', '--force', $path)
        $null = Invoke-GitCapture -Root $base -GitArguments @('branch', '-D', $branch)
    }
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result.removed = -not (Test-Path -LiteralPath $path)
    $result.ok = $result.removed
    if ($result.removed) { $result.reason = "removed" } else { $result.reason = "path still present after removal" }
    return $result
}

# --- CONTEXT-BUFFER API ----------------------------------------------------

function Read-ProjectContextBuffer {
    param([string]$Project, [string]$Root)
    $path = Get-ProjectContextBufferPath -Project $Project -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
}

# Append to a project's buffer. Refuses cross-project writes and any target that
# falls outside the project boundary. Returns { ok, reason, path, bytes }.
function Write-ProjectContextBuffer {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [string]$SourceProject = "",
        [string]$Root,
        [switch]$AllowCrossProject
    )

    $result = [PSCustomObject]@{ ok = $false; reason = ""; path = ""; bytes = 0 }

    try { Assert-ProjectName -ProjectName $Project | Out-Null } catch {
        $result.reason = "invalid target project: $($_.Exception.Message)"
        return $result
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceProject)) {
        try { Assert-ProjectName -ProjectName $SourceProject | Out-Null } catch {
            $result.reason = "invalid source project: $($_.Exception.Message)"
            return $result
        }
        if (($SourceProject -ne $Project) -and (-not $AllowCrossProject)) {
            $result.reason = "cross-project write blocked: source '$SourceProject' != target '$Project'"
            return $result
        }
    }

    $path = Get-ProjectContextBufferPath -Project $Project -Root $Root
    if (-not (Test-ProjectPathBoundary -Project $Project -Path $path -Root $Root)) {
        $result.reason = "path boundary violation: '$path' is outside project '$Project'"
        return $result
    }
    $result.path = $path

    try {
        $dir = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $existing = ""
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $existing = [System.IO.File]::ReadAllText($path, $encoding)
            if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $existing += "`r`n" }
        }
        [System.IO.File]::WriteAllText($path, ($existing + $Content), $encoding)
    } catch {
        $result.reason = "write failed: $($_.Exception.Message)"
        return $result
    }

    $written = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
    $result.bytes = $written.Length
    if ($written.Contains($Content)) {
        $result.ok = $true
        $result.reason = "appended"
    } else {
        $result.reason = "write verification failed"
    }
    return $result
}

# --- CLI -------------------------------------------------------------------

if ($IsProjectWorktreeDotSourced) { return }

function Write-ProjectWorktreeJson {
    param([object]$Value)
    Write-Output ($Value | ConvertTo-Json -Depth 6 -Compress)
}

# Manual CLI parsing (no param block - see the note at the top of the file).
$CliProject = ""
$CliRoot = ""
$CliEnsure = $false
$CliGet = $false
$CliRemove = $false
$CliList = $false
for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]
    switch ($argument) {
        '-Ensure'  { $CliEnsure = $true }
        '-Get'     { $CliGet = $true }
        '-Remove'  { $CliRemove = $true }
        '-List'    { $CliList = $true }
        '-Project' { if (($index + 1) -lt $args.Count) { $index++; $CliProject = [string]$args[$index] } }
        '-Root'    { if (($index + 1) -lt $args.Count) { $index++; $CliRoot = [string]$args[$index] } }
        default    { }
    }
}

if ($CliList) {
    $base = Get-ProjectIsolationRoot -Root $CliRoot
    $projectsDir = Join-Path $base "projects"
    $items = @()
    if (Test-Path -LiteralPath $projectsDir -PathType Container) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue)) {
            try {
                $items += Get-ProjectWorktree -Project $dir.Name -Root $base
            } catch {
                # A directory whose name is not a valid project id (traversal,
                # reserved device name, ...) must not abort the whole listing.
                # Names with Cyrillic letters ARE valid and take the normal path.
                $items += [PSCustomObject]@{
                    project           = $dir.Name
                    path              = ""
                    branch            = ""
                    exists            = $false
                    registered        = $false
                    registered_branch = ""
                    error             = $_.Exception.Message
                }
            }
        }
    }
    Write-ProjectWorktreeJson -Value $items
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CliProject)) {
    Write-Output "Usage:"
    Write-Output "  project-worktree.ps1 -Ensure -Project <name> [-Root <path>]"
    Write-Output "  project-worktree.ps1 -Get    -Project <name> [-Root <path>]"
    Write-Output "  project-worktree.ps1 -Remove -Project <name> [-Root <path>]"
    Write-Output "  project-worktree.ps1 -List   [-Root <path>]"
    exit 1
}

if ($CliEnsure) {
    $wt = New-ProjectWorktree -Project $CliProject -Root $CliRoot
    Write-ProjectWorktreeJson -Value $wt
    if ($wt.ok) { exit 0 } else { exit 1 }
}

if ($CliGet) {
    Write-ProjectWorktreeJson -Value (Get-ProjectWorktree -Project $CliProject -Root $CliRoot)
    exit 0
}

if ($CliRemove) {
    $wt = Remove-ProjectWorktree -Project $CliProject -Root $CliRoot
    Write-ProjectWorktreeJson -Value $wt
    if ($wt.ok) { exit 0 } else { exit 1 }
}

Write-Output "No action specified. Use -Ensure, -Get, -Remove or -List."
exit 1
