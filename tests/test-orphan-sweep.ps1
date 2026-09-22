# test-orphan-sweep.ps1 - изолированные тесты .agents\scripts\orphan-sweep.ps1.
#
# Две части:
#   1) unit: чистые функции выбора кандидата на синтетических процессах
#      (CIM-подобные объекты) - маркер проекта, мёртвый родитель, PID-reuse,
#      возраст, allowlist имён, защита текущего процесса / активных job;
#   2) integration: два РЕАЛЬНЫХ процесса-сироты (родитель-обёртка завершается) -
#      «наш» (cmdline указывает на наш temp) и «чужой» (cmdline без наших маркеров).
#      DryRun обязан показать первого, не показать второго и НИЧЕГО не убить.
#
# Никаких секретов. Фоновые процессы создаются только внутри кейса и всегда
# убиваются в finally по PID (плюс самоограничение Start-Sleep 45 c).
# Exit code: 0 - все проверки прошли, 1 - есть FAIL.

$Here     = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$Target   = Join-Path $RepoRoot ".agents\scripts\orphan-sweep.ps1"
$TempBase = Join-Path $env:TEMP ("agent-hq-orphan-sweep-tests\" + [guid]::NewGuid().ToString('N'))
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

# Процесс-кандидат в списке вывода свипа (первый токен строки = PID).
function Test-PidListed {
    param([string]$Text, [int]$ProcessId)
    foreach ($line in ($Text -split "\r?\n")) {
        $t = $line.Trim()
        if ($t -match '^(\d+)\s') {
            if ([int]$Matches[1] -eq $ProcessId) { return $true }
        }
    }
    return $false
}

function Stop-TestProcess {
    param([int]$ProcessId)
    try {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction SilentlyContinue
        if ($p -and $p.Name -eq 'powershell.exe') { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function New-FakeProc {
    param([int]$Id, [int]$ParentId, [string]$Name, [string]$Cmd, [datetime]$Created)
    return [pscustomobject]@{
        ProcessId       = $Id
        ParentProcessId = $ParentId
        Name            = $Name
        CommandLine     = $Cmd
        CreationDate    = $Created
    }
}

function Select-Fake {
    param([object[]]$Processes, [string]$SweepRoot, [int]$Age = 30, [int[]]$Protected = @(), [datetime]$Now)
    return @(Select-OrphanCandidate -Processes $Processes -RootValue $SweepRoot -Names @('powershell', 'node', 'opencode', 'python') -OlderThanMinutes $Age -ProtectedPids $Protected -Now $Now)
}

# --- runner ----------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
    Write-Host ("FATAL: target script not found: " + $Target)
    exit 1
}
New-Item -ItemType Directory -Path $TempBase -Force | Out-Null

$ownScript = Join-Path $TempBase "ours-child.ps1"
$foreignScript = Join-Path $env:TEMP ("orphan-foreign-" + [guid]::NewGuid().ToString('N') + ".ps1")
$wrapperScript = Join-Path $TempBase "wrapper.ps1"
$pidFile = Join-Path $TempBase "child-pids.txt"
$ownPid = 0
$foreignPid = 0

try {
    Write-Host "=== orphan-sweep tests ==="

    # --- unit: dot-source даёт функции без запуска CLI ---
    . $Target

    $unitRoot = Join-Path $env:TEMP 'agent-hq-synthetic-root'
    $oursCmd = 'powershell -NoProfile -File "' + (Join-Path $unitRoot 'scripts\busy.ps1') + '"'
    $foreignCmd = 'powershell -NoProfile -Command "Get-Date"'
    $now = Get-Date

    # u1: наш процесс, родитель мёртв, возраст 45 мин -> кандидат
    # NB: результат всегда оборачиваем в @(): в PS 5.1 у PSCustomObject нет .Count,
    #    и одиночный кандидат (не массив) дал бы пустое значение вместо 1.
    $procs = @(New-FakeProc -Id 5001 -ParentId 9001 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-45)))
    $sel = @(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now)
    Write-Check "u1) наш осиротевший процесс найден (1)" ($sel.Count -eq 1)
    Write-Check "u1) PID и возраст верны" ($sel.Count -eq 1 -and $sel[0].PID -eq 5001 -and $sel[0].AgeMinutes -ge 44)

    # u2: родитель жив -> не кандидат
    $procs = @(
        (New-FakeProc -Id 9001 -ParentId 0 -Name 'explorer.exe' -Cmd 'C:\Windows\explorer.exe' -Created ($now.AddHours(-2))),
        (New-FakeProc -Id 5002 -ParentId 9001 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-45)))
    )
    Write-Check "u2) живой родитель -> 0 кандидатов" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now).Count -eq 0)

    # u3: PID родителя переиспользован (родитель стартовал позже ребёнка) -> сирота
    $procs = @(
        (New-FakeProc -Id 9002 -ParentId 0 -Name 'explorer.exe' -Cmd 'C:\Windows\explorer.exe' -Created ($now.AddMinutes(-1))),
        (New-FakeProc -Id 5003 -ParentId 9002 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-60)))
    )
    $sel = @(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now)
    Write-Check "u3) PID-reuse родителя -> сирота найден" ($sel.Count -eq 1 -and $sel[0].PID -eq 5003)

    # u4: чужая командная строка -> не кандидат (даже если сирота)
    $procs = @(New-FakeProc -Id 5004 -ParentId 9003 -Name 'powershell.exe' -Cmd $foreignCmd -Created ($now.AddMinutes(-90)))
    Write-Check "u4) чужая cmdline -> 0 кандидатов" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now).Count -eq 0)
    Write-Check "u4) маркер чужой cmdline не матчится" (-not (Test-OrphanMarkerMatch -CommandLine $foreignCmd -Markers (Get-OrphanMarkers -RootValue $unitRoot)))

    # u5: имя процесса вне списка -> не кандидат
    $procs = @(New-FakeProc -Id 5005 -ParentId 9004 -Name 'notepad.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-90)))
    Write-Check "u5) чужое имя процесса -> 0 кандидатов" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now).Count -eq 0)

    # u6: порог возраста
    $procs = @(New-FakeProc -Id 5006 -ParentId 9005 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-10)))
    Write-Check "u6) моложе порога 30 мин -> 0" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Age 30 -Now $now).Count -eq 0)
    Write-Check "u6) порог 0 -> найден" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Age 0 -Now $now).Count -eq 1)

    # u7: текущий процесс защищён
    $procs = @(New-FakeProc -Id $PID -ParentId 0 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-90)))
    Write-Check "u7) текущий PID защищён" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Protected @($PID) -Now $now).Count -eq 0)

    # u8/u10: PID активного job и его потомки защищены
    $procs = @(New-FakeProc -Id 7001 -ParentId 9007 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-90)))
    Write-Check "u8) PID активного job защищён" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Protected @(7001) -Now $now).Count -eq 0)

    $procs = @(
        (New-FakeProc -Id 8001 -ParentId 9008 -Name 'powershell.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-90))),
        (New-FakeProc -Id 8002 -ParentId 8001 -Name 'node.exe' -Cmd $oursCmd -Created ($now.AddMinutes(-90)))
    )
    Write-Check "u10) потомок защищённого PID защищён" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Protected @(8001) -Now $now).Count -eq 0)

    # u9: имя процесса нормализуется (.exe и регистр)
    $procs = @(New-FakeProc -Id 5009 -ParentId 9009 -Name 'POWERSHELL.EXE' -Cmd $oursCmd -Created ($now.AddMinutes(-90)))
    Write-Check "u9) POWERSHELL.EXE нормализован и найден" (@(Select-Fake -Processes $procs -SweepRoot $unitRoot -Now $now).Count -eq 1)

    # --- integration: два реальных сироты ---
    [System.IO.File]::WriteAllText($ownScript, "Start-Sleep -Seconds 45`r`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText($foreignScript, "Start-Sleep -Seconds 45`r`n", $Utf8NoBom)
    $wrapperSrc = @'
param([string]$OursScript, [string]$ForeignScript, [string]$PidFile)
$enc = New-Object System.Text.UTF8Encoding($false)
$p1 = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$OursScript) -PassThru
$p2 = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ForeignScript) -PassThru
[System.IO.File]::WriteAllText($PidFile, ($p1.Id.ToString() + ',' + $p2.Id.ToString()), $enc)
'@
    [System.IO.File]::WriteAllText($wrapperScript, $wrapperSrc, $Utf8NoBom)

    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapperScript -OursScript $ownScript -ForeignScript $foreignScript -PidFile $pidFile 2>&1
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        $parts = ([System.IO.File]::ReadAllText($pidFile)).Split(',')
        if ($parts.Count -eq 2) {
            $ownPid = [int]$parts[0]
            $foreignPid = [int]$parts[1]
        }
    }
    Write-Check "i0) оба тестовых процесса созданы и живы" ($ownPid -gt 0 -and $foreignPid -gt 0 -and
        ($null -ne (Get-Process -Id $ownPid -ErrorAction SilentlyContinue)) -and
        ($null -ne (Get-Process -Id $foreignPid -ErrorAction SilentlyContinue)))

    if ($ownPid -gt 0 -and $foreignPid -gt 0) {
        # Убеждаемся, что родитель-обёртка завершился (т.е. процессы - сироты).
        $wrapperDead = $true
        foreach ($cand in @($ownPid, $foreignPid)) {
            $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $cand) -ErrorAction SilentlyContinue
            if ($p) {
                $parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$p.ParentProcessId) -ErrorAction SilentlyContinue
                if ($parent) { $wrapperDead = $false }
            }
        }
        Write-Check "i1) у тестовых процессов родитель уже мёртв" $wrapperDead

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -DryRun -OlderThanMinutes 0 -Root $RepoRoot 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Check "i2) DryRun exit 0" ($code -eq 0)
        Write-Check "i3) DryRun нашёл «наш» процесс-сироту" (Test-PidListed -Text $out -ProcessId $ownPid)
        Write-Check "i4) DryRun НЕ показал «чужой» процесс" (-not (Test-PidListed -Text $out -ProcessId $foreignPid))
        Write-Check "i5) DryRun ничего не убил (наш жив)" ($null -ne (Get-Process -Id $ownPid -ErrorAction SilentlyContinue))
        Write-Check "i5) DryRun ничего не убил (чужой жив)" ($null -ne (Get-Process -Id $foreignPid -ErrorAction SilentlyContinue))
        Write-Check "i6) DryRun заявил, что не убивает" ($out -match 'dry-run: nothing is killed')
    }

    # --- guard: -Apply несовместим с нулевым порогом и с -DryRun ---
    $g1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Apply -OlderThanMinutes 0 2>&1 | Out-String
    $c1 = $LASTEXITCODE
    $g2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $Target -Apply -DryRun 2>&1 | Out-String
    $c2 = $LASTEXITCODE
    Write-Check "g1) -Apply с порогом 0 отклонён (exit 1)" ($c1 -eq 1)
    Write-Check "g2) -Apply + -DryRun отклонены (exit 1)" ($c2 -eq 1)

    # --- инварианты файла ---
    $bytes = [System.IO.File]::ReadAllBytes($Target)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Check "инвариант: UTF-8 BOM" $hasBom
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) {
            $lf++
            if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
    }
    Write-Check "инвариант: CRLF (lone LF = 0)" (($lf - $crlf) -eq 0 -and $crlf -gt 0)
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Target -Raw), [ref]$errors)
    Write-Check "инвариант: PSParser 0 ошибок" ($errors.Count -eq 0)
} catch {
    Write-Check 'harness' $false ("unhandled exception: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionScript)
} finally {
    if ($ownPid -gt 0) { Stop-TestProcess -ProcessId $ownPid }
    if ($foreignPid -gt 0) { Stop-TestProcess -ProcessId $foreignPid }
    Remove-Item -LiteralPath $TempBase -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $foreignScript) { Remove-Item -LiteralPath $foreignScript -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "=================================================="
Write-Host ("SUMMARY: passed=" + $script:Pass + " failed=" + $script:Fail + " total=" + ($script:Pass + $script:Fail))
Write-Host "=================================================="

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
