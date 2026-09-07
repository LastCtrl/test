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

    $content = Get-Content $reportPath -Raw
    $cutoff = (Get-Date).AddHours(-$lookbackHours)

    # Найти все записи TYPE: update|resolved за последние N часов
    # Формат: [YYYY-MM-DD] agent >> team-lead: ... SKILLS_LOADED: [...] MCP_USED: [...] COMPLIANCE: true
    $pattern = '\[(?<date>\d{4}-\d{2}-\d{2})\]?\s*(?<time>\d{2}:\d{2}:\d{2})?\s*\]\s+(?<agent>\S+)\s+>>\s+team-lead:\s*TYPE:\s+(?<type>update|resolved).*?SKILLS_LOADED:\s*(?<skills>\[.*?\]).*?MCP_USED:\s*(?<mcp>\[.*?\]).*?COMPLIANCE:\s*(?<compliance>true|false)'
    $matches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $pass = 0
    $fail = 0
    $violations = @()

    foreach ($match in $matches) {
        # Parse date - use date part only since time might not be present
        $dateStr = $match.Groups['date'].Value
        $timeStr = $match.Groups['time'].Value
        if ($timeStr) {
            $time = [DateTime]::ParseExact("$dateStr $timeStr", "yyyy-MM-dd HH:mm:ss", $null)
        } else {
            $time = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
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
        $logPath = Join-Path (Split-Path $reportPath -Parent) ".memory\tool-usage-violations.jsonl"
        if (-not (Test-Path (Split-Path $logPath -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null
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