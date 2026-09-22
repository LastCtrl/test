@echo off
rem Wrapper for scheduled task: runs the bridge once, logging output for diagnostics.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-bridge.ps1" --once >> "%~dp0..\..\.memory\traces\bridge-task.log" 2>&1
