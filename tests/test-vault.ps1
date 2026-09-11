# test-vault.ps1 - Self-test for the DPAPI secret vault.
# IMPORTANT: this test does NOT use any -TestValue/backdoor in prod scripts.
# It encrypts the well-known TEST plaintext "test-secret-123" directly with
# ProtectedData::Protect (exactly like set-secret.ps1 does) and verifies that
# get-secret.ps1 can read it back. No real secrets are involved.

$ErrorActionPreference = 'Continue'
$here     = $PSScriptRoot
$scripts  = Join-Path (Join-Path (Split-Path -Parent $here) '.agents') 'scripts'
$getToken = Join-Path $scripts 'get-secret.ps1'
$setSecret = Join-Path $scripts 'set-secret.ps1'
$runBridge = Join-Path $scripts 'run-bridge.ps1'
$SecretsDir = 'C:\Users\Ermak_DS\.agent-secrets'
$TestName = 'selftest-tmp'
$TestPlain = 'test-secret-123'

$results = @()
function Add-Result($id, $pass, $note) {
    $script:results += [pscustomobject]@{ Id = $id; Pass = $pass; Note = $note }
    Write-Host ("[{0}] {1} — {2}" -f $(if ($pass) {'PASS'} else {'FAIL'}), $id, $note)
}
function Invoke-Capture($scriptBlock) {
    # capture ALL streams (Write-Host goes to stream 6 in PS 5.1)
    & $scriptBlock *>&1 | Out-String
}

try {
    # --- prepare: encrypt test plaintext directly (as set-secret would) ---
    if (-not (Test-Path -LiteralPath $SecretsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null
    }
    Add-Type -AssemblyName System.Security
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($TestPlain)
    $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes((Join-Path $SecretsDir "secret.$TestName.enc"), $encBytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $expectedFp = ([BitConverter]::ToString($sha.ComputeHash($plainBytes)) -replace '-', '').ToLowerInvariant().Substring(0, 12)
    $sha.Dispose()

    # --- T2: get-secret -Verify -> matching hash ---
    $out = Invoke-Capture { & $getToken -Name $TestName -Verify }
    $ok = ($LASTEXITCODE -eq 0) -and ($out -match [regex]::Escape($expectedFp))
    Add-Result 'T2-verify' $ok ("expected=$expectedFp captured-match=$($out -match [regex]::Escape($expectedFp))")

    # --- T3: get-secret -AsEnv TEST_VAULT in the same process ---
    $out = Invoke-Capture { & $getToken -Name $TestName -AsEnv TEST_VAULT }
    $ok = ($LASTEXITCODE -eq 0) -and ($env:TEST_VAULT -ceq $TestPlain)
    Add-Result 'T3-asenv' $ok ("env matches=$($env:TEST_VAULT -ceq $TestPlain)")

    # --- T4: missing secret (with a mode) -> clear error + exit 1 + name list ---
    $out = Invoke-Capture { & $getToken -Name nonexistent -Verify }
    $ok = ($LASTEXITCODE -eq 1) -and ($out -match 'не найден')
    Add-Result 'T4-missing' $ok ("exit=$LASTEXITCODE name-listed=$($out -match 'selftest-tmp')")

    # --- T4b: no mode selected -> usage error ---
    $out = Invoke-Capture { & $getToken -Name $TestName }
    $ok = ($LASTEXITCODE -eq 1) -and ($out -match 'AsEnv')
    Add-Result 'T4b-usage' $ok "exit=$LASTEXITCODE (usage hint shown)"

    # --- T5: bad secret name rejected ---
    $out = Invoke-Capture { & $getToken -Name 'Bad_Name!' }
    Add-Result 'T5-badname' ($LASTEXITCODE -eq 1) "exit=$LASTEXITCODE (name rejected)"

    # --- T6: set-secret -List shows saved names ---
    $out = Invoke-Capture { & $setSecret -List }
    $ok = ($LASTEXITCODE -eq 0) -and ($out -match $TestName)
    Add-Result 'T6-list' $ok "list contains $TestName"

    # --- T7: run-bridge without tg-bot-token -> exit 1 + hint ---
    $tgFile = Join-Path $SecretsDir 'secret.tg-bot-token.enc'
    $tgExisted = Test-Path -LiteralPath $tgFile -PathType Leaf
    if ($tgExisted) { Rename-Item -LiteralPath $tgFile -NewName 'secret.tg-bot-token.enc.hold' -Force }
    $out = Invoke-Capture { & $runBridge }
    $ok = ($LASTEXITCODE -eq 1) -and ($out -match 'set-secret')
    Add-Result 'T7-bridge-nosecret' $ok "exit=$LASTEXITCODE hint-shown=$($out -match 'set-secret')"
}
catch {
    Write-Host ('STACK: ' + $_.ScriptStackTrace)
    Write-Host ('POS: ' + $_.InvocationInfo.PositionMessage)
    Add-Result 'T-runtime' $false $_.Exception.Message
}

# --- T8: cleanup test secret + env ---
try {
    $f = Join-Path $SecretsDir "secret.$TestName.enc"
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    Remove-Item Env:TEST_VAULT -ErrorAction SilentlyContinue
    $hold = Join-Path $SecretsDir 'secret.tg-bot-token.enc.hold'
    if (Test-Path -LiteralPath $hold) { Rename-Item -LiteralPath $hold -NewName 'secret.tg-bot-token.enc' -Force }
    Add-Result 'T8-cleanup' $true 'test secret + TEST_VAULT removed'
}
catch {
    Add-Result 'T8-cleanup' $false $_.Exception.Message
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("ИТОГ: {0}/{1} PASS" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
