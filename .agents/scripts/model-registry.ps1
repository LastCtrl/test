# model-registry.ps1 - free-model registry: discovery, live probe, scoring (R1).
# Discovery source 1: openrouter /api/v1/models; free = pricing.prompt==0 and pricing.completion==0.
# Discovery source 2 (R-1): opencode-go free models read dynamically from the local
#   opencode models cache; probe endpoint https://opencode.ai/zen/go/v1/chat/completions.
# Probe: POST /chat/completions ("Reply with exactly: PONG"), classified OK|RATE_LIMIT|DEAD|TIMEOUT.
# Registry ids are provider-qualified: openrouter/<id> and opencode-go/<id>.
# State: .memory/model-registry.json (TTL 60 min for OK, unless -Force).
# Composite score: W_AVAILABILITY*availability + W_SPEED*speed + W_QUALITY*quality
#                  + W_TASK_FIT*task_fit - W_INSTABILITY*instability.
# Weights are the constants below. API keys: env OPENROUTER_API_KEY and
# env OPENCODE_API_KEY, never printed and never passed in the process command line
# (curl --config header file).

[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$Force,
    [switch]$List,
    [ValidateSet("score", "speed", "availability", "quality")]
    [string]$Sort = "score",
    [switch]$FreeOnly,
    [switch]$Json,
    [int]$Top = 0,
    [string]$TaskType = "",
    [switch]$Score,
    [int]$MaxProbe = 15,
    [int]$TimeoutSec = 25,
    [string]$Root = ""
)

$script:RegistryFileName    = "model-registry.json"
$script:RatingsFileName     = "ratings.jsonl"
$script:ModelsUrl           = "https://openrouter.ai/api/v1/models"
$script:ChatUrl             = "https://openrouter.ai/api/v1/chat/completions"
$script:ProbePrompt         = "Reply with exactly: PONG"
$script:DefaultMaxProbe     = 15
$script:DefaultTimeoutSec   = 25
$script:DownloadTimeoutSec  = 45
$script:TtlMinutes          = 60
$script:CooldownMinutes     = 15
$script:FailThreshold       = 2
$script:IntervalMinSec      = 1
$script:IntervalMaxSec      = 2
$script:SpeedRefMs          = 30000.0

# Second discovery source (R-1): opencode-go free models are read dynamically from
# the opencode models cache, never hardcoded. The probe uses the same endpoint and
# headers as the gateway "free" alias; the x-opencode-session header is required.
$script:OpenCodeGoModelsCache = ".cache\opencode\models.json"
$script:OpenCodeGoProvider    = "opencode-go"
$script:OpenCodeGoChatUrl     = "https://opencode.ai/zen/go/v1/chat/completions"
$script:OpenCodeGoSession     = "agent-hq-registry"
$script:OpenRouterProvider    = "openrouter"
$script:OpenRouterPrefix      = "openrouter/"
$script:OpenCodeGoPrefix      = "opencode-go/"

# Composite score weights (documented; change here only).
$script:WAvailability = 0.30
$script:WSpeed        = 0.25
$script:WQuality      = 0.25
$script:WTaskFit      = 0.20
$script:WInstability  = 0.40

# Task-fit keyword heuristics (model id, lowercase substring). Base 0.5, match -> 0.8.
$script:TaskFitKeywords = @{
    code     = @("deepseek", "qwen", "coder", "code", "glm", "ling")
    review   = @("nemotron", "pickle", "qwen", "deepseek", "glm")
    qa       = @("mimo", "ling", "lightning", "nemotron", "flash")
    analysis = @("inkling", "thinking", "nemotron", "dots", "laguna")
}

# ===========================================================================
# Paths and timestamps (PowerShell 5.1 safe)
# ===========================================================================

function Get-RegistryRoot {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_HQ_ROOT)) { return $env:AGENT_HQ_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    }
    return (Get-Location).Path
}

