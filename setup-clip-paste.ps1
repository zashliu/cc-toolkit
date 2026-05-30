# =====================================================================
# setup-clip-paste.ps1
# Enables: Alt+V screenshot -> Ctrl+V to paste the image into Claude Code
# running inside Windows Terminal.
#
# Idempotent & machine-agnostic. Safe to re-run (e.g. to update).
# Run in Windows PowerShell 5.1+:
#     powershell -ExecutionPolicy Bypass -File .\setup-clip-paste.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'

Write-Host "== Claude Code clipboard-image paste setup ==" -ForegroundColor Cyan

# --- target folder for the runtime scripts -----------------------------
$dir = Join-Path $env:USERPROFILE '.cc-clippaste'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# --- 1. Ensure AutoHotkey v2 is installed ------------------------------
function Resolve-Ahk {
    foreach ($c in @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey32.exe",
        'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
    )) { if (Test-Path $c) { return $c } }
    return $null
}
$ahk = Resolve-Ahk
if (-not $ahk) {
    Write-Host "Installing AutoHotkey v2 via winget..." -ForegroundColor Yellow
    winget install --id AutoHotkey.AutoHotkey -e --accept-source-agreements --accept-package-agreements --silent
    $ahk = Resolve-Ahk
}
if (-not $ahk) { throw "AutoHotkey not found after install. Install it manually, then re-run." }
Write-Host "AutoHotkey: $ahk" -ForegroundColor Green

# --- 2. Write the clipboard-image save script --------------------------
$savePs = Join-Path $dir 'save-clip-image.ps1'
@'
# Saves the clipboard image to a PNG and replaces the clipboard with its path.
# Retries ride out the race where the screenshot tool is still writing the
# clipboard, or it is briefly locked by another process (the "works sometimes" bug).
# Exit 0 = image saved & path copied; Exit 1 = no image after retries.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Get-ClipImage {
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $im = [System.Windows.Forms.Clipboard]::GetImage()
            if ($null -ne $im) { return $im }
        } catch { }
        Start-Sleep -Milliseconds 50
    }
    return $null
}
$img = Get-ClipImage
if ($null -eq $img) { exit 1 }
$d = Join-Path $env:TEMP 'cc-clip'
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
# Expand any 8.3 short name (e.g. ADMINI~1) to the full path so the displayed path is clean.
$sig = '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern int GetLongPathName(string s, System.Text.StringBuilder b, int len);'
Add-Type -MemberDefinition $sig -Name LP -Namespace W32 | Out-Null
$sb = New-Object System.Text.StringBuilder 1024
if ([W32.LP]::GetLongPathName($d, $sb, $sb.Capacity) -gt 0) { $d = $sb.ToString() }
$path = Join-Path $d ("clip_{0}.png" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$img.Dispose()
for ($i = 0; $i -lt 20; $i++) {
    try { Set-Clipboard -Value $path; break } catch { Start-Sleep -Milliseconds 50 }
}
exit 0
'@ | Set-Content -Path $savePs -Encoding UTF8
Write-Host "Wrote $savePs" -ForegroundColor Green

# --- 3. Write the AutoHotkey interceptor -------------------------------
$ahkScript = Join-Path $dir 'clip-paste.ahk'
@'
#Requires AutoHotkey v2.0
#SingleInstance Force
; In Windows Terminal, if Ctrl+V is pressed while the clipboard holds an image,
; save it to a PNG, put the file path on the clipboard, then paste the path.
; Claude Code reads the pasted image-file path and loads the image.
; Non-image clipboard content pastes as usual.
; The probe/wait loops ride out the race where the screenshot tool is still
; writing the clipboard or it is briefly locked -- the "works sometimes" bug.
psScript := A_ScriptDir "\save-clip-image.ps1"
#HotIf WinActive("ahk_exe WindowsTerminal.exe")
^v:: {
    global psScript
    ; The clipboard can be briefly locked right after a screenshot; retry the probe.
    hasImage := false
    Loop 10 {
        if (DllCall("IsClipboardFormatAvailable", "UInt", 8)   ; CF_DIB
            || DllCall("IsClipboardFormatAvailable", "UInt", 2)) {  ; CF_BITMAP
            hasImage := true
            break
        }
        Sleep 30
    }
    if (hasImage) {
        RunWait('powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "' psScript '"', , "Hide")
        ; Wait until the path text has actually replaced the image on the clipboard.
        Loop 40 {
            if (A_Clipboard ~= "i)\.png$")
                break
            Sleep 25
        }
    }
    Send("^v")
}
#HotIf
'@ | Set-Content -Path $ahkScript -Encoding UTF8
Write-Host "Wrote $ahkScript" -ForegroundColor Green

# --- 4. Auto-start on login (Startup folder shortcut) ------------------
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'cc-clip-paste.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = $ahk
$sc.Arguments = '"' + $ahkScript + '"'
$sc.WorkingDirectory = $dir
$sc.Description = 'Ctrl+V image paste for Claude Code in Windows Terminal'
$sc.Save()
Write-Host "Startup shortcut: $lnk" -ForegroundColor Green

# --- 5. Unbind Ctrl+V in Windows Terminal so the key reaches the app ---
$wtPaths = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)
foreach ($wt in $wtPaths) {
    if (-not (Test-Path $wt)) { continue }
    try {
        $json = Get-Content $wt -Raw | ConvertFrom-Json
        $kept = @()
        if ($json.PSObject.Properties.Name -contains 'keybindings' -and $json.keybindings) {
            $kept = @($json.keybindings | Where-Object { $_.keys -ne 'ctrl+v' })
        }
        $kept += [pscustomobject]@{ command = 'unbound'; keys = 'ctrl+v' }
        if ($json.PSObject.Properties.Name -contains 'keybindings') {
            $json.keybindings = $kept
        } else {
            $json | Add-Member -NotePropertyName keybindings -NotePropertyValue $kept
        }
        ($json | ConvertTo-Json -Depth 32) | Set-Content -Path $wt -Encoding UTF8
        Write-Host "Unbound Ctrl+V in: $wt" -ForegroundColor Green
    } catch {
        Write-Host "Could not auto-edit $wt -- unbind Ctrl+V manually. ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# --- 6. (Re)launch the interceptor now ---------------------------------
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
    Where-Object { $_.CommandLine -like '*clip-paste.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process -FilePath $ahk -ArgumentList ('"' + $ahkScript + '"')

Write-Host ""
Write-Host "Done. Open a NEW Windows Terminal tab, then: Alt+V screenshot -> Ctrl+V in Claude Code." -ForegroundColor Cyan
