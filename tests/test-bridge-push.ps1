# test-bridge-push.ps1 - offline acceptance checks for US-016 push tiers and UX.
# Runs bridge.py --selftest (no network) and the offline --demo-push renderer.
# Exit 0 = PASS, exit 1 = FAIL.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$repo = Split-Path -Parent $PSScriptRoot
$bridge = Join-Path $repo 'projects\telegram-bridge\bridge.py'
$script:checks = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Assert-Check([string]$Name, [bool]$Condition, [string]$Detail) {
    $script:checks++
    if ($Condition) {
        Write-Host "PASS $Name"
    } else {
        Write-Host "FAIL $Name - $Detail"
        $script:failures.Add($Name)
    }
}

$py = $null
$pyArgs = @()
$launcher = Get-Command py -ErrorAction SilentlyContinue
if ($launcher) {
    $py = $launcher.Source
    $pyArgs = @('-3')
} else {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source -notlike '*WindowsApps*') { $py = $pythonCmd.Source }
}
Assert-Check 'interpreter найден' ([bool]$py) 'нет py/python'
if (-not $py) {
    Write-Host "checks=$script:checks failed=$($script:failures.Count)"
    exit 1
}
Assert-Check 'bridge.py существует' (Test-Path -LiteralPath $bridge -PathType Leaf) $bridge

$selfOut = & $py @pyArgs $bridge --selftest 2>&1 | Out-String
$selfCode = $LASTEXITCODE
Assert-Check 'selftest exit 0' ($selfCode -eq 0) "exit=$selfCode"
Assert-Check 'selftest failed=0' ($selfOut -match 'failed=0') 'есть падения'
$countMatch = [regex]::Match($selfOut, 'checks passed=(\d+)')
$passedCount = if ($countMatch.Success) { [int]$countMatch.Groups[1].Value } else { 0 }
Assert-Check 'selftest >= 138 проверок' ($passedCount -ge 138) "проверок: $passedCount"

$required = @(
    'push parser: структурные поля извлечены',
    'push parser: подстрока в CONTENT не становится полем',
    'push parser: CONTENT-инъекция игнорируется',
    'push: dead-letter -> critical instant',
    'push: blocker PRIORITY:critical -> critical',
    'push: REJECT -> reject-тир',
    'push: завершённая задача -> done-тир',
    'push: фейковая blocker-строка не триггерит',
    'push: детектор read-only',
    'push plan: critical instant (sound), reject/done тихие',
    'push dispatch: первый тик отправил сообщения',
    'push dispatch: повторный тик не дублирует',
    'push dispatch: hard cap',
    'push dispatch: rate-limit глушит шторм',
    'push dispatch: /alerts off глушит push',
    'lock: второй тик отклонён',
    'ux: inline-кнопка обновления построена',
    'ux: /status с inline-кнопкой',
    'ux: клавиатура agents построена',
    "ux: callback 'cmd:queue' -> queue",
    'answer: ответ run-задачи доставлен',
    'answer: анти-дубль (повторная доставка не идёт)',
    'ux: setMyCommands покрывает команды',
    'sqlite ro: запись отклонена',
    'doh: резолв вернул IP',
    'doh: кэш жив в пределах TTL',
    'doh: TTL не ниже минимума',
    'doh: fallback на системный DNS',
    'doh: всё пусто -> понятная ошибка',
    'resolver: api.telegram.org -> DoH IP',
    'resolver: прочие хосты -> делегат'
)
foreach ($line in $required) {
    Assert-Check "selftest содержит: $line" ($selfOut -match [regex]::Escape($line)) 'строка PASS не найдена'
}

$demoOut = & $py @pyArgs $bridge --demo-push 2>&1 | Out-String
$demoCode = $LASTEXITCODE
Assert-Check 'demo-push exit 0' ($demoCode -eq 0) "exit=$demoCode"
Assert-Check 'demo: планирует сообщения' ($demoOut -match 'запланировано сообщений') 'нет плана'
Assert-Check 'demo: critical instant' ($demoOut -match 'tier=critical silent=False') 'нет instant'
Assert-Check 'demo: тихие ярусы' ($demoOut -match 'tier=reject silent=True' -and $demoOut -match 'tier=done silent=True') 'нет тихих'
Assert-Check 'demo: анти-дубль (tick2 sent=0)' ($demoOut -match 'tick2 sent=0') 'повтор отправил'
Assert-Check 'demo: hard cap 5' ($demoOut -match 'hard cap 5') 'нет упоминания cap'

# Network checks: only when the cntlm proxy is up. DoH must return an A-record
# for api.telegram.org and the direct HTTPS connection (SNI) must succeed.
$proxyUp = $false
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', 3128, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) {
        $client.EndConnect($iar)
        $proxyUp = [bool]$client.Connected
    }
    $client.Close()
} catch { $proxyUp = $false }
if ($proxyUp) {
    $netOut = & $py @pyArgs $bridge --check-network 2>&1 | Out-String
    $netCode = $LASTEXITCODE
    $netHead = $netOut.Substring(0, [Math]::Min(240, $netOut.Length))
    Assert-Check 'network: --check-network exit 0' ($netCode -eq 0) "exit=$netCode out=$netHead"
    Assert-Check 'network: DoH вернул IP' ($netOut -match '\[doh\] OK api\.telegram\.org -> \d+\.\d+\.\d+\.\d+') $netHead
    Assert-Check 'network: Telegram HTTPS OK' ($netOut -match 'Telegram HTTPS OK') $netHead
} else {
    Write-Host 'SKIP network checks (proxy 127.0.0.1:3128 down)'
}

Write-Host ""
Write-Host "checks=$script:checks failed=$($script:failures.Count)"
foreach ($name in $script:failures) { Write-Host "  - $name" }
if ($script:failures.Count -gt 0) { exit 1 }
exit 0
