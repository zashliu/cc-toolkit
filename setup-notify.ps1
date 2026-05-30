# =====================================================================
# setup-notify.ps1
# Plays a notification sound when Claude Code / Gemini CLI finishes a turn,
# so you know to come back and check the result.
#
#   Claude Code -> "Stop" hook        (fires when the response ends)
#   Gemini CLI  -> "AfterAgent" hook  (fires once per turn after final reply)
#
# Idempotent & machine-agnostic. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File .\setup-notify.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'

Write-Host "== AI CLI 'turn finished' notification sound setup ==" -ForegroundColor Cyan

# --- runtime folder + the sound script --------------------------------
$dir = Join-Path $env:USERPROFILE '.cc-notify'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$soundPs = Join-Path $dir 'notify-sound.ps1'

@'
# Plays a short notification sound, then prints "{}" to stdout.
# Gemini CLI hooks require stdout to contain ONLY JSON; "{}" is a no-op
# for both Gemini (AfterAgent) and Claude Code (Stop).
$ErrorActionPreference = 'SilentlyContinue'
try {
    $wav = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav'
    if (-not (Test-Path $wav)) { $wav = Join-Path $env:WINDIR 'Media\notify.wav' }
    if (Test-Path $wav) {
        (New-Object System.Media.SoundPlayer $wav).PlaySync()
    } else {
        [console]::beep(880, 150); [console]::beep(1175, 250)
    }
} catch {
    try { [console]::beep(880, 200) } catch { }
}
Write-Output '{}'
'@ | Out-File -FilePath $soundPs -Encoding ascii
Write-Host "Wrote $soundPs" -ForegroundColor Green

# command both CLIs will invoke on completion
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$soundPs`""

# --- helper: merge a completion hook into a CLI's settings.json --------
function Add-CompletionHook {
    param(
        [string]$SettingsPath,  # path to settings.json
        [string]$Event,         # "Stop" (Claude) or "AfterAgent" (Gemini)
        [string]$Command,
        [string]$HookName       # optional friendly name ("" to omit)
    )
    if (Test-Path $SettingsPath) {
        $raw = Get-Content $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { $json = [pscustomobject]@{} }
        else { $json = $raw | ConvertFrom-Json }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $SettingsPath) | Out-Null
        $json = [pscustomobject]@{}
    }

    # ensure .hooks object
    if (-not ($json.PSObject.Properties.Name -contains 'hooks') -or $null -eq $json.hooks) {
        $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $hooks = $json.hooks

    # existing definitions for this event
    $defs = @()
    if (($hooks.PSObject.Properties.Name -contains $Event) -and $hooks.$Event) {
        $defs = @($hooks.$Event)
    }

    # already configured? (same command anywhere in this event)
    $already = $false
    foreach ($d in $defs) {
        foreach ($h in @($d.hooks)) {
            if ($h.command -eq $Command) { $already = $true }
        }
    }

    if ($already) {
        Write-Host "Already configured: $Event in $SettingsPath" -ForegroundColor DarkGray
        return
    }

    # build our hook entry
    $entry = [ordered]@{ type = 'command'; command = $Command }
    if ($HookName) { $entry['name'] = $HookName }
    $newDef = [pscustomobject]@{ hooks = @([pscustomobject]$entry) }

    $defs = @($defs) + $newDef
    if ($hooks.PSObject.Properties.Name -contains $Event) {
        $hooks.$Event = [object[]]$defs
    } else {
        $hooks | Add-Member -NotePropertyName $Event -NotePropertyValue ([object[]]$defs) -Force
    }

    # write back as UTF-8 WITHOUT BOM (JSON parsers choke on a leading BOM)
    $out = $json | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($SettingsPath, $out, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Added $Event hook -> $SettingsPath" -ForegroundColor Green
}

# --- Claude Code (~/.claude/settings.json, "Stop") --------------------
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (Test-Path $claudeDir) {
    Add-CompletionHook -SettingsPath (Join-Path $claudeDir 'settings.json') -Event 'Stop' -Command $cmd -HookName ''
} else {
    Write-Host "Claude Code (~/.claude) not found - skipped." -ForegroundColor Yellow
}

# --- Gemini CLI (~/.gemini/settings.json, "AfterAgent") ---------------
$geminiDir = Join-Path $env:USERPROFILE '.gemini'
if (Test-Path $geminiDir) {
    Add-CompletionHook -SettingsPath (Join-Path $geminiDir 'settings.json') -Event 'AfterAgent' -Command $cmd -HookName 'cc-notify-sound'
} else {
    Write-Host "Gemini CLI (~/.gemini) not found - skipped." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. RESTART Claude Code / Gemini CLI for the hook to load." -ForegroundColor Cyan
Write-Host "Test the sound now:  powershell -File `"$soundPs`"" -ForegroundColor Cyan