function Get-RegistryPath {
    param([string]$Root)
    return (Join-Path (Get-RegistryRoot -Root $Root) (".memory\" + $script:RegistryFileName))
}

function Get-RatingsPath {
    param([string]$Root)
    return (Join-Path (Get-RegistryRoot -Root $Root) (".memory\" + $script:RatingsFileName))
}

function Format-RegistryTimestamp {
    param([datetime]$Value)
    return $Value.ToString("yyyy-MM-ddTHH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-RegistryDate {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Text.Trim(),
        "yyyy-MM-ddTHH:mm:ss",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed)
    if ($ok) { return $parsed }
    return $null
}

# ===========================================================================
# Registry state (.memory/model-registry.json)
# ===========================================================================

function Read-RegistryDocument {
    param([string]$Root)
    $doc = [ordered]@{ generated_at = ""; models = [ordered]@{} }
    $path = Get-RegistryPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $doc }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $doc }
        $json = $raw | ConvertFrom-Json
        if ($null -ne $json.generated_at) { $doc.generated_at = [string]$json.generated_at }
        if ($null -ne $json.models) {
            foreach ($property in @($json.models.PSObject.Properties)) {
                $doc.models[$property.Name] = $property.Value
            }
        }
    } catch {
        Write-Warning "model-registry.json is unreadable ($path): $($_.Exception.Message) - starting empty"
        $doc = [ordered]@{ generated_at = ""; models = [ordered]@{} }
    }
    return $doc
}

# Atomic swap: sibling temp file then Replace/Move, so readers never see half a file.
function Save-RegistryDocument {
    param([hashtable]$Models, [string]$GeneratedAt, [string]$Root)
    $path = Get-RegistryPath -Root $Root
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $doc = [ordered]@{ generated_at = $GeneratedAt; models = $Models }
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tmpPath = Join-Path $dir ("." + (Split-Path -Leaf $path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = $path + ".bak." + [guid]::NewGuid().ToString("N")
    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        $swapped = $false
        foreach ($attempt in 1..5) {
            try {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    [System.IO.File]::Replace($tmpPath, $path, $backupPath)
                } else {
                    [System.IO.File]::Move($tmpPath, $path)
                }
                $swapped = $true
                break
            } catch {
                if ($attempt -eq 5) {
                    Write-Warning "cannot swap in model-registry ${path}: $($_.Exception.Message)"
                } else {
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        if (-not $swapped) {
            [System.IO.File]::WriteAllText($path, $json, $encoding)
        }
    } finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

# ===========================================================================
# Ratings (.memory/ratings.jsonl) -> average grade per model
# ===========================================================================

function Read-RatingsQuality {
    param([string]$Root)
    $map = @{}
    $path = Get-RatingsPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $sum = @{}
    $count = @{}
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $record = $null
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($null -eq $record) { continue }
            $model = [string]$record.model
            if ([string]::IsNullOrWhiteSpace($model)) { continue }
            if ($null -eq $record.grade) { continue }
            $grade = 0.0
            if (-not [double]::TryParse([string]$record.grade, [ref]$grade)) { continue }
            if (-not $sum.ContainsKey($model)) { $sum[$model] = 0.0; $count[$model] = 0 }
            $sum[$model] = $sum[$model] + $grade
            $count[$model] = $count[$model] + 1
        }
    } catch {
        Write-Warning "ratings.jsonl unreadable: $($_.Exception.Message)"
    }
    foreach ($model in $sum.Keys) {
        if ($count[$model] -gt 0) { $map[$model] = [math]::Round($sum[$model] / $count[$model], 2) }
    }
    return $map
}

# ===========================================================================
# Discovery (openrouter /api/v1/models)
# ===========================================================================

function Get-FreeModelList {
    param([int]$TimeoutSec)
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:DownloadTimeoutSec }
    $tmp = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $http = & curl.exe -s -S --max-time $TimeoutSec -w "%{http_code}" -o $tmp $script:ModelsUrl 2>$err
        $exit = $LASTEXITCODE
        $code = 0
        [void][int]::TryParse(([string]$http).Trim(), [ref]$code)
        if ($exit -ne 0 -or $code -ne 200) {
            $detail = ""
            if (Test-Path -LiteralPath $err) { $detail = [System.IO.File]::ReadAllText($err, [System.Text.Encoding]::UTF8) }
            throw "models download failed (curl exit $exit, http $code): $detail"
        }
        $raw = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "models response is empty" }
        $json = $raw | ConvertFrom-Json
        $result = New-Object System.Collections.ArrayList
        foreach ($item in @($json.data)) {
            if ($null -eq $item) { continue }
            $pricePrompt = ""
            $priceCompletion = ""
            if ($null -ne $item.pricing) {
                if ($null -ne $item.pricing.prompt) { $pricePrompt = [string]$item.pricing.prompt }
                if ($null -ne $item.pricing.completion) { $priceCompletion = [string]$item.pricing.completion }
            }
            if (($pricePrompt -eq "0") -and ($priceCompletion -eq "0")) {
                $id = [string]$item.id
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                $name = [string]$item.name
                if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
                $context = 0
                if ($null -ne $item.context_length) { [void][int]::TryParse([string]$item.context_length, [ref]$context) }
                [void]$result.Add([pscustomobject]@{
                    id       = ($script:OpenRouterPrefix + $id)
                    raw_id   = $id
                    name     = $name
                    context  = $context
                    provider = $script:OpenRouterProvider
                })
            }
        }
        return $result.ToArray()
    } finally {
        foreach ($f in @($tmp, $err)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ===========================================================================
# Discovery (opencode-go free models from the local models cache)
# ===========================================================================

function Get-OpenCodeGoModelsPath {
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($homePath)) { return "" }
    return (Join-Path $homePath $script:OpenCodeGoModelsCache)
}

# Reads the opencode models cache and returns every "opencode-go" model whose key
# ends with "-free". The list is dynamic: whatever the cache declares is used, so
# a changed free set needs no code change. Any failure (missing cache, bad JSON,
# absent provider) yields an empty list and a warning - the other source is
# unaffected. IDs are normalised to "<provider>/<raw>".
function Get-OpenCodeGoFreeModelList {
    $result = New-Object System.Collections.ArrayList
    $path = Get-OpenCodeGoModelsPath
    if ([string]::IsNullOrWhiteSpace($path) -or (-not (Test-Path -LiteralPath $path -PathType Leaf))) {
        Write-Warning "opencode-go discovery skipped: models cache not found ($path)"
        return $result.ToArray()
    }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "models cache is empty" }
        $json = $raw | ConvertFrom-Json
        $provider = $json.PSObject.Properties[$script:OpenCodeGoProvider]
        if ($null -eq $provider) { throw "provider '$($script:OpenCodeGoProvider)' is not present in the cache" }
        $providerModels = $provider.Value.models
        if ($null -eq $providerModels) { throw "provider '$($script:OpenCodeGoProvider)' declares no models" }
        foreach ($property in @($providerModels.PSObject.Properties)) {
            $key = [string]$property.Name
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if (-not $key.EndsWith("-free", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $item = $property.Value
            $name = $key
            if (($null -ne $item) -and ($null -ne $item.name) -and (-not [string]::IsNullOrWhiteSpace([string]$item.name))) { $name = [string]$item.name }
            $context = 0
            if (($null -ne $item) -and ($null -ne $item.limit) -and ($null -ne $item.limit.context)) { [void][int]::TryParse([string]$item.limit.context, [ref]$context) }
            [void]$result.Add([pscustomobject]@{
                id       = ($script:OpenCodeGoPrefix + $key)
                raw_id   = $key
                name     = $name
                context  = $context
                provider = $script:OpenCodeGoProvider
            })
        }
    } catch {
        Write-Warning "opencode-go discovery failed: $($_.Exception.Message)"
        return $result.ToArray()
    }
    return $result.ToArray()
}

# ===========================================================================
# Live probe (curl, key via --config so it never appears in argv)
# ===========================================================================

function Get-ProbeStatus {
    param([int]$HttpCode, [string]$Body, [int]$ExitCode, [bool]$TimedOut)
    if ($TimedOut) { return "TIMEOUT" }
    $text = [string]$Body
    if ($HttpCode -eq 429) { return "RATE_LIMIT" }
    if ($text -match '(?i)rate limit|rate_limit|too many requests|quota exceeded|\b429\b') { return "RATE_LIMIT" }
    if ($HttpCode -eq 200) {
        if ($text -match '(?i)"error"') { return "DEAD" }
        return "OK"
    }
    if (($HttpCode -eq 0) -and ($ExitCode -eq 28)) { return "TIMEOUT" }
    return "DEAD"
}

function Invoke-ModelProbe {
    param([string]$Model, [string]$ApiKey, [int]$TimeoutSec, [string]$Url = "", [string]$Provider = "openrouter")
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:DefaultTimeoutSec }
    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = $script:ChatUrl }
    $bodyFile = [System.IO.Path]::GetTempFileName()
    $outFile = [System.IO.Path]::GetTempFileName()
    $cfgFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $body = '{"model":"' + $Model + '","messages":[{"role":"user","content":"' + $script:ProbePrompt + '"}],"max_tokens":8}'
        [System.IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))
        # curl --config keeps the bearer token out of the process command line. The
        # opencode-go endpoint additionally requires the x-opencode-session header.
        $headerLines = New-Object System.Collections.ArrayList
        [void]$headerLines.Add('header = "Authorization: Bearer ' + $ApiKey + '"')
        if ($Provider -eq $script:OpenCodeGoProvider) {
            [void]$headerLines.Add('header = "x-opencode-session: ' + $script:OpenCodeGoSession + '"')
        }
        [System.IO.File]::WriteAllText($cfgFile, ($headerLines -join ([Environment]::NewLine)), (New-Object System.Text.UTF8Encoding($false)))

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $http = & curl.exe -s -S --max-time $TimeoutSec --config $cfgFile -w "%{http_code}" -o $outFile -X POST $Url -H "Content-Type: application/json" --data-binary ("@" + $bodyFile) 2>$errFile
        $sw.Stop()
        $exit = $LASTEXITCODE

        $bodyText = ""
        if (Test-Path -LiteralPath $outFile) { $bodyText = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) }
        $errText = ""
        if (Test-Path -LiteralPath $errFile) { $errText = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) }
        $httpCode = 0
        [void][int]::TryParse(([string]$http).Trim(), [ref]$httpCode)
        $timedOut = ($exit -eq 28)
        $status = Get-ProbeStatus -HttpCode $httpCode -Body ($bodyText + " " + $errText) -ExitCode $exit -TimedOut $timedOut
        return [pscustomobject]@{
            status     = $status
            latency_ms = [int]$sw.ElapsedMilliseconds
            http_code  = $httpCode
            exit_code  = $exit
            timed_out  = $timedOut
        }
    } finally {
        foreach ($f in @($bodyFile, $outFile, $cfgFile, $errFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ===========================================================================
# Scoring
# ===========================================================================

function Get-AvailabilityScore {
    param([string]$Status)
    switch ($Status) {
        "OK"         { return 1.0 }
        "RATE_LIMIT" { return 0.4 }
        "TIMEOUT"    { return 0.1 }
        "DEAD"       { return 0.0 }
        default      { return 0.3 }
    }
}

function Get-AvailabilityRank {
    param([string]$Status)
    switch ($Status) {
        "OK"         { return 4 }
        "RATE_LIMIT" { return 3 }
        "TIMEOUT"    { return 1 }
        "DEAD"       { return 0 }
        default      { return 2 }
    }
}

function Get-SpeedScore {
    param($LatencyMs)
    if ($null -eq $LatencyMs) { return 0.3 }
    $value = 1.0 - ([double]$LatencyMs / $script:SpeedRefMs)
    if ($value -lt 0.0) { $value = 0.0 }
    if ($value -gt 1.0) { $value = 1.0 }
    return $value
}

function Get-QualityScore {
    param($Quality)
    if ($null -eq $Quality) { return 0.5 }
    $value = [double]$Quality / 10.0
    if ($value -lt 0.0) { $value = 0.0 }
    if ($value -gt 1.0) { $value = 1.0 }
    return $value
}

function Get-TaskFitScore {
    param([string]$Model, [string]$TaskType)
    if ([string]::IsNullOrWhiteSpace($TaskType)) { return 0.5 }
    if (-not $script:TaskFitKeywords.ContainsKey($TaskType)) { return 0.5 }
    $id = ([string]$Model).ToLowerInvariant()
    foreach ($keyword in $script:TaskFitKeywords[$TaskType]) {
        if ($id.Contains($keyword)) { return 0.8 }
    }
    return 0.5
}

function Get-InstabilityScore {
    param($FailCount, [string]$UnstableUntil)
    $fail = 0.0
    if ($null -ne $FailCount) {
        $parsed = 0.0
        if ([double]::TryParse([string]$FailCount, [ref]$parsed)) { $fail = $parsed }
    }
    $value = $fail / [double]$script:FailThreshold
    $until = ConvertTo-RegistryDate -Text $UnstableUntil
    if (($null -ne $until) -and ($until -gt (Get-Date))) { $value = 1.0 }
    if ($value -lt 0.0) { $value = 0.0 }
    if ($value -gt 1.0) { $value = 1.0 }
    return $value
}

function Get-ModelScore {
    param($Entry, [string]$TaskType)
    $availability = Get-AvailabilityScore -Status ([string]$Entry.status)
    $speed = Get-SpeedScore -LatencyMs $Entry.latency_ms
    $quality = Get-QualityScore -Quality $Entry.quality
    $taskFit = Get-TaskFitScore -Model ([string]$Entry.id) -TaskType $TaskType
    $instability = Get-InstabilityScore -FailCount $Entry.fail_count -UnstableUntil ([string]$Entry.unstable_until)
    $total = ($script:WAvailability * $availability) +
             ($script:WSpeed * $speed) +
             ($script:WQuality * $quality) +
             ($script:WTaskFit * $taskFit) -
             ($script:WInstability * $instability)
    return [pscustomobject]@{
        score        = [math]::Round($total, 3)
        availability = [math]::Round($availability, 3)
        speed        = [math]::Round($speed, 3)
        quality      = [math]::Round($quality, 3)
        task_fit     = [math]::Round($taskFit, 3)
        instability  = [math]::Round($instability, 3)
    }
}

# ===========================================================================
# Refresh
# ===========================================================================

function New-RegistryEntry {
    param([string]$Id, [string]$RawId, [string]$Name, [int]$Context, $Quality, [string]$Provider)
    return [ordered]@{
        id            = $Id
        raw_id        = $RawId
        provider      = $Provider
        name          = $Name
        context       = $Context
        free          = $true
        probed_at     = ""
        status        = "unprobed"
        latency_ms    = $null
        fail_count    = 0
        unstable_until = ""
        quality       = $Quality
        speed         = $null
        task_fit      = $null
    }
}

function Invoke-RegistryRefresh {
    param([string]$Root, [bool]$Force, [int]$MaxProbe, [int]$TimeoutSec)
    if ($MaxProbe -le 0) { $MaxProbe = $script:DefaultMaxProbe }
    if ($TimeoutSec -le 0) { $TimeoutSec = $script:DefaultTimeoutSec }

    # Two independent sources. A missing key disables only its own source with a
    # warning, so e.g. an absent OPENCODE_API_KEY never blocks the openrouter run.
    $openRouterKey = $env:OPENROUTER_API_KEY
    $openCodeKey = $env:OPENCODE_API_KEY
    $haveOpenRouter = -not [string]::IsNullOrWhiteSpace($openRouterKey)
    $haveOpenCodeGo = -not [string]::IsNullOrWhiteSpace($openCodeKey)
    if ((-not $haveOpenRouter) -and (-not $haveOpenCodeGo)) {
        Write-Error "Neither OPENROUTER_API_KEY nor OPENCODE_API_KEY is set in this process environment (use the vault wrapper: get-secret ... -AsEnv ...). Nothing to probe."
        exit 2
    }
    if (-not $haveOpenRouter) {
        Write-Warning "OPENROUTER_API_KEY is not set - openrouter discovery/probe skipped"
    }
    if (-not $haveOpenCodeGo) {
        Write-Warning "OPENCODE_API_KEY is not set - opencode-go discovery/probe skipped (vault wrapper: get-secret opencode-api-key -AsEnv OPENCODE_API_KEY)"
    }

    # opencode-go first: its free models are the gateway "free" alias's first
    # candidates (R-1), so they win the probe cap over the larger openrouter set.
    $apiModels = New-Object System.Collections.ArrayList
    if ($haveOpenCodeGo) {
        foreach ($model in @(Get-OpenCodeGoFreeModelList)) { [void]$apiModels.Add($model) }
    }
    $openRouterError = ""
    if ($haveOpenRouter) {
        try {
            foreach ($model in @(Get-FreeModelList -TimeoutSec $script:DownloadTimeoutSec)) { [void]$apiModels.Add($model) }
        } catch {
            $openRouterError = $_.Exception.Message
            Write-Warning ("openrouter model discovery failed: " + $openRouterError)
        }
    }
    if ($apiModels.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($openRouterError)) {
            Write-Error ("model discovery failed: " + $openRouterError)
            exit 3
        }
        Write-Error "model discovery returned zero free models from the available source(s)"
        exit 3
    }

    # Per-provider endpoint and token, resolved once; every probe candidate carries
    # its own copy so the probe loop stays source-agnostic.
    $providerSettings = @{}
    $providerSettings[$script:OpenRouterProvider] = [pscustomobject]@{ url = $script:ChatUrl; key = $openRouterKey }
    $providerSettings[$script:OpenCodeGoProvider] = [pscustomobject]@{ url = $script:OpenCodeGoChatUrl; key = $openCodeKey }

    $qualityMap = Read-RatingsQuality -Root $Root
    $previous = Read-RegistryDocument -Root $Root
    $now = Get-Date

    $models = [ordered]@{}
    $candidates = New-Object System.Collections.ArrayList
    $freshCount = 0
    foreach ($api in $apiModels) {
        $id = [string]$api.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($models.Contains($id)) { continue }
        $rawId = [string]$api.raw_id
        if ([string]::IsNullOrWhiteSpace($rawId)) { $rawId = $id }
        $provider = [string]$api.provider

        $quality = $null
        if ($qualityMap.ContainsKey($id)) { $quality = $qualityMap[$id] }
        elseif ($qualityMap.ContainsKey($rawId)) { $quality = $qualityMap[$rawId] }
        $entry = New-RegistryEntry -Id $id -RawId $rawId -Name ([string]$api.name) -Context ([int]$api.context) -Quality $quality -Provider $provider

        # Migration: a pre-R-1 document keys openrouter entries by their bare id;
        # either key is accepted so cached status/latency/quality survive the switch.
        $old = $null
        if ($previous.models.Contains($id)) { $old = $previous.models[$id] }
        elseif ($previous.models.Contains($rawId)) { $old = $previous.models[$rawId] }
        if ($null -ne $old) {
            if ($null -ne $old.probed_at) { $entry.probed_at = [string]$old.probed_at }
            if ($null -ne $old.status) { $entry.status = [string]$old.status }
            if ($null -ne $old.latency_ms) { $entry.latency_ms = $old.latency_ms }
            $fail = 0
            if ($null -ne $old.fail_count) { [void][int]::TryParse([string]$old.fail_count, [ref]$fail) }
            $entry.fail_count = $fail
            if ($null -ne $old.unstable_until) { $entry.unstable_until = [string]$old.unstable_until }
        }

        $fresh = $false
        if ((-not $Force) -and ($entry.status -eq "OK")) {
            $probedAt = ConvertTo-RegistryDate -Text ([string]$entry.probed_at)
            if (($null -ne $probedAt) -and (((($now - $probedAt).TotalMinutes) -lt $script:TtlMinutes))) { $fresh = $true }
        }
        if ($fresh) {
            $freshCount++
        } else {
            $settings = $null
            if ($providerSettings.ContainsKey($provider)) { $settings = $providerSettings[$provider] }
            if (($null -ne $settings) -and (-not [string]::IsNullOrWhiteSpace([string]$settings.key))) {
                [void]$candidates.Add([pscustomobject]@{
                    id       = $id
                    raw_id   = $rawId
                    provider = $provider
                    url      = [string]$settings.url
                    key      = [string]$settings.key
                })
            }
        }
        $models[$id] = $entry
    }

    $probeList = @($candidates | Select-Object -First $MaxProbe)
    $deferred = $candidates.Count - $probeList.Count
    $probedCount = 0
    $okCount = 0
    $rateLimited = 0
    $dead = 0
    $timedOut = 0

    foreach ($candidate in $probeList) {
        if ($probedCount -gt 0) {
            Start-Sleep -Seconds (Get-Random -Minimum $script:IntervalMinSec -Maximum ($script:IntervalMaxSec + 1))
        }
        $result = Invoke-ModelProbe -Model $candidate.raw_id -ApiKey $candidate.key -TimeoutSec $TimeoutSec -Url $candidate.url -Provider $candidate.provider
        $entry = $models[$candidate.id]
        $entry.probed_at = Format-RegistryTimestamp -Value (Get-Date)
        $entry.status = $result.status
        $entry.latency_ms = $result.latency_ms

        $previousUntil = ConvertTo-RegistryDate -Text ([string]$entry.unstable_until)
        if (($null -ne $previousUntil) -and ($previousUntil -le (Get-Date))) { $entry.fail_count = 0; $entry.unstable_until = "" }

        if ($result.status -eq "OK") {
            $entry.fail_count = 0
            $entry.unstable_until = ""
            $okCount++
        } else {
            $entry.fail_count = [int]$entry.fail_count + 1
            if ($entry.fail_count -ge $script:FailThreshold) {
                $entry.unstable_until = Format-RegistryTimestamp -Value ((Get-Date).AddMinutes($script:CooldownMinutes))
            }
            if ($result.status -eq "RATE_LIMIT") { $rateLimited++ }
            elseif ($result.status -eq "TIMEOUT") { $timedOut++ }
            else { $dead++ }
        }
        $probedCount++
    }

    $generatedAt = Format-RegistryTimestamp -Value (Get-Date)
    $path = Save-RegistryDocument -Models $models -GeneratedAt $generatedAt -Root $Root

    return [pscustomobject]@{
        path          = $path
        total_free    = $models.Count
        probed        = $probedCount
        fresh_cached  = $freshCount
        deferred      = $deferred
        ok            = $okCount
        rate_limited  = $rateLimited
        dead          = $dead
        timed_out     = $timedOut
        generated_at  = $generatedAt
    }
}

# ===========================================================================
# List / score
# ===========================================================================

function Get-RegistryRows {
    param([string]$Root, [string]$TaskType)
    $doc = Read-RegistryDocument -Root $Root
    $rows = New-Object System.Collections.ArrayList
    foreach ($key in @($doc.models.Keys | Sort-Object)) {
        $entry = $doc.models[$key]
        $id = [string]$key
        if ($null -ne $entry.id) { $id = [string]$entry.id }
        $context = 0
        if ($null -ne $entry.context) { [void][int]::TryParse([string]$entry.context, [ref]$context) }
        $latency = $null
        if (($null -ne $entry.latency_ms) -and ([string]$entry.latency_ms) -ne "") { [void][int]::TryParse([string]$entry.latency_ms, [ref]$latency) }
        $quality = $null
        if ($null -ne $entry.quality) {
            $parsedQuality = 0.0
            if ([double]::TryParse([string]$entry.quality, [ref]$parsedQuality)) { $quality = $parsedQuality }
        }
        $metrics = Get-ModelScore -Entry $entry -TaskType $TaskType
        [void]$rows.Add([pscustomobject]@{
            id            = $id
            provider      = [string]$entry.provider
            name          = [string]$entry.name
            status        = [string]$entry.status
            free          = [bool]$entry.free
            latency_ms    = $latency
            context       = $context
            quality       = $quality
            probed_at     = [string]$entry.probed_at
            fail_count    = $entry.fail_count
            unstable_until = [string]$entry.unstable_until
            score         = $metrics.score
            availability  = $metrics.availability
            speed         = $metrics.speed
            task_fit      = $metrics.task_fit
            instability   = $metrics.instability
        })
    }
    return $rows
}

function Sort-RegistryRows {
    param([object[]]$Rows, [string]$Sort)
    switch ($Sort) {
        "speed" {
            return @($Rows | Sort-Object @{ Expression = { if ($null -eq $_.latency_ms) { [int]::MaxValue } else { [int]$_.latency_ms } } }, @{ Expression = { $_.id } })
        }
        "availability" {
            return @($Rows | Sort-Object @{ Expression = { Get-AvailabilityRank -Status $_.status }; Descending = $true }, @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.id } })
        }
        "quality" {
            return @($Rows | Sort-Object @{ Expression = { if ($null -eq $_.quality) { -1.0 } else { [double]$_.quality } }; Descending = $true }, @{ Expression = { $_.id } })
        }
        default {
            return @($Rows | Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { if ($null -eq $_.latency_ms) { [int]::MaxValue } else { [int]$_.latency_ms } } }, @{ Expression = { $_.id } })
        }
    }
}

