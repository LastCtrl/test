#!/usr/bin/env pwsh
# prompt-gate.ps1 — структурный контроль промптов агентов
# Usage: .\prompt-gate.ps1 -Check
#        .\prompt-gate.ps1 -FixSync

param(
    [switch]$Check,
    [switch]$FixSync
)

# Set UTF-8 output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$baseDir = "D:\Тест\agent-hq"

if ($FixSync) {
    Write-Host "[-FixSync] Re-running sync-agents.ps1 before check..."
    & (Join-Path $baseDir ".agents\scripts\sync-agents.ps1")
}
$agentsDir = Join-Path $baseDir ".opencode\agents"
$promptsDir = Join-Path $agentsDir "prompts"

# Список агентов (JSON файлы, кроме registry.json)
$agentFiles = Get-ChildItem -Path $agentsDir -Filter "*.json" | Where-Object { $_.Name -ne "registry.json" }
$agentNames = $agentFiles | ForEach-Object { $_.Name -replace "\.json$", "" }

# Союзы/предлоги, на которые строка не должна заканчиваться
$conjunctions = @(" и", " в", " на", " с", " по", " за", " к", " о", " у", " от", " до", " при", "—", "-")

function Check-G1 {
    param($agentFile)
    try {
        $content = Get-Content $agentFile.FullName -Encoding UTF8
        $json = $content | ConvertFrom-Json
        return $true
    } catch {
        return $false
    }
}

function Check-G2 {
    param($agent)
    if (-not $agent.prompt) { return $false }
    $prompt = $agent.prompt
    return $prompt.Length -gt 500
}

function Check-G3 {
    param($promptText)
    if (-not $promptText) { return $true }
    # Find duplicate '## ' headers using regex
    $pattern = '^## .+'
    $matches = [regex]::Matches($promptText, $pattern)
    $headers = $matches | ForEach-Object { $_.Value }
    if ($headers.Count -le 1) { return $true }
    $uniqueHeaders = $headers | Select-Object -Unique
    return ($headers.Count -eq $uniqueHeaders.Count)
}

function Check-G4 {
    param($promptText)
    if (-not $promptText) { return $true }
    $lines = $promptText -split [Environment]::NewLine
    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()
        # Проверяем, заканчивается ли строка на союзе/предлоге
        foreach ($conj in $conjunctions) {
            if ($trimmed.EndsWith($conj, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
    }
    return $true
}

function Check-G5 {
    param($agentName, $agent)
    $prompt = $agent.prompt
    if (-not $prompt) { return $false }
    
    $result = $true
    
    if ($agentName -eq "team-lead") {
        if ($prompt -match "ОТКАТА|OTKATA|[Rr]etry") { $result = $true }
        else { $result = $false }
    }
    elseif ($agentName -eq "qa-engineer" -or $agentName -eq "code-reviewer" -or $agentName -eq "security-auditor") {
        if ($prompt -match "read-only|чтен|изменя") { $result = $true }
        else { $result = $false }
    }
    else {
        if ($prompt -match "CONTEXT-BUFFER") { $result = $true }
        else { $result = $false }
    }
    
    return $result
}

function Check-G6 {
    param($agentName)
    $txtPath = Join-Path $promptsDir "$agentName.txt"
    if (-not (Test-Path $txtPath)) { return $false }

    $jsonRaw = Get-Content (Join-Path $agentsDir "$agentName.json") -Raw -Encoding UTF8
    try { $promptField = ($jsonRaw | ConvertFrom-Json).prompt } catch { return $false }
    if (-not $promptField) { return $false }
    $txtContent = Get-Content $txtPath -Raw -Encoding UTF8

    # Разворачиваем JSON-эскейпы в реальный текст
    $promptReal = $promptField -replace '\\r\\n', "`n" -replace '\\n', "`n" -replace '\\t', "`t"

    # Нормализация концов строк
    $p = ($promptReal -replace "`r`n", "`n").Trim()
    $t = ($txtContent -replace "`r`n", "`n").Trim()
    if ($p -eq $t) { return $true }

    # Fallback: каждая непустая строка txt должна встречаться в промпте как подстрока
    foreach ($line in ($t -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if (-not $p.Contains($line)) { return $false }
    }
    return $true
}

# Выполнение проверок
$results = @{}
foreach ($agentFile in $agentFiles) {
    $name = $agentFile.Name -replace "\.json$", ""
    $results[$name] = @{ G1 = $false; G2 = $false; G3 = $false; G4 = $false; G5 = $false; G6 = $false }
    
    # Чтение JSON
    try {
        $agent = Get-Content $agentFile.FullName -Encoding UTF8 | ConvertFrom-Json
    } catch {
        continue
    }
    
    # G1: JSON валиден
    $results[$name].G1 = $true
    
    # G2: prompt непустой и >500 символов
    $results[$name].G2 = Check-G2 $agent
    
    # G3: нет дублей заголовков ##
    $results[$name].G3 = Check-G3 $agent.prompt
    
    # G4: нет обрывов по концу строки
    $results[$name].G4 = Check-G4 $agent.prompt
    
    # G5: обязательные секции по роли
    $results[$name].G5 = Check-G5 $name $agent
    
    # G6: консистентность sync
    $results[$name].G6 = Check-G6 $name
}

# Формирование отчета в файл
$reportPath = Join-Path $baseDir "temp_prompt_gate_report.txt"
Remove-Item $reportPath -ErrorAction SilentlyContinue

$report = @()
$report += "PROMPT GATE CHECK REPORT"
$report += ""
$report += "Agent              G1 G2 G3 G4 G5 G6 Status"
$report += "----------------- ---- ---- ---- ---- ---- -----"

$allPass = $true
foreach ($name in ($results.Keys | Sort-Object)) {
    $r = $results[$name]
    $g1 = if ($r.G1) { "PASS" } else { "FAIL" }
    $g2 = if ($r.G2) { "PASS" } else { "FAIL" }
    $g3 = if ($r.G3) { "PASS" } else { "FAIL" }
    $g4 = if ($r.G4) { "PASS" } else { "FAIL" }
    $g5 = if ($r.G5) { "PASS" } else { "FAIL" }
    $g6 = if ($r.G6) { "PASS" } else { "FAIL" }
    
    $status = if ($g1 -eq "PASS" -and $g2 -eq "PASS" -and $g3 -eq "PASS" -and $g4 -eq "PASS" -and $g5 -eq "PASS" -and $g6 -eq "PASS") { "PASS" } else { "FAIL" }
    
    if ($status -eq "FAIL") { $allPass = $false }
    
    $line = $name + " " + $g1 + " " + $g2 + " " + $g3 + " " + $g4 + " " + $g5 + " " + $g6 + " " + $status
    $report += $line
}

$report += ""
$totalAgents = $results.Keys.Count
$passAgents = ($results.Values | Where-Object { $_.G1 -and $_.G2 -and $_.G3 -and $_.G4 -and $_.G5 -and $_.G6 }).Count
$report += "Total: " + $passAgents + "/" + $totalAgents + " PASS"

if (-not $allPass) {
    $report += "Verdict: FAIL — there are agents with check failures"
    "FAIL" | Out-File -FilePath "$baseDir\temp_exit_code.txt" -Encoding UTF8
} else {
    $report += "Verdict: PASS — all agents passed the check"
    "PASS" | Out-File -FilePath "$baseDir\temp_exit_code.txt" -Encoding UTF8
}

# Запись отчета в файл
$report | Out-File -FilePath $reportPath -Encoding UTF8