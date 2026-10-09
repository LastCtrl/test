# resume-opencode.ps1 - compute what to resume in the interactive opencode TUI.
# Read-only: locates the newest opencode session (storage\session_diff), logs the
# recommended continue command and the files in flight. The TUI is NEVER started
# from here (no background/interactive processes per AGENTS.md 3.7); the printed
# command is a separate human-confirmed step.
# Exit: 0 found, 2 no session, 1 usage.
param(
    [string]$Root = '',
    [string]$DataDir = '',
    [string]$SessionId = '',
    [switch]$Json,
    [switch]$NoLog,
    [string]$LogFile = '',
    [int]$MaxFiles = 25
)

$ErrorActionPreference = 'Continue'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-ResumeRoot {
    param([string]$RootValue)
    if (-not [string]::IsNullOrWhiteSpace($RootValue)) { return $RootValue }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if ($PSScriptRoot) { return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) }
    return (Get-Location).Path
}

function Get-OpenCodeDataDir {
    param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_DATA)) { return $env:OPENCODE_DATA }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidate = Join-Path $env:USERPROFILE '.local\share\opencode'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA 'opencode')
    }
    return ''
}

function Get-LatestSessionDiff {
    param([string]$DiffDir, [string]$Wanted)
    $result = [ordered]@{ found = $false; path = ''; session_id = ''; modified = $null; size = 0; wanted = '' }
    if (-not (Test-Path -LiteralPath $DiffDir -PathType Container)) { return $result }
    $files = @(Get-ChildItem -LiteralPath $DiffDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $result }
    $chosen = $null
    if (-not [string]::IsNullOrWhiteSpace($Wanted)) {
        $result.wanted = $Wanted
        $name = $Wanted
        if (-not $name.EndsWith('.json')) { $name = $name + '.json' }
        foreach ($f in $files) { if ($f.Name -eq $name) { $chosen = $f; break } }
        # BUG-063: an explicit -SessionId must never fall back to the newest session.
        if ($null -eq $chosen) { return $result }
    }
    if ($null -eq $chosen) {
        $chosen = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($null -eq $chosen) { return $result }
    $result.found = $true
    $result.path = $chosen.FullName
    $result.session_id = [System.IO.Path]::GetFileNameWithoutExtension($chosen.Name)
    $result.modified = $chosen.LastWriteTime
    $result.size = $chosen.Length
    return $result
}

function Get-SessionTouchedFiles {
    param([string]$Path, [int]$Limit)
    $files = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $doc = $null
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return @() }
    foreach ($entry in @($doc)) {
        if ($null -eq $entry) { continue }
        $file = [string]$entry.file
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        if ($files -notcontains $file) { [void]$files.Add($file) }
        if ($files.Count -ge $Limit) { break }
    }
    return @($files)
}

function Write-ResumeLog {
    param([string]$Path, [string]$Line)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        [System.IO.File]::AppendAllText($Path, ((Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + ' ' + $Line + "`r`n"), $script:Utf8NoBom)
    } catch { }
}

if ($MyInvocation.InvocationName -ne '.') {

    # BUG-064: parameter validation -> usage exit 1 (as promised in the header).
    if ($MaxFiles -lt 1) {
        Write-Host ('resume-opencode: usage: -MaxFiles must be >= 1 (got ' + $MaxFiles + ')')
        exit 1
    }

    $rootValue = Get-ResumeRoot -RootValue $Root
    if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Join-Path $rootValue '.memory\traces\resume-opencode.log' }

    $dataDir = Get-OpenCodeDataDir -Value $DataDir
    if ([string]::IsNullOrWhiteSpace($dataDir) -or -not (Test-Path -LiteralPath $dataDir -PathType Container)) {
        Write-Host ('resume-opencode: opencode data dir not found: ' + $dataDir)
        exit 2
    }

    $diffDir = Join-Path $dataDir 'storage\session_diff'
    $latest = Get-LatestSessionDiff -DiffDir $diffDir -Wanted $SessionId
    if (-not $latest.found) {
        if (-not [string]::IsNullOrWhiteSpace($latest.wanted)) {
            Write-Host ('resume-opencode: session not found: ' + $latest.wanted)
        } else {
            Write-Host ('resume-opencode: no session diff found under ' + $diffDir)
        }
        exit 2
    }

    $touched = @(Get-SessionTouchedFiles -Path $latest.path -Limit $MaxFiles)
    $continueCommand = 'opencode --continue'
    $sessionCommand = 'opencode --session ' + $latest.session_id
    $modifiedText = ''
    if ($null -ne $latest.modified) { $modifiedText = ([datetime]$latest.modified).ToString('yyyy-MM-ddTHH:mm:ss') }

    if ($Json) {
        $payload = [ordered]@{
            session_id       = $latest.session_id
            diff_path        = $latest.path
            modified         = $modifiedText
            size_bytes       = $latest.size
            touched_files    = $touched
            touched_count    = $touched.Count
            continue_command = $continueCommand
            session_command  = $sessionCommand
            launch           = 'manual (TUI is never auto-started; run the command yourself)'
        }
        ($payload | ConvertTo-Json -Depth 5) | Write-Output
    } else {
        Write-Host '=== resume-opencode ==='
        Write-Host ('data dir   : ' + $dataDir)
        Write-Host ('session    : ' + $latest.session_id)
        Write-Host ('diff       : ' + $latest.path)
        Write-Host ('modified   : ' + $modifiedText + '  size=' + $latest.size + 'B')
        Write-Host ('files      : ' + $touched.Count)
        foreach ($f in $touched) { Write-Host ('  - ' + $f) }
        Write-Host ''
        Write-Host 'NEXT STEP (manual, confirmed by a human):'
        Write-Host ('  ' + $continueCommand + '        # continue the last session')
        Write-Host ('  ' + $sessionCommand + '   # continue this exact session')
    }

    if (-not $NoLog) {
        Write-ResumeLog -Path $LogFile -Line ('RESUME session=' + $latest.session_id + ' files=' + $touched.Count + ' cmd="' + $continueCommand + '" manual-only')
    }
    exit 0
}
