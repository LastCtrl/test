param()
# Installs the canonical pre-commit hook into .git/hooks.
# Kept as a separate small script: the inline version inside sync-agents.ps1
# triggered corporate AV (AMSI / ScriptContainedMaliciousContent).
$root = if ($env:AGENT_HQ_ROOT) { $env:AGENT_HQ_ROOT } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$hookSource = Join-Path $root ".agents\hooks\pre-commit"
$gitHooksDir = Join-Path $root ".git\hooks"
$hookTarget = Join-Path $gitHooksDir "pre-commit"
if ((Test-Path -LiteralPath $hookSource) -and (Test-Path -LiteralPath $gitHooksDir -PathType Container)) {
    Copy-Item -LiteralPath $hookSource -Destination $hookTarget -Force
    Write-Host "Git hook installed: $hookTarget" -ForegroundColor Green
}
else {
    Write-Warning "Git hook not installed (source: $(Test-Path -LiteralPath $hookSource); .git/hooks: $(Test-Path -LiteralPath $gitHooksDir))"
}
