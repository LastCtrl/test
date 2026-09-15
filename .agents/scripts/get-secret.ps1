# get-secret.ps1 - Use a secret stored by set-secret.ps1 WITHOUT printing it.
# Two modes only:
#   -AsEnv <ENV_NAME> : decrypt and set env-var for the CURRENT process only
#   -Verify           : print only the SHA256 fingerprint (12 hex) for comparison
# There is NO mode that prints the secret to stdout.

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$AsEnv,
    [switch]$Verify
)

$SecretsDir = if ($env:AGENT_HQ_SECRETS) { $env:AGENT_HQ_SECRETS } else { Join-Path $env:USERPROFILE '.agent-secrets' }

if ($Name -notmatch '^[a-z0-9-]{2,40}$') {
    Write-Error ("Недопустимое имя секрета '$Name'. Разрешено: 2-40 символов, строчные латиница/цифры/дефис.")
    exit 1
}

if (-not $AsEnv -and -not $Verify) {
    Write-Error @"
Режим не выбран. Скрипт НИКОГДА не печатает секрет в stdout. Примеры:
  get-secret.ps1 -Name tg-bot-token -AsEnv TG_TOKEN   # положить в env:TG_TOKEN текущего процесса
  get-secret.ps1 -Name tg-bot-token -Verify            # показать SHA256-отпечаток (12 hex) для сверки
"@
    exit 1
}

$secretFile = Join-Path $SecretsDir ("secret.$Name.enc")
if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
    $available = @()
    if (Test-Path -LiteralPath $SecretsDir -PathType Container) {
        $available = @(Get-ChildItem -LiteralPath $SecretsDir -Filter 'secret.*.enc' -File -ErrorAction SilentlyContinue) |
            ForEach-Object { $_.Name -replace '^secret\.', '' -replace '\.enc$', '' }
    }
    $msg = "Секрет '$Name' не найден."
    if ($available.Count -gt 0) { $msg += " Доступные имена: $($available -join ', ')" }
    else { $msg += ' Сохранённых секретов нет.' }
    Write-Error $msg
    exit 1
}

$plain = $null
try {
    Add-Type -AssemblyName System.Security
    $encBytes = [System.IO.File]::ReadAllBytes($secretFile)
    try {
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    }
    catch {
        Write-Error "Не удалось расшифровать secret.$Name.enc (файл повреждён или создан другим пользователем/компьютером)."
        exit 1
    }
    $plain = [System.Text.Encoding]::UTF8.GetString($plainBytes)

    if ($Verify) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha.ComputeHash($plainBytes) } finally { $sha.Dispose() }
        $fp = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
        Write-Host "SHA256 ($Name, первые 12 hex): $fp"
    }

    if ($AsEnv) {
        [Environment]::SetEnvironmentVariable($AsEnv, $plain, 'Process')
        Write-Host ("{0} -> env:{1} (set, {2} симв.)" -f $Name, $AsEnv, $plain.Length)
    }
    exit 0
}
finally {
    # plaintext must not outlive the script
    $plain = $null
}
