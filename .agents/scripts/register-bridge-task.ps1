param(
    [string]$TaskName = 'agent-hq-telegram-bridge'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vbs = Join-Path $Root '.agents\scripts\run-bridge-serve-hidden.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B "{0}"' -f $vbs)
# Resident task: starts Mon-Fri 08:00, runs until the bridge self-exits at 17:00 (work hours).
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At '08:00'
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 10) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
'REGISTERED: {0} state={1} exec={2} days={3} interval={4} limit={5}' -f $t.TaskName, $t.State, $t.Actions[0].Execute, $t.Triggers[0].DaysOfWeek, $t.Triggers[0].Repetition.Interval, $t.Settings.ExecutionTimeLimit
