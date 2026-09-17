# compliance-gate.ps1 — Валидация enforcement Skills+MCP
# Проверяет: self-report в CONTEXT-BUFFER.md содержит SKILLS_LOADED и MCP_USED

param(
    [string]$ReportPath = "CONTEXT-BUFFER.md",
    [int]$LookbackHours = 24,
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

function Test-Compliance {
    param($reportPath, $lookbackHours, $strict)

    if (-not (Test-Path $reportPath)) {
        Write-Error "CONTEXT-BUFFER.md not found: $reportPath"
        exit 1
    }

    # -Encoding UTF8: файлы шины без BOM, иначе PS 5.1 читает их как CP1251 и портит разделитель U+2192
    $content = Get-Content $reportPath -Raw -Encoding UTF8
    $cutoff = (Get-Date).AddHours(-$lookbackHours)

    # Найти все записи TYPE: update|resolved за последние N часов
    # Реальные заголовки: [2026-09-09T10:20:00] / [2026-09-10 15:05] / [2026-09-10 ~17:20] / [TIME]
    # Разделитель: "->" или unicode-стрелка U+2192 (legacy ">>" тоже поддержан)
    $pattern = '\[(?<stamp>[^\]]+)\]\s+(?<agent>\S+(?:\s+\([^)]*\))?)\s+(?:->|\u2192|>>)\s+team-lead:\s*TYPE:\s+(?<type>update|resolved).*?SKILLS_LOADED:\s*(?<skills>\[[^\]\r\n]*\]).*?MCP_USED:\s*(?<mcp>\[[^\]\r\n]*\]).*?COMPLIANCE:\s*(?<compliance>true|false)'
    $allMatches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $pass = 0
    $fail = 0
    $violations = @()

    foreach ($match in $allMatches) {
        # Разбор метки: ISO с T ("2026-09-14T19:00:00"), дата+время через пробел, "~" перед временем,
        # только дата, либо плейсхолдер [TIME] (считаем моментом записи).
        $stamp = $match.Groups['stamp'].Value
        if ($stamp -match '(?<d>\d{4}-\d{2}-\d{2})(?:[T ]\s*~?(?<t>\d{2}:\d{2}(?::\d{2})?))?') {
            $dateStr = $Matches['d']
            $timeStr = $Matches['t']
            if ($timeStr) {
                if ($timeStr.Length -eq 5) { $timeStr = "${timeStr}:00" }
                try {
                    $time = [DateTime]::ParseExact("$dateStr $timeStr", "yyyy-MM-dd HH:mm:ss", $null)
                } catch {
                    Write-Host "  [WARN] Invalid stamp '$stamp' — skipping record (not counted as violation)" -ForegroundColor Yellow
                    continue
                }
            } else {
                try {
                    $time = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
                } catch {
                    Write-Host "  [WARN] Invalid stamp '$stamp' — skipping record (not counted as violation)" -ForegroundColor Yellow
                    continue
                }
            }
        } else {
            $time = Get-Date
        }
        if ($time -lt $cutoff) { continue }

        $agent = $match.Groups['agent'].Value
        $skills = $match.Groups['skills'].Value
        $mcp = $match.Groups['mcp'].Value
        $compliance = $match.Groups['compliance'].Value

        $skillsEmpty = $skills -eq '[]' -or [string]::IsNullOrWhiteSpace($skills)
        $mcpEmpty = $mcp -eq '[]' -or [string]::IsNullOrWhiteSpace($mcp)
        $compOk = $compliance -eq 'true'

        $ok = (-not $skillsEmpty) -and (-not $mcpEmpty) -and $compOk

        if ($ok) {
            Write-Host "  [PASS] $agent -- skills: $skills, mcp: $mcp" -ForegroundColor Green
            $pass++
        } else {
            $reason = @()
            if ($skillsEmpty) { $reason += "SKILLS_LOADED empty" }
            if ($mcpEmpty) { $reason += "MCP_USED empty" }
            if (-not $compOk) { $reason += "COMPLIANCE != true" }
            Write-Host "  [FAIL] $agent -- $($reason -join ', ')" -ForegroundColor Red
            $fail++
            $violations += @{
                agent = $agent
                time = $time
                reason = $reason -join '; '
            }
        }
    }

    if ($pass -eq 0 -and $fail -eq 0) {
        Write-Host "  [INFO] No records in last $lookbackHours hours" -ForegroundColor Yellow
    }

    # Логирование нарушений
    if ($violations.Count -gt 0) {
        # Для относительного $reportPath Split-Path -Parent возвращает пусто — берём текущий каталог
        $reportDir = Split-Path $reportPath -Parent
        if ([string]::IsNullOrWhiteSpace($reportDir)) { $reportDir = (Get-Location).Path }
        $memoryDir = Join-Path $reportDir ".memory"
        $logPath = Join-Path $memoryDir "tool-usage-violations.jsonl"
        if (-not (Test-Path $memoryDir)) {
            New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null
        }
        foreach ($v in $violations) {
            $entry = @{
                date = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
                agent = $v.agent
                missing = $v.reason
                severity = "warning"
            } | ConvertTo-Json -Depth 3
            Add-Content -Path $logPath -Value $entry -Encoding UTF8
        }
    }

    Write-Host "`n=== Compliance Summary ===" -ForegroundColor Cyan
    Write-Host "Passed: $pass"
    Write-Host "Failed: $fail"
    Write-Host "Total:  $($pass + $fail)"

    if ($fail -gt 0) {
        if ($strict) { exit 1 }
        return $false
    }
    return $true
}

Test-Compliance -reportPath $ReportPath -lookbackHours $LookbackHours -strict $Strict