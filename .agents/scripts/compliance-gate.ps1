# compliance-gate.ps1 - validation of the Skills+MCP enforcement mandate.
# Checks that every self-report record in CONTEXT-BUFFER.md (TYPE: update|resolved,
# within the lookback window) carries non-empty SKILLS_LOADED / MCP_USED and
# COMPLIANCE: true.
#
# Parsing is PER-RECORD: the content is first split at self-report headers
# ("[stamp] <agent> -> team-lead:") and every field is searched inside its own
# record body only. A field can therefore never leak from a neighbouring record,
# and a record with a missing field is a visible FAIL instead of being skipped.
#
# Exit code: 0 when there are no violations, 1 when at least one record fails
# (regardless of -Strict; a violation is always a gate failure).

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

    # -Encoding UTF8: bus files carry no BOM; otherwise PS 5.1 decodes them as
    # CP1251 and corrupts the unicode arrow separator (U+2192).
    $content = Get-Content $reportPath -Raw -Encoding UTF8
    $cutoff = (Get-Date).AddHours(-$lookbackHours)

    # Record header: "[stamp] <agent> -> team-lead:" ("->", U+2192 or legacy ">>").
    # Multiline (NOT Singleline) so a header is always matched on a single line.
    $headerPattern = '(?m)^\[(?<stamp>[^\]]+)\]\s+(?<agent>\S+(?:\s+\([^)]*\))?)\s+(?:->|\u2192|>>)\s+team-lead:'
    $headers = [regex]::Matches($content, $headerPattern)

    # Field lines are anchored to the start of a line so field-shaped text
    # embedded in CONTENT (e.g. the literal "COMPLIANCE:false" quoted inside a
    # report body) is never mistaken for a real field.
    $typePattern       = '(?m)^TYPE:\s*(?<type>update|resolved)\b'
    $skillsPattern     = '(?m)^SKILLS_LOADED:\s*(?<v>\[[^\]\r\n]*\])'
    $mcpPattern        = '(?m)^MCP_USED:\s*(?<v>\[[^\]\r\n]*\])'
    $compliancePattern = '(?m)^COMPLIANCE:\s*(?<v>true|false)'

    $pass = 0
    $fail = 0
    $placeholders = 0
    $violations = @()

    for ($i = 0; $i -lt $headers.Count; $i++) {
        $start = $headers[$i].Index
        $end = if ($i + 1 -lt $headers.Count) { $headers[$i + 1].Index } else { $content.Length }
        $body = $content.Substring($start, $end - $start)

        # Parse stamp: ISO with T ("2026-09-14T19:00:00"), date+time with a space,
        # "~" before time, or date only. Placeholder/non-date stamps (e.g. "[TIME]")
        # are skipped with a WARN and counted in the summary; never treated as now.
        $stamp = $headers[$i].Groups['stamp'].Value
        if ($stamp -match '(?<d>\d{4}-\d{2}-\d{2})(?:[T ]\s*~?(?<t>\d{2}:\d{2}(?::\d{2})?))?') {
            $dateStr = $Matches['d']
            $timeStr = $Matches['t']
            if ($timeStr) {
                if ($timeStr.Length -eq 5) { $timeStr = "${timeStr}:00" }
                try {
                    $time = [DateTime]::ParseExact("$dateStr $timeStr", "yyyy-MM-dd HH:mm:ss", $null)
                } catch {
                    Write-Host "  [WARN] Invalid stamp '$stamp' -- skipping record (not counted as violation)" -ForegroundColor Yellow
                    $placeholders++
                    continue
                }
            } else {
                try {
                    $time = [DateTime]::ParseExact($dateStr, "yyyy-MM-dd", $null)
                } catch {
                    Write-Host "  [WARN] Invalid stamp '$stamp' -- skipping record (not counted as violation)" -ForegroundColor Yellow
                    $placeholders++
                    continue
                }
            }
        } else {
            Write-Host "  [WARN] Placeholder/non-date stamp '$stamp' -- skipping record (not counted as violation)" -ForegroundColor Yellow
            $placeholders++
            continue
        }
        if ($time -lt $cutoff) { continue }

        $agent = $headers[$i].Groups['agent'].Value

        $typeMatch   = [regex]::Match($body, $typePattern)
        $skillsMatch = [regex]::Match($body, $skillsPattern)
        $mcpMatch    = [regex]::Match($body, $mcpPattern)
        $compMatch   = [regex]::Match($body, $compliancePattern)

        $reason = @()
        if (-not $typeMatch.Success) {
            $reason += "TYPE missing/not update|resolved"
        }
        if (-not $skillsMatch.Success) {
            if ([regex]::IsMatch($body, '(?m)^SKILLS_LOADED:')) { $reason += "SKILLS_LOADED malformed" }
            else { $reason += "SKILLS_LOADED missing" }
        } elseif ($skillsMatch.Groups['v'].Value -eq '[]') {
            $reason += "SKILLS_LOADED empty"
        }
        if (-not $mcpMatch.Success) {
            if ([regex]::IsMatch($body, '(?m)^MCP_USED:')) { $reason += "MCP_USED malformed" }
            else { $reason += "MCP_USED missing" }
        } elseif ($mcpMatch.Groups['v'].Value -eq '[]') {
            $reason += "MCP_USED empty"
        }
        if (-not $compMatch.Success) {
            if ([regex]::IsMatch($body, '(?m)^COMPLIANCE:')) { $reason += "COMPLIANCE malformed" }
            else { $reason += "COMPLIANCE missing" }
        } elseif ($compMatch.Groups['v'].Value -ne 'true') {
            $reason += "COMPLIANCE != true"
        }

        if ($reason.Count -eq 0) {
            $skills = $skillsMatch.Groups['v'].Value
            $mcp = $mcpMatch.Groups['v'].Value
            Write-Host "  [PASS] $agent -- skills: $skills, mcp: $mcp" -ForegroundColor Green
            $pass++
        } else {
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

    # Violation log
    if ($violations.Count -gt 0) {
        # For a relative $reportPath Split-Path -Parent returns empty -- use cwd.
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
            # Best-effort: a concurrent writer may hold the log; never let logging
            # abort the gate (the violation was already reported above).
            try {
                Add-Content -Path $logPath -Value $entry -Encoding UTF8 -ErrorAction Stop
            } catch {
                Write-Host "  [WARN] Could not append violation log: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "`n=== Compliance Summary ===" -ForegroundColor Cyan
    Write-Host "Passed: $pass"
    Write-Host "Failed: $fail"
    Write-Host "Placeholders skipped: $placeholders"
    Write-Host "Total:  $($pass + $fail)"

    return ($fail -eq 0)
}

$ok = Test-Compliance -reportPath $ReportPath -lookbackHours $LookbackHours -strict $Strict
# Emit the verdict on the pipeline so in-process callers (health-check.ps1)
# can capture it, then signal the outcome via the exit code.
Write-Output $ok
# A violation is always a gate failure: exit 1 even without -Strict.
if (-not $ok) { exit 1 }
exit 0
