# =====================================================================
# setup-sharex-paste.ps1
# Enables: ShareX screenshot -> Ctrl+V pastes it into Claude Code in ANY
# terminal AND uploads as an image in browsers (web ChatGPT/Gemini/...).
#
# How: switches ShareX's "after capture" task to save the file, then run
# a tiny helper script (via ShareX "Actions") that puts the screenshot
# on the clipboard in MULTIPLE formats at once:
#   - plain text (the file path)  -> terminals / Claude Code
#   - bitmap + PNG stream         -> browsers paste it as an image
#   - file drop (CF_HDROP)        -> web apps that accept pasted files
# ShareX's own clipboard jobs can't do this (each one overwrites the
# clipboard), hence the helper.
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

$applyValue  = 'SaveImageToFile, PerformActions'
$revertValue = 'CopyImageToClipboard, SaveImageToFile'
$targetValue = if ($Revert) { $revertValue } else { $applyValue }
$actionName  = 'cc-toolkit: clipboard path + image'
# ShareX runs an action only if File.Exists(Path) -- a bare "powershell.exe"
# fails that check and the action is silently skipped, so resolve it fully.
$psExe = (Get-Command powershell.exe).Source
# Per-hotkey: when applying, STOP deferring to the default (some capture
# hotkeys carry their own AfterCaptureJob that would otherwise win); when
# reverting, hand control back to the default.
$hotkeyUseDefault = [bool]$Revert

# --- 0. Install the clipboard helper script ---------------------------
# Runs after every capture (ShareX Action). Puts the screenshot on the
# clipboard as text path + bitmap + PNG + file drop simultaneously.
$helperDir  = Join-Path $env:LOCALAPPDATA 'cc-toolkit'
$helperPath = Join-Path $helperDir 'sharex-clip-both.ps1'
if (-not $Revert) {
    if (-not (Test-Path $helperDir)) { New-Item -ItemType Directory -Force $helperDir | Out-Null }
    $helperBody = @'
# sharex-clip-both.ps1 - installed by cc-toolkit setup-sharex-paste.ps1
# Put a screenshot on the clipboard in several formats AT ONCE:
#   text (file path) for terminals, bitmap/PNG for browsers,
#   file drop for web apps that accept pasted files.
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$bytes = [System.IO.File]::ReadAllBytes($Path)
$img   = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,$bytes)))

$data = New-Object System.Windows.Forms.DataObject
$data.SetText($Path)                                  # terminals / Claude Code
$data.SetImage($img)                                  # browsers (CF_BITMAP/DIB)
if ([System.IO.Path]::GetExtension($Path) -eq '.png') {
    # Chromium prefers the "PNG" format; keeps transparency
    $data.SetData('PNG', $false, (New-Object System.IO.MemoryStream(,$bytes)))
}
$files = New-Object System.Collections.Specialized.StringCollection
[void]$files.Add($Path)
$data.SetFileDropList($files)                         # paste-as-file upload

# copy=true so the data survives after this process exits; retry while busy
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
'@
    [System.IO.File]::WriteAllText($helperPath, $helperBody, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Helper installed : $helperPath" -ForegroundColor Green
}

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
$shareXDir = Split-Path $config

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

# --- 4. Replace the default AfterCaptureJob (DefaultTaskSettings) ------
# NOTE: not Get-Content -Raw -- PS 5.1 decodes BOM-less UTF-8 as ANSI,
# which silently corrupts non-ASCII strings (and thus the JSON) on write.
$text = [System.IO.File]::ReadAllText($config)
$pattern = '("AfterCaptureJob":\s*")[^"]*(")'
if ($text -notmatch $pattern) {
    throw "AfterCaptureJob not found in config; aborting. Backup left at $backup"
}
$newText = ([regex]$pattern).Replace($text, "`${1}$targetValue`${2}", 1)

