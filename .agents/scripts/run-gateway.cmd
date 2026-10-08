@echo off
rem Resident model gateway launcher: injects provider keys from the vault and runs the gateway.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0run-with-secrets.ps1' -Secret 'opencode-api-key','openrouter-api-key' -FilePath '%~dp0..\..\go\bin\agent-hq-gateway.exe' -Args @('-config','%~dp0..\..\.agents\config\gateway.json')"
