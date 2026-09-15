# set-secret.ps1 - Save a secret encrypted with Windows DPAPI (scope: CurrentUser).
# The secret is entered via masked input (Read-Host -AsSecureString), never passed
# as a parameter, never printed, never logged. Only a SHA256 fingerprint (12 hex)
# is shown so the user can verify "the same secret" without revealing it.
# Storage: <AGENT_HQ_SECRETS or %USERPROFILE%\.agent-secrets>\secret.<Name>.enc (outside the repo).

param(
    # two mutually exclusive usages: save a secret (Name required) or list names
    [Parameter(ParameterSetName='Save', Mandatory=$true)][string]$Name,
    [Parameter(ParameterSetName='List')][switch]$List
)

$SecretsDir = if ($env:AGENT_HQ_SECRETS) { $env:AGENT_HQ_SECRETS } else { Join-Path $env:USERPROFILE '.agent-secrets' }

if ($PSCmdlet.ParameterSetName -eq 'List') {
    if (-not (Test-Path -LiteralPath $SecretsDir -PathType Container)) {
        Write-Host 'Нет сохранённых секретов (каталог ещё не создан).'
        exit 0
    }
    $files = @(Get-ChildItem -LiteralPath $SecretsDir -Filter 'secret.*.enc' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Host 'Нет сохранённых секретов.'
        exit 0
    }
    Write-Host 'Сохранённые секреты:'
    foreach ($f in $files) {
        $n = $f.Name -replace '^secret\.', '' -replace '\.enc$', ''
        Write-Host ("  {0}  (сохранён {1})" -f $n, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
    exit 0
}

# --- validate name BEFORE any prompt ---
if ($Name -notmatch '^[a-z0-9-]{2,40}$') {
    Write-Error ("Недопустимое имя секрета '$Name'. Разрешено: 2-40 символов, строчные латиница/цифры/дефис (пример: tg-bot-token).")
    exit 1
}

if (-not (Test-Path -LiteralPath $SecretsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
}

# --- masked input ONLY ---
$sec = Read-Host -AsSecureString 'Введите секрет (ввод маскирован)'
if ($sec.Length -eq 0) {
    Write-Error 'Пустой секрет — ничего не сохранено.'
    exit 1
}

# SecureString -> plaintext strictly inside the process, BSTR freed immediately
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = $null
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrEmpty($plain)) {
    Write-Error 'Пустой секрет — ничего не сохранено.'
    exit 1
}

$secretFile = Join-Path $SecretsDir ("secret.$Name.enc")
try {
    Add-Type -AssemblyName System.Security
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($secretFile, $encBytes)

    # fingerprint: SHA256 of the secret (not the secret itself)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash($plainBytes) } finally { $sha.Dispose() }
    $fp = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)

    Write-Host "Сохранено: secret.$Name.enc (каталог $SecretsDir)"
    Write-Host "Отпечаток секрета (SHA256, первые 12 hex): $fp"
}
finally {
    $plain = $null
}
