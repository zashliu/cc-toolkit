# =====================================================================
# setup-sharex-paste.ps1
# Enables: ShareX screenshot -> Ctrl+V / right-click to paste it into
# Claude Code, in ANY terminal (no AutoHotkey, no background process).
#
# How: switches ShareX's "after capture" task to save the file and copy
# the FILE PATH (plain text) to the clipboard instead of the image.
# Every terminal can paste text, and Claude Code loads the image from
# that path. A lighter-weight alternative to setup-clip-paste.ps1 for
# people who already use ShareX.
#
# Idempotent & machine-agnostic. Safe to re-run.
#     powershell -ExecutionPolicy Bypass -File .\setup-sharex-paste.ps1
#     powershell -ExecutionPolicy Bypass -File .\setup-sharex-paste.ps1 -Revert
# =====================================================================
[CmdletBinding()]
param(
    [switch]$Revert
)
$ErrorActionPreference = 'Stop'

Write-Host "== ShareX -> Claude Code paste setup ==" -ForegroundColor Cyan

$applyValue  = 'SaveImageToFile, CopyFilePathToClipboard'
$revertValue = 'CopyImageToClipboard, SaveImageToFile'
$targetValue = if ($Revert) { $revertValue } else { $applyValue }

# --- 1. Locate ShareX config ------------------------------------------
$candidates = @(
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShareX\ApplicationConfig.json'),
    (Join-Path $env:USERPROFILE 'Documents\ShareX\ApplicationConfig.json'),
    (Join-Path $env:LOCALAPPDATA 'ShareX\ApplicationConfig.json')
) | Select-Object -Unique
$config = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $config) {
    throw ("ShareX ApplicationConfig.json not found. Install ShareX and run it once first.`nChecked:`n" + ($candidates -join "`n"))
}
Write-Host "Config file : $config" -ForegroundColor Green

# --- 2. Stop ShareX if running (remember its exe to restart) -----------
$proc = Get-Process ShareX -ErrorAction SilentlyContinue
$shareXPath = $null
if ($proc) {
    $shareXPath = ($proc | Select-Object -First 1).Path
    Write-Host "Stopping ShareX so it won't overwrite the change on exit..." -ForegroundColor Yellow
    Stop-Process -Name ShareX -Force
    Start-Sleep -Milliseconds 800
}

# --- 3. Back up the config --------------------------------------------
$backup = "$config.bak"
Copy-Item $config $backup -Force
Write-Host "Backup made  : $backup" -ForegroundColor Green

# --- 4. Replace the first AfterCaptureJob value (DefaultTaskSettings;  -
#        capture hotkeys with UseDefaultAfterCaptureJob=true inherit it) -
$text = Get-Content $config -Raw
$pattern = '("AfterCaptureJob":\s*")[^"]*(")'
if ($text -notmatch $pattern) {
    throw "AfterCaptureJob not found in config; aborting. Backup left at $backup"
}
$newText = ([regex]$pattern).Replace($text, "`${1}$targetValue`${2}", 1)
# Write back as UTF-8 WITHOUT BOM (matches ShareX's own format)
[System.IO.File]::WriteAllText($config, $newText, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Set AfterCaptureJob = $targetValue" -ForegroundColor Green

# --- 5. Restart ShareX if it had been running -------------------------
if ($shareXPath -and (Test-Path $shareXPath)) {
    Start-Process $shareXPath
    Write-Host "Restarted ShareX." -ForegroundColor Green
} elseif ($proc) {
    Write-Host "ShareX was running but its exe path was unknown - start it manually." -ForegroundColor Yellow
}

Write-Host ""
if ($Revert) {
    Write-Host "Reverted: ShareX copies the image to the clipboard again." -ForegroundColor Cyan
} else {
    Write-Host "Done. Take a ShareX screenshot, then Ctrl+V (or right-click) in Claude Code." -ForegroundColor Cyan
}
