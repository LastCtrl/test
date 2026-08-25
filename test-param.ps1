param([switch]$DryRun)
if ($DryRun) { Write-Host "Dry run mode" } else { Write-Host "Normal mode" }