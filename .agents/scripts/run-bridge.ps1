# run-bridge.ps1 - Wrapper to start the Telegram bridge (US-016, not implemented yet).
# Flow:
#   1. Verify the tg-bot-token secret exists (get-secret -Verify, same process).
#   2. If exists: put it into env:TG_TOKEN of the CURRENT process, then run bridge.py.
#      bridge.py does not exist yet -> polite message, exit 0 (this is OK).
#   3. If no secret: instruct how to save it, exit 1.
# The token itself is never printed or passed on the command line.

$ErrorActionPreference = 'Continue'
$here     = $PSScriptRoot
$getToken = Join-Path $here 'get-secret.ps1'
$bridgePy = 'D:\Тест\agent-hq\projects\telegram-bridge\bridge.py'

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

& python $bridgePy
exit $LASTEXITCODE
