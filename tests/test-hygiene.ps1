# test-hygiene.ps1 - проверки гигиены (тех-долг, пункт 13).
#   H1-H3: model-limits.json - единый EOL (CRLF) + правило *.json в .gitattributes
#          + валидность JSON.
#   H4: run-bridge.ps1 при отсутствии bridge.py обязан вернуть exit != 0
#       (раньше exit 0 маскировал незавершённый мост) с понятным сообщением.
#   H5: инварианты правленых скриптов (UTF-8 BOM, CRLF, PSParser 0 ошибок).
# Изоляция: копия run-bridge.ps1 + get-secret.ps1 в temp-корне, throwaway DPAPI-vault
# в %TEMP% через $env:AGENT_HQ_SECRETS - реальный vault не читается и не пишется.
# Exit code: 0 - все проверки прошли, 1 - есть FAIL.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$ModelLimits = Join-Path $RepoRoot ".agents\config\model-limits.json"
$GitAttributes = Join-Path $RepoRoot ".gitattributes"
$ScriptsDir = Join-Path $RepoRoot ".agents\scripts"
$RunBridge = Join-Path $ScriptsDir "run-bridge.ps1"
$TempBase = Join-Path $env:TEMP ("agent-hq-hygiene-tests\" + [guid]::NewGuid().ToString('N'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Pass = 0
$script:Fail = 0

function Write-Check {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host ("    ok  : " + $Label)
        $script:Pass++
    } else {
        Write-Host ("    FAIL: " + $Label)
        $script:Fail++
    }
}

function Get-EolStats {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
    }
    return [pscustomobject]@{ LoneLF = ($lf - $crlf); CRLF = $crlf; LF = $lf }
}

function Test-FileInvariants {
    param([string]$Label, [string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Check ($Label + ": UTF-8 BOM") $hasBom
    $eol = Get-EolStats -Path $Path
    Write-Check ($Label + ": CRLF (lone LF = 0)") ($eol.LoneLF -eq 0 -and $eol.CRLF -gt 0)
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Path -Raw), [ref]$errors)
    Write-Check ($Label + ": PSParser 0 ошибок") ($errors.Count -eq 0)
}

$prevVault = $env:AGENT_HQ_SECRETS
try {
    Write-Host "=== hygiene tests (tech-debt item 13) ==="

    # --- H1: EOL model-limits.json ---
    Write-Check "H1) model-limits.json существует" (Test-Path -LiteralPath $ModelLimits -PathType Leaf)
    $eol = Get-EolStats -Path $ModelLimits
    Write-Check "H1) CRLF-строки есть" ($eol.CRLF -gt 0)
    Write-Check "H1) lone LF = 0 (единый EOL)" ($eol.LoneLF -eq 0)

    # --- H2: правило нормализации в .gitattributes ---
    Write-Check "H2) .gitattributes существует" (Test-Path -LiteralPath $GitAttributes -PathType Leaf)
    $attrText = [System.IO.File]::ReadAllText($GitAttributes)
    Write-Check "H2) есть правило '*.json text eol=crlf'" ($attrText -match '(?m)^\s*\*\.json\s+text\s+eol=crlf\s*$')
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        foreach ($rel in @('.agents/config/model-limits.json', '.opencode/agents/qa-engineer.json', 'schemas/opencode.config.schema.json')) {
            $ca = (& git -C $RepoRoot check-attr eol -- $rel 2>&1 | Out-String)
            Write-Check ("H2) git check-attr eol=crlf для " + $rel) ($ca -match 'eol:\s*crlf')
        }
    } else {
        Write-Check "H2) git доступен" $false
    }

    # --- H3: JSON валиден и содержателен ---
    $limits = $null
    $parseOk = $true
    try { $limits = ConvertFrom-Json ([System.IO.File]::ReadAllText($ModelLimits)) } catch { $parseOk = $false }
    Write-Check "H3) model-limits.json - валидный JSON" $parseOk
    if ($parseOk) {
        Write-Check "H3) 8 записей моделей сохранены" ((@($limits.models.PSObject.Properties)).Count -eq 8)
        Write-Check "H3) opencode/big-pickle: 100 req/day" ($limits.models.'opencode/big-pickle'.requests_per_day -eq 100)
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\config") -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $ok = $true
        try { $null = ConvertFrom-Json ([System.IO.File]::ReadAllText($f.FullName)) } catch { $ok = $false }
        Write-Check ("H3) валидный JSON: " + $f.Name) $ok
    }

    # --- H4: run-bridge.ps1 без bridge.py -> exit != 0 ---
    Write-Check "H4) run-bridge.ps1 существует" (Test-Path -LiteralPath $RunBridge -PathType Leaf)
    New-Item -ItemType Directory -Path $TempBase -Force | Out-Null
    $destScripts = Join-Path $TempBase ".agents\scripts"
    New-Item -ItemType Directory -Path $destScripts -Force | Out-Null
    $rbCopy = Join-Path $destScripts "run-bridge.ps1"
    Copy-Item -LiteralPath $RunBridge -Destination $rbCopy -Force
    Copy-Item -LiteralPath (Join-Path $ScriptsDir "get-secret.ps1") -Destination (Join-Path $destScripts "get-secret.ps1") -Force
    $bridgeUnderTemp = Join-Path $TempBase "projects\telegram-bridge\bridge.py"
    Write-Check "H4) в temp-корне bridge.py действительно нет" (-not (Test-Path -LiteralPath $bridgeUnderTemp -PathType Leaf))

    $vault = Join-Path $TempBase "vault"
    New-Item -ItemType Directory -Path $vault -Force | Out-Null
    Add-Type -AssemblyName System.Security
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes('test-secret-123')
    $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes((Join-Path $vault 'secret.tg-bot-token.enc'), $encBytes)
    $env:AGENT_HQ_SECRETS = $vault

    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rbCopy 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Check "H4) exit != 0 при отсутствии bridge.py" ($code -ne 0)
    Write-Check "H4) exit именно 1 (не маскирующий 0)" ($code -eq 1)
    # Сообщение с "bridge.py" доказывает, что проверка секрета уже пройдена
    # (иначе скрипт вышел бы раньше на get-secret -Verify).
    Write-Check "H4) в сообщении назван bridge.py" ($out -match 'bridge\.py')

    # --- H5: инварианты правленых скриптов ---
    Test-FileInvariants -Label "H5) run-bridge.ps1" -Path $RunBridge
    Test-FileInvariants -Label "H5) message-queue.ps1" -Path (Join-Path $ScriptsDir "message-queue.ps1")
    Test-FileInvariants -Label "H5) review-disagreement.ps1" -Path (Join-Path $ScriptsDir "review-disagreement.ps1")
    Test-FileInvariants -Label "H5) orphan-sweep.ps1" -Path (Join-Path $ScriptsDir "orphan-sweep.ps1")
} catch {
    Write-Check 'harness' $false ("unhandled exception: " + $_.Exception.Message)
} finally {
    try {
        if ($null -ne $prevVault) { $env:AGENT_HQ_SECRETS = $prevVault }
        else { Remove-Item -Path 'Env:\AGENT_HQ_SECRETS' -ErrorAction SilentlyContinue }
    } catch { }
    if (Test-Path -LiteralPath $TempBase) { Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
