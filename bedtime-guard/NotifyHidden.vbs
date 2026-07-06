' Launch Notify.ps1 fully hidden to avoid a console window flashing every minute.
' wscript.exe has no console window; Run arg 0 = hidden, False = do not wait.
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\ProgramData\BedtimeGuard\Notify.ps1""", 0, False
