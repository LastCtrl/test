param(
    [string]$TaskName = 'agent-hq-go-loop'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vbs = Join-Path $Root '.agents\scripts\run-go-loop-hidden.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B "{0}"' -f $vbs)
$base = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At '08:00'
$rep = New-ScheduledTaskTrigger -Once -At '08:00' -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Hours 9)
$base.Repetition = $rep.Repetition
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $base -Settings $settings -Force | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
'REGISTERED: {0} state={1} exec={2} days={3} interval={4}' -f $t.TaskName, $t.State, $t.Actions[0].Execute, $t.Triggers[0].DaysOfWeek, $t.Triggers[0].Repetition.Interval
