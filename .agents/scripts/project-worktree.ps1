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

function Assert-ProjectName {
    param([Parameter(Mandatory = $true)][string]$ProjectName)
    if ($ProjectName -notmatch '^[a-zA-Z0-9_\-]+$') {
        throw "Invalid project name '$ProjectName': allowed chars are a-zA-Z0-9_-"
    }
    return $true
}

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

function Get-ProjectWorktreeBranch {
    param([string]$Project)
    return ("project/" + $Project)
}

# True when $Path lives inside projects\<Project>\ or .agents\worktrees\<Project>\.
function Test-ProjectPathBoundary {
    param([string]$Project, [string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $full = Get-NormalizedPath -Path $Path
    $bases = @()
    try { $bases += (Get-ProjectDir -Project $Project -Root $Root) } catch { return $false }
    try { $bases += (Get-ProjectWorktreePath -Project $Project -Root $Root) } catch { }

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

function Get-ProjectWorktreeRegistration {
    param([string]$Project, [string]$Root)
    $base = Get-ProjectIsolationRoot -Root $Root
    $path = Get-ProjectWorktreePath -Project $Project -Root $base
    $wanted = Get-NormalizedPath -Path $path
    $match = @(Get-RepositoryWorktrees -Root $base | Where-Object { (Get-NormalizedPath -Path $_.Path) -ieq $wanted })
    if ($match.Count -eq 0) { return $null }
    return $match[0]
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
            $gitArgs = @('-C', $base, 'worktree', 'add', $path, $branch)
        } else {
            $gitArgs = @('-C', $base, 'worktree', 'add', '-b', $branch, $path)
        }
        $gitOutput = @()
        $exitCode = 1
        try {
            $gitOutput = @(& git @gitArgs 2>&1)
            $exitCode = $LASTEXITCODE
        } catch {
            $gitOutput = @($_.Exception.Message)
            $exitCode = 1
        }
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
        $null = & git -C $base worktree remove --force $path 2>&1
        $null = & git -C $base branch -D $branch 2>&1
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
                # A legacy directory whose name is not a valid project id (e.g.
                # non-ASCII) must not abort the whole listing.
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
