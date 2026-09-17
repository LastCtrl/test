# run-with-secrets.ps1 - Run a child command with vault secrets injected into its
# environment for the lifetime of that call only.
#
# A secret is NEVER printed, NEVER written to disk and NEVER passed in argv. It is
# decrypted by get-secret.ps1 and set as a process environment variable in THIS
# process right before the child starts, so the child inherits it. As soon as the
# child returns, the variable is restored to its previous value (or removed), so it
# cannot leak into a later command of the same host.
#
# Modes:
#   -List                 show the secret-name -> ENV-NAME mapping (no values)
#   -VerifyOnly           print SHA256 fingerprints (12 hex) and run nothing
#   (default / run)       inject -Secret into the environment and run -Command/-FilePath
#
# Examples:
#   run-with-secrets.ps1 -List
#   run-with-secrets.ps1 -VerifyOnly
#   run-with-secrets.ps1 -VerifyOnly -Secret tg-bot-token
#   run-with-secrets.ps1 -Secret tg-bot-token -FilePath python.exe -Args @('bridge.py','--once')
#   run-with-secrets.ps1 -Secret opencode-api-key -Command opencode -Args @('run')
#
# Exit codes: 0 = child succeeded; non-zero = child exit code; 2 = usage/setup error
# (in that case the child is NOT started).

param(
    # vault secret names (e.g. 'tg-bot-token' or 'tg-bot-token,github-token')
    [string[]]$Secret,

    # optional override of the secret-name -> ENV-NAME mapping
    [hashtable]$Map,

    # the command to run (name on PATH or full path); mutually exclusive with -FilePath
    [string]$Command,

    # the file to run; mutually exclusive with -Command
    [string]$FilePath,

    # arguments forwarded to the child as-is (never includes a secret value)
    [Alias('Args')]
    [string[]]$CommandArgs,

    # working directory for the child (defaults to the current one)
    [string]$WorkingDirectory,

    # show the mapping only
    [switch]$List,

    # verify secrets only (fingerprints), run nothing
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Continue'
$getSecret = Join-Path $PSScriptRoot 'get-secret.ps1'
$VaultDir  = if ($env:AGENT_HQ_SECRETS) { $env:AGENT_HQ_SECRETS } else { Join-Path $env:USERPROFILE '.agent-secrets' }

# --- default mapping: vault secret name -> environment variable of the child -------
# Keep in sync with AGENTS.md §11. Names not present here fall back to an upper-cased
# form with '-' replaced by '_' (tg-bot-token -> TG_BOT_TOKEN), unless -Map overrides.
$DefaultMap = [ordered]@{
    'opencode-api-key'    = 'OPENCODE_API_KEY'
    'aihubmix-api-key'    = 'AIHUBMIX_API_KEY'
    'openrouter-api-key'  = 'OPENROUTER_API_KEY'
    'groq-api-key'        = 'GROQ_API_KEY'
    'tokenrouter-api-key' = 'TOKENROUTER_API_KEY'
    'tg-bot-token'        = 'TG_TOKEN'
}

function Get-EnvName {
    param([string]$Name)
    if ($Map) {
        foreach ($k in @($Map.Keys)) {
            if ([string]::Equals([string]$k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$Map[$k]
            }
        }
    }
    foreach ($k in @($DefaultMap.Keys)) {
        if ([string]::Equals([string]$k, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$DefaultMap[$k]
        }
    }
    return ($Name.ToUpperInvariant() -replace '[^A-Za-z0-9]', '_')
}

function Test-EnvName {
    param([string]$EnvName, [string]$ForSecret)
    if ([string]::IsNullOrWhiteSpace($EnvName) -or $EnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Write-Host ("[secrets] ОШИБКА: для секрета '{0}' получено недопустимое имя переменной '{1}'." -f $ForSecret, $EnvName)
        return $false
    }
    return $true
}

function Get-VaultSecretNames {
    if (-not (Test-Path -LiteralPath $VaultDir -PathType Container)) { return @() }
    $names = @(Get-ChildItem -LiteralPath $VaultDir -Filter 'secret.*.enc' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name -replace '^secret\.', '' -replace '\.enc$', '' } |
        Sort-Object)
    return $names
}

if (-not (Test-Path -LiteralPath $getSecret -PathType Leaf)) {
    Write-Host ("[secrets] ОШИБКА: не найден get-secret.ps1 рядом со скриптом: {0}" -f $getSecret)
    exit 2
}

# --- mode: -List ------------------------------------------------------------------
if ($List) {
    $names = if ($Secret -and @($Secret).Count -gt 0) { @($Secret) } else { @($DefaultMap.Keys) }
    Write-Host '[secrets] Соответствие "имя секрета в vault -> переменная окружения":'
    foreach ($n in $names) {
        Write-Host ("  {0,-22} -> {1}" -f $n, (Get-EnvName $n))
    }
    exit 0
}

# --- mode: -VerifyOnly ------------------------------------------------------------
if ($VerifyOnly) {
    $names = @()
    if ($Secret) { $names = @($Secret) }
    if ($names.Count -eq 0) { $names = @(Get-VaultSecretNames) }
    if ($names.Count -eq 0) {
        Write-Host ("[secrets] В vault нет сохранённых секретов ({0})." -f $VaultDir)
        exit 0
    }
    $failed = 0
    foreach ($n in $names) {
        & $getSecret -Name $n -Verify
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -gt 0) {
        Write-Host ("[secrets] Не проверено секретов: {0}. Сохранение: set-secret.ps1 -Name <имя>" -f $failed)
        exit 1
    }
    exit 0
}

# --- mode: run --------------------------------------------------------------------
if (-not $Secret -or @($Secret).Count -eq 0) {
    Write-Host '[secrets] ОШИБКА: укажите -Secret <имя[,имя]> (либо режим -List / -VerifyOnly).'
    exit 2
}
$hasCommand = -not [string]::IsNullOrWhiteSpace($Command)
$hasFile    = -not [string]::IsNullOrWhiteSpace($FilePath)
if ($hasCommand -eq $hasFile) {
    Write-Host '[secrets] ОШИБКА: укажите ровно один из -Command или -FilePath.'
    exit 2
}
if ($hasFile -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Host ("[secrets] ОШИБКА: файл не найден: {0}" -f $FilePath)
    exit 2
}
if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory) -and -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    Write-Host ("[secrets] ОШИБКА: рабочий каталог не найден: {0}" -f $WorkingDirectory)
    exit 2
}
if ($null -eq $CommandArgs) { $CommandArgs = @() }

