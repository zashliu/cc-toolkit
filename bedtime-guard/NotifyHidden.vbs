' Launch the resident notifier fully hidden and keep the scheduled task attached to it.
' Run arg 0 = hidden, True = wait until Notify.ps1 exits.
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\ProgramData\BedtimeGuard\Notify.ps1""", 0, True
