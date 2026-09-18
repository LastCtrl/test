param(
    [string]$TaskName = 'agent-hq-telegram-bridge'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runner = Join-Path $Root '.agents\scripts\run-bridge.ps1'
$arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" --once' -f $runner
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At '08:00' -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Hours 9)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
'REGISTERED: {0} state={1}' -f $t.TaskName, $t.State