# Resolve and validate every ENV name BEFORE touching the environment.
$plan = @()
foreach ($n in @($Secret)) {
    $envName = Get-EnvName $n
    if (-not (Test-EnvName $envName $n)) { exit 2 }
    $plan += [pscustomobject]@{ Name = $n; Env = $envName }
}

# Save original values and inject secrets; restore in finally so nothing leaks out.
$saved = @{}
$failure = $false
$childExit = $null
foreach ($p in $plan) {
    if ($saved.ContainsKey($p.Env)) {
        Write-Host ("[secrets] {0} -> env:{1} (уже задан этим же вызовом, пропуск)" -f $p.Name, $p.Env)
        continue
    }
    $saved[$p.Env] = [Environment]::GetEnvironmentVariable($p.Env, 'Process')
    $captured = & $getSecret -Name $p.Name -AsEnv $p.Env *>&1
    $injectExit = $LASTEXITCODE
    if ($injectExit -ne 0) {
        Write-Host ("[secrets] ОШИБКА: секрет '{0}' недоступен (код {1}) — дочерний процесс НЕ запущен." -f $p.Name, $injectExit)
        $msg = ($captured | Out-String).Trim()
        if ($msg) { Write-Host $msg }
        Write-Host ("[secrets] Сохранение секрета: set-secret.ps1 -Name {0}" -f $p.Name)
        $failure = $true
        break
    }
    Write-Host ("[secrets] {0} -> env:{1} (инъекция на время вызова)" -f $p.Name, $p.Env)
}

try {
    if ($failure) { exit 2 }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        if ($hasFile) { & $FilePath @CommandArgs } else { & $Command @CommandArgs }
        $childExit = $LASTEXITCODE
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Pop-Location }
    }
}
finally {
    # env vars must not outlive this call (restore prior value or remove)
    foreach ($envName in @($saved.Keys)) {
        $orig = $saved[$envName]
        if ($null -ne $orig) { [Environment]::SetEnvironmentVariable($envName, [string]$orig, 'Process') }
        else { [Environment]::SetEnvironmentVariable($envName, $null, 'Process') }
    }
}

if ($null -eq $childExit) { $childExit = 0 }
exit $childExit
