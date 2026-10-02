@echo off
rem Wrapper for the resident scheduled task: runs the bridge in serve (long-poll) mode.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-bridge.ps1" --serve >> "%~dp0..\..\.memory\traces\bridge-serve.log" 2>&1
