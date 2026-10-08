param(
    [string]$TaskName = 'agent-hq-gateway'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vbs = Join-Path $Root '.agents\scripts\run-gateway-hidden.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B "{0}"' -f $vbs)
# Resident gateway: must be up whenever agents run, so it starts at logon and
# restarts on failure. It is loopback-only and holds no state.
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
$t = Get-ScheduledTask -TaskName $TaskName
'REGISTERED: {0} state={1} exec={2} trigger={3} restart={4}x/{5}' -f $t.TaskName, $t.State, $t.Actions[0].Execute, $t.Triggers[0].CimClass.CimClassName, $t.Settings.RestartCount, $t.Settings.RestartInterval