function Invoke-RegistryList {
    param([string]$Root, [string]$Sort, [bool]$FreeOnly, [bool]$Json, [int]$Top, [string]$TaskType, [bool]$WithComponents)
    $doc = Read-RegistryDocument -Root $Root
    if ($doc.models.Count -eq 0) {
        Write-Error "model-registry.json is empty or missing (run: model-registry.ps1 -Refresh)"
        exit 4
    }
    $rows = @(Get-RegistryRows -Root $Root -TaskType $TaskType)
    if ($FreeOnly) { $rows = @($rows | Where-Object { $_.free }) }
    $rows = @(Sort-RegistryRows -Rows $rows -Sort $Sort)
    if ($Top -gt 0) { $rows = @($rows | Select-Object -First $Top) }

    if ($Json) {
        $payload = New-Object System.Collections.ArrayList
        foreach ($row in $rows) {
            [void]$payload.Add([ordered]@{
                id           = $row.id
                provider     = $row.provider
                name         = $row.name
                status       = $row.status
                free         = $row.free
                latency_ms   = $row.latency_ms
                context      = $row.context
                quality      = $row.quality
                probed_at    = $row.probed_at
                fail_count   = $row.fail_count
                score        = $row.score
                availability = $row.availability
                speed        = $row.speed
                task_fit     = $row.task_fit
                instability  = $row.instability
            })
        }
        Write-Output (ConvertTo-Json -InputObject $payload.ToArray() -Depth 5)
        return
    }

    Write-Host ""
    Write-Host ("MODEL REGISTRY  (generated_at=" + [string]$doc.generated_at + ")") -ForegroundColor Cyan
    $table = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        $latencyText = "-"
        if ($null -ne $row.latency_ms) { $latencyText = ([string][int]$row.latency_ms) + "ms" }
        $qualityText = "-"
        if ($null -ne $row.quality) { $qualityText = ("{0:N2}" -f [double]$row.quality) }
        $item = [ordered]@{
            MODEL   = $row.id
            STATUS  = $row.status
            LATENCY = $latencyText
            CONTEXT = $row.context
            QUALITY = $qualityText
            SCORE   = ("{0:N3}" -f [double]$row.score)
        }
        if ($WithComponents) {
            $item["AVAIL"] = ("{0:N2}" -f [double]$row.availability)
            $item["SPEED"] = ("{0:N2}" -f [double]$row.speed)
            $item["FIT"] = ("{0:N2}" -f [double]$row.task_fit)
            $item["INSTAB"] = ("{0:N2}" -f [double]$row.instability)
        }
        [void]$table.Add([pscustomobject]$item)
    }
    $table | Format-Table -AutoSize
    Write-Host ("rows=" + $rows.Count + " sort=" + $Sort + $(if ([string]::IsNullOrWhiteSpace($TaskType)) { "" } else { " task_type=" + $TaskType }))
}

