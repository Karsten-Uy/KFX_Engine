' launch_kfx_gui.vbs - start the KFX Engine GUI with NO console window.
'
' Runs the GUI straight from this repo folder, so editing gui.py (or a git pull)
' takes effect on the very next launch - nothing is bundled or frozen.
'
' Preference order:
'   1. the project's venv pythonw.exe  -> a GUI-subsystem Python, zero console,
'      fast, and independent of whether `uv` is on PATH.
'   2. `uv run python gui.py`          -> self-heals a missing venv on a fresh
'      clone; launched hidden (window style 0) so its console never shows.
'
' Double-click this file to run the app, or let install_shortcut.ps1 create a
' Start Menu shortcut that points here.

Dim sh, fso, here, pyw
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
pyw = here & "\.venv\Scripts\pythonw.exe"

If fso.FileExists(pyw) Then
    ' pythonw.exe has no console of its own; only the Tk window appears.
    sh.Run """" & pyw & """ """ & here & "\gui.py""", 0, False
Else
    ' No venv yet: let uv build/sync it and run. Style 0 hides uv's console;
    ' the Tk window still shows normally.
    sh.Run "cmd /c uv run python gui.py", 0, False
End If
