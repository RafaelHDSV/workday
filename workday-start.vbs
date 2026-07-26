' Inicia o overlay sem janela de console (CMD/PowerShell).
Option Explicit

Dim fso, shell, scriptDir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\workday.ps1"""
shell.Run cmd, 0, False
