param(
    [string]$TaskName = 'agent-hq-telegram-bridge'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runner = Join-Path $Root '.agents\scripts\run-bridge.ps1'
$arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" --once' -f $runner
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$base = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At '08:00'
$rep = New-ScheduledTaskTrigger -Once -At '08:00' -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Hours 9)
$base.Repetition = $rep.Repetition
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $base -Settings $settings -Force | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
$days = $t.Triggers[0].DaysOfWeek
'REGISTERED: {0} state={1} days={2} interval={3}' -f $t.TaskName, $t.State, $days, $t.Triggers[0].Repetition.Interval
