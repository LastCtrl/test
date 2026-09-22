Dim fso, sh, scriptDir, root, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(fso.GetParentFolderName(scriptDir))
cmd = "cmd /c """ & root & "\.agents\scripts\run-bridge-once.cmd"""
sh.Run cmd, 0, False