function Show-RegistryUsage {
    Write-Host ""
    Write-Host "model-registry.ps1 - free model registry (discovery, probe, score)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  -Refresh                    discover free models, probe, write .memory/model-registry.json"
    Write-Host "  -Force                      with -Refresh: ignore the 60 min OK cache"
    Write-Host "  -MaxProbe <n>               with -Refresh: probes per run (default 15)"
    Write-Host "  -TimeoutSec <n>             per-probe timeout (default 25)"
    Write-Host "  -List                       print the registry table"
    Write-Host "  -Sort score|speed|availability|quality   (default score)"
    Write-Host "  -FreeOnly                   keep free entries only"
    Write-Host "  -Top <n>                    limit rows"
    Write-Host "  -Json                       machine-readable output"
    Write-Host "  -Score -TaskType code|review|qa|analysis  composite score table"
    Write-Host ""
    Write-Host "Score weights: availability=$($script:WAvailability) speed=$($script:WSpeed) quality=$($script:WQuality) task_fit=$($script:WTaskFit) instability=$($script:WInstability)" -ForegroundColor DarkGray
    Write-Host ""
}

# ===========================================================================
# Entry point
# ===========================================================================

$script:RegistryRoot = Get-RegistryRoot -Root $Root

$script:ProxyModulePath = Join-Path $PSScriptRoot "proxy-mode.ps1"
if (Test-Path -LiteralPath $script:ProxyModulePath -PathType Leaf) {
    try {
        . $script:ProxyModulePath
        if (Get-Command Initialize-ProxyEnvironment -ErrorAction SilentlyContinue) {
            [void](Initialize-ProxyEnvironment -Root $script:RegistryRoot)
        }
    } catch {
        Write-Warning "proxy-mode.ps1 could not be loaded: $($_.Exception.Message)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {

if ($Refresh) {
    $summary = Invoke-RegistryRefresh -Root $script:RegistryRoot -Force:$Force -MaxProbe $MaxProbe -TimeoutSec $TimeoutSec
    Write-Host ""
    Write-Host "REFRESH SUMMARY" -ForegroundColor Cyan
    Write-Host ("  registry      : " + $summary.path)
    Write-Host ("  free models   : " + $summary.total_free)
    Write-Host ("  probed        : " + $summary.probed + " (fresh-cached: " + $summary.fresh_cached + ", deferred by cap: " + $summary.deferred + ")")
    Write-Host ("  OK            : " + $summary.ok)
    Write-Host ("  RATE_LIMIT    : " + $summary.rate_limited)
    Write-Host ("  TIMEOUT       : " + $summary.timed_out)
    Write-Host ("  DEAD          : " + $summary.dead)
    exit 0
}

if ($Score) {
    if ([string]::IsNullOrWhiteSpace($TaskType)) {
        Write-Host "-Score requires -TaskType code|review|qa|analysis" -ForegroundColor Red
        exit 1
    }
    if (@("code", "review", "qa", "analysis") -notcontains $TaskType) {
        Write-Host "-TaskType must be one of: code, review, qa, analysis" -ForegroundColor Red
        exit 1
    }
    Invoke-RegistryList -Root $script:RegistryRoot -Sort "score" -FreeOnly:$FreeOnly -Json:$Json -Top $Top -TaskType $TaskType -WithComponents $true
    exit 0
}

if ($List) {
    Invoke-RegistryList -Root $script:RegistryRoot -Sort $Sort -FreeOnly:$FreeOnly -Json:$Json -Top $Top -TaskType $TaskType -WithComponents $false
    exit 0
}

Show-RegistryUsage
exit 0

}