# --- 4a. Register the helper as a ShareX Action (ExternalPrograms) -----
# PerformActions runs every active entry in DefaultTaskSettings.ExternalPrograms
# with %input = the saved file path. Edited via targeted regex (NOT a full
# JSON round-trip, which mangles ShareX's date fields in PowerShell 5.1).
$nameEsc = [regex]::Escape($actionName)
if ($Revert) {
    # Leave the entry in place but deactivate it (harmless either way,
    # since PerformActions is no longer in AfterCaptureJob).
    $flip = '("IsActive":\s*)true(,?\s*"Name":\s*"' + $nameEsc + '")'
    $newText = ([regex]$flip).Replace($newText, '${1}false${2}', 1)
} else {
    $helperJson = $helperPath -replace '\\', '\\'   # \ -> \\ (JSON escape)
    $psExeJson  = $psExe -replace '\\', '\\'
    $entry = '{"IsActive": true, "Name": "' + $actionName + '", ' +
             '"Path": "' + $psExeJson + '", ' +
             '"Args": "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $helperJson + '\" \"%input\"", ' +
             '"OutputExtension": "", "Extensions": "", "HiddenWindow": true, "DeleteInputFile": false}'
    # Remove any stale copy of our entry first, then (re)insert fresh.
    # The entry object has no nested braces, so [^{}] matches it exactly.
    $ours = '\{[^{}]*"Name":\s*"' + $nameEsc + '"[^{}]*\}'
    foreach ($rm in @(('(\[)\s*' + $ours + '\s*(\])'), (',\s*' + $ours), ($ours + '\s*,\s*'))) {
        if ($newText -match $rm) {
            $newText = ([regex]$rm).Replace($newText, '${1}${2}', 1)
            break
        }
    }
    if ($newText -match '"ExternalPrograms":\s*\[\s*\]') {
        $newText = ([regex]'"ExternalPrograms":\s*\[\s*\]').Replace($newText, ('"ExternalPrograms": [' + $entry + ']'), 1)
    } elseif ($newText -match '"ExternalPrograms":\s*null') {
        $newText = ([regex]'"ExternalPrograms":\s*null').Replace($newText, ('"ExternalPrograms": [' + $entry + ']'), 1)
    } elseif ($newText -match '"ExternalPrograms":\s*\[') {
        $newText = ([regex]'("ExternalPrograms":\s*\[)').Replace($newText, ('${1}' + $entry + ', '), 1)
    } else {
        # Key absent entirely: inject it next to AfterCaptureJob (same object)
        $newText = ([regex]'("AfterCaptureJob":)').Replace($newText, ('"ExternalPrograms": [' + $entry + '], ${1}'), 1)
    }
    Write-Host "Registered ShareX action : $actionName" -ForegroundColor Green
}

# Write back as UTF-8 WITHOUT BOM (matches ShareX's own format)
[System.IO.File]::WriteAllText($config, $newText, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Set default AfterCaptureJob = $targetValue" -ForegroundColor Green

# --- 4b. Patch per-hotkey TaskSettings (HotkeysConfig.json) -----------
# Capture hotkeys can carry their OWN AfterCaptureJob that overrides the
# default above, so changing only the default silently does nothing for
# them -- the "set it, but Ctrl+V still pastes an image / does nothing" bug.
# Force every hotkey to the same job and stop deferring to the default.
$hotkeysCfg = Join-Path $shareXDir 'HotkeysConfig.json'
if (Test-Path $hotkeysCfg) {
    Copy-Item $hotkeysCfg "$hotkeysCfg.bak" -Force
    $hk = [System.IO.File]::ReadAllText($hotkeysCfg) | ConvertFrom-Json
    $patched = 0
    foreach ($e in @($hk.Hotkeys)) {
        if ($null -ne $e.TaskSettings) {
            $e.TaskSettings.UseDefaultAfterCaptureJob = $hotkeyUseDefault
            $e.TaskSettings.AfterCaptureJob = $targetValue
            # ShareX bug (#5831): a hotkey that overrides AfterCaptureJob does
            # NOT fall back to the default Actions list for PerformActions --
            # it only runs its OWN ExternalPrograms. So the entry must live in
            # each hotkey too, with UseDefaultActions off.
            $others = @($e.TaskSettings.ExternalPrograms) | Where-Object { $null -ne $_ -and $_.Name -ne $actionName }
            if ($Revert) {
                $e.TaskSettings | Add-Member -NotePropertyName UseDefaultActions -NotePropertyValue $true -Force
                $e.TaskSettings | Add-Member -NotePropertyName ExternalPrograms -NotePropertyValue @($others) -Force
            } else {
                $entryObj = [pscustomobject]@{
                    IsActive        = $true
                    Name            = $actionName
                    Path            = $psExe
                    Args            = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $helperPath + '" "%input"'
                    OutputExtension = ''
                    Extensions      = ''
                    HiddenWindow    = $true
                    DeleteInputFile = $false
                }
                $e.TaskSettings | Add-Member -NotePropertyName UseDefaultActions -NotePropertyValue $false -Force
                $e.TaskSettings | Add-Member -NotePropertyName ExternalPrograms -NotePropertyValue (@($entryObj) + $others) -Force
            }
            $patched++
        }
    }
    [System.IO.File]::WriteAllText($hotkeysCfg, ($hk | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Patched $patched hotkey(s)  : $hotkeysCfg" -ForegroundColor Green
} else {
    Write-Host "No HotkeysConfig.json (no custom capture hotkeys) - default is enough." -ForegroundColor DarkGray
}

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
    Write-Host "Done. Take a ShareX screenshot, then Ctrl+V:" -ForegroundColor Cyan
    Write-Host "  - in a terminal / Claude Code -> pastes the file path (image is loaded from it)"
    Write-Host "  - in a browser (web ChatGPT/Gemini/...) -> pastes/uploads the image itself"
}
