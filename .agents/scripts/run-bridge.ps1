# run-bridge.ps1 - Wrapper to start the Telegram bridge (US-016).
# Flow:
#   1. Verify the tg-bot-token secret exists (get-secret -Verify, same process).
#   2. If exists: put it into env:TG_TOKEN of the CURRENT process, then run bridge.py.
#   3. If no secret: instruct how to save it, exit 1.
# The token itself is never printed and never passed on the command line.
# Extra arguments are forwarded to bridge.py as-is (examples: --once, --once --dry-run,
# --selftest, --limit 5).

$ErrorActionPreference = 'Continue'
$here     = $PSScriptRoot
$getToken = Join-Path $here 'get-secret.ps1'
$bridgePy = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'projects\telegram-bridge\bridge.py'

# 1) secret presence check (exit 1 + error from get-secret if missing)
& $getToken -Name tg-bot-token -Verify
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Секрет tg-bot-token не найден. Сначала: set-secret.ps1 -Name tg-bot-token'
    exit 1
}

# 2) token into env-var of this process, then launch the bridge
& $getToken -Name tg-bot-token -AsEnv TG_TOKEN
if ($LASTEXITCODE -ne 0) { exit 1 }

if (-not (Test-Path -LiteralPath $bridgePy -PathType Leaf)) {
    Write-Host 'bridge.py не найден — мост ещё не реализован (US-016).'
    exit 0
}

# 3) resolve a working interpreter. The bare 'python' shim from WindowsApps is a
#    Microsoft Store stub in this environment, so the 'py' launcher is preferred.
$pythonExe  = $null
$pythonArgs = @()
$pyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($pyLauncher) {
    $pythonExe  = $pyLauncher.Source
    $pythonArgs = @('-3')
} else {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source -notlike '*WindowsApps*') { $pythonExe = $pythonCmd.Source }
}
if (-not $pythonExe) {
    Write-Host 'Python 3 не найден (нет ни py, ни рабочего python). Установите Python 3 и повторите.'
    exit 1
}

$aiogramVersion = & $pythonExe @pythonArgs -c "import aiogram; print(aiogram.__version__)"
if ($LASTEXITCODE -ne 0) {
    Write-Host 'aiogram не установлен в этом интерпретаторе. Установка:'
    Write-Host '  pip install --proxy http://127.0.0.1:3128 -r projects\telegram-bridge\requirements.txt'
    exit 1
}
Write-Host ("[run-bridge] python: {0} | aiogram {1}" -f $pythonExe, $aiogramVersion)

& $pythonExe @pythonArgs $bridgePy @args
exit $LASTEXITCODE
