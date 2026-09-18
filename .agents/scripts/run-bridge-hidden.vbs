Dim fso, sh, scriptDir, root, ps
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(fso.GetParentFolderName(scriptDir))
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & root & "\.agents\scripts\run-bridge.ps1"" --once"
sh.Run ps, 0, False
