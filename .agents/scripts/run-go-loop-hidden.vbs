Dim fso, sh, scriptDir, root, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
root = fso.GetParentFolderName(fso.GetParentFolderName(scriptDir))
cmd = """" & root & "\go\bin\agent-hq.exe"" run-loop -once"
sh.CurrentDirectory = root
sh.Run cmd, 0, False
