# token-preflight.ps1 - read-only preflight: estimate prompt/context token size vs a limit.
# Usage: -Input '<text>' | -Files a,b | -Dir <path> [-Recurse]; -Json for machine output.
# Heuristic: tokens ~ chars / -CharsPerToken (default 4). Over limit -> recommend /compact.
# Exit: 0 ok, 2 warn (>= -WarnPercent), 3 over limit, 1 usage.
param(
    [switch]$Check,
    [Alias('Input')][string]$InputText = '',
    [string[]]$Files = @(),
    [string]$Dir = '',
    [switch]$Recurse,
    [int]$LimitTokens = 200000,
    [int]$CharsPerToken = 4,
    [int]$WarnPercent = 80,
    [int]$MaxFiles = 200,
    [int]$MaxReadBytes = 5242880,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

function Get-EstTokensFromChars {
    param([int]$Chars, [int]$CharsPerToken = 4)
    if ($CharsPerToken -lt 1) { $CharsPerToken = 4 }
    if ($Chars -le 0) { return 0 }
    return [int][math]::Ceiling([double]$Chars / [double]$CharsPerToken)
}

function Get-EstTokensFromText {
    param([string]$Text, [int]$CharsPerToken = 4)
    if ($null -eq $Text) { return 0 }
    return Get-EstTokensFromChars -Chars $Text.Length -CharsPerToken $CharsPerToken
}

function New-TokenMeasure {
    param([string]$Name, [string]$Kind, [string]$Status, [int]$Chars, [int]$CharsPerToken, [string]$Note = '')
    return [pscustomobject]@{
        name      = $Name
        kind      = $Kind
        status    = $Status
        chars     = [int]$Chars
        estTokens = (Get-EstTokensFromChars -Chars $Chars -CharsPerToken $CharsPerToken)
        note      = $Note
    }
}

function Measure-TokenFile {
    param([string]$Path, [int]$CharsPerToken = 4, [int]$MaxReadBytes = 5242880)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return New-TokenMeasure -Name '' -Kind 'file' -Status 'invalid' -Chars 0 -CharsPerToken $CharsPerToken -Note 'empty path'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-TokenMeasure -Name $Path -Kind 'file' -Status 'missing' -Chars 0 -CharsPerToken $CharsPerToken -Note 'not found'
    }
    try {
        $len = (Get-Item -LiteralPath $Path).Length
    } catch {
        return New-TokenMeasure -Name $Path -Kind 'file' -Status 'error' -Chars 0 -CharsPerToken $CharsPerToken -Note $_.Exception.Message
    }
    if ($MaxReadBytes -gt 0 -and $len -gt $MaxReadBytes) {
        return New-TokenMeasure -Name $Path -Kind 'file' -Status 'size-approx' -Chars ([int]$len) -CharsPerToken $CharsPerToken -Note 'measured by file size'
    }
    $raw = ''
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
    } catch {
        return New-TokenMeasure -Name $Path -Kind 'file' -Status 'error' -Chars 0 -CharsPerToken $CharsPerToken -Note $_.Exception.Message
    }
    if ($raw.IndexOf([char]0) -ge 0) {
        return New-TokenMeasure -Name $Path -Kind 'file' -Status 'binary' -Chars 0 -CharsPerToken $CharsPerToken -Note 'binary content ignored'
    }
    return New-TokenMeasure -Name $Path -Kind 'file' -Status 'ok' -Chars $raw.Length -CharsPerToken $CharsPerToken
}

function Get-TokenDirFiles {
    param([string]$Path, [switch]$Recurse, [int]$MaxFiles = 200)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    $found = @()
    try {
        if ($Recurse) {
            $found = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue)
        } else {
            $found = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)
        }
    } catch {
        $found = @()
    }
    if ($MaxFiles -gt 0 -and $found.Count -gt $MaxFiles) {
        $found = @($found | Select-Object -First $MaxFiles)
    }
    return @($found | ForEach-Object { $_.FullName })
}

if ($MyInvocation.InvocationName -ne '.') {

    if ($LimitTokens -lt 1) {
        Write-Host 'token-preflight: -LimitTokens must be >= 1'
        exit 1
    }
    if ($CharsPerToken -lt 1) { $CharsPerToken = 4 }
    if ($WarnPercent -lt 1 -or $WarnPercent -gt 100) { $WarnPercent = 80 }

    $items = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($InputText)) {
        $null = $items.Add((New-TokenMeasure -Name 'input' -Kind 'input' -Status 'ok' -Chars $InputText.Length -CharsPerToken $CharsPerToken))
    }
    foreach ($f in @($Files)) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        $null = $items.Add((Measure-TokenFile -Path $f -CharsPerToken $CharsPerToken -MaxReadBytes $MaxReadBytes))
    }
    foreach ($f in @(Get-TokenDirFiles -Path $Dir -Recurse:$Recurse -MaxFiles $MaxFiles)) {
        $null = $items.Add((Measure-TokenFile -Path $f -CharsPerToken $CharsPerToken -MaxReadBytes $MaxReadBytes))
    }

    $totalChars = 0
    foreach ($it in @($items)) {
        if ($it.status -eq 'ok' -or $it.status -eq 'size-approx') { $totalChars += [int]$it.chars }
    }
    $estTokens = Get-EstTokensFromChars -Chars $totalChars -CharsPerToken $CharsPerToken
    $percent = 0.0
    $percent = [math]::Round(100.0 * [double]$estTokens / [double]$LimitTokens, 1)

    $verdict = 'ok'
    if ($estTokens -gt $LimitTokens) {
        $verdict = 'over'
    } elseif ($percent -ge [double]$WarnPercent) {
        $verdict = 'warn'
    }
    $recommendation = ''
    if ($verdict -ne 'ok') { $recommendation = 'run /compact to shrink the context' }

    if ($Json) {
        $obj = [pscustomobject]@{
            generatedAt    = (Get-Date).ToString('o')
            limitTokens    = $LimitTokens
            charsPerToken  = $CharsPerToken
            warnPercent    = $WarnPercent
            totalChars     = $totalChars
            estTokens      = $estTokens
            percent        = $percent
            verdict        = $verdict
            recommendation = $recommendation
            items          = @($items)
        }
        Write-Output ($obj | ConvertTo-Json -Depth 6 -Compress)
    } else {
        Write-Host '=== token-preflight ==='
        foreach ($it in @($items)) {
            Write-Host ("  {0,-6} {1,-12} {2,10} chars {3,8} tok  {4}" -f $it.kind, $it.status, $it.chars, $it.estTokens, $it.name)
        }
        if ($items.Count -eq 0) { Write-Host '  (no input provided)' }
        Write-Host ("total   : {0} chars ~ {1} tokens / limit {2} ({3}%)" -f $totalChars, $estTokens, $LimitTokens, $percent)
        Write-Host ("verdict : {0}" -f $verdict)
        if ($recommendation) { Write-Host ("advice  : {0}" -f $recommendation) }
    }

    if ($verdict -eq 'over') { exit 3 }
    if ($verdict -eq 'warn') { exit 2 }
    exit 0
}
