# =====================================================================
# setup-notify.ps1
# Plays a notification sound when Codex / Claude Code / Gemini CLI finishes a turn,
# so you know to come back and check the result.
#
#   Codex       -> "notify" in ~/.codex/config.toml
#   Claude Code -> "Stop" hook        (fires when the response ends)
#   Gemini CLI  -> "AfterAgent" hook  (fires once per turn after final reply)
#
# The alarm plays without touching other apps' volume or mute state, so an
# interrupted alarm can never leave the system silent.
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
# Displays a topmost WinForms MessageBox and plays a looping alarm sound until dismissed.
# Does NOT touch other apps' volume or mute state, so an interrupted alarm can never
# leave the system muted.
# Gemini CLI hooks require stdout to contain ONLY JSON; "{}" is a no-op.
$ErrorActionPreference = 'SilentlyContinue'
try {
    Add-Type -AssemblyName System.Windows.Forms

    # Make sure the alarm will actually be heard: unmute the default output
    # device and lift the volume off the floor. This NEVER mutes anything and
    # never touches other apps, so it can't leave the system silent.
    if (-not ([System.Management.Automation.PSTypeName]'CcNotify.Vol').Type) {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        namespace CcNotify {
            [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] internal class MMDeviceEnumerator {}
            [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface IMMDeviceEnumerator { int NotImpl1(); [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint); }
            [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }
            [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] internal interface IAudioEndpointVolume { [PreserveSig] int RegisterControlChangeNotify(IntPtr n); [PreserveSig] int UnregisterControlChangeNotify(IntPtr n); [PreserveSig] int GetChannelCount(out int c); [PreserveSig] int SetMasterVolumeLevel(float d, ref Guid ctx); [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, ref Guid ctx); [PreserveSig] int GetMasterVolumeLevel(out float d); [PreserveSig] int GetMasterVolumeLevelScalar(out float pfLevel); [PreserveSig] int SetChannelVolumeLevel(uint ch, float d, ref Guid ctx); [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float l, ref Guid ctx); [PreserveSig] int GetChannelVolumeLevel(uint ch, out float d); [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float l); [PreserveSig] int SetMute(bool bMute, ref Guid ctx); [PreserveSig] int GetMute(out bool pbMute); }
            public class Vol {
                public static void EnsureAudible() {
                    try {
                        // Unmute the default device for all roles (console/multimedia/comms)
                        foreach (int role in new int[] { 0, 1, 2 }) {
                            try {
                                IMMDeviceEnumerator de = (IMMDeviceEnumerator)new MMDeviceEnumerator();
                                IMMDevice dev; if (de.GetDefaultAudioEndpoint(0, role, out dev) != 0 || dev == null) continue;
                                Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
                                dev.Activate(ref iid, 23, IntPtr.Zero, out o);
                                IAudioEndpointVolume ep = (IAudioEndpointVolume)o;
                                Guid ctx = Guid.Empty;
                                ep.SetMute(false, ref ctx);
                                float v; ep.GetMasterVolumeLevelScalar(out v);
                                if (v < 0.2f) ep.SetMasterVolumeLevelScalar(0.5f, ref ctx);
                            } catch {}
                        }
                    } catch {}
                }
            }
        }
"@
    }
    [CcNotify.Vol]::EnsureAudible()

    # Try to find a loud alarm/ring sound
    $wav = Join-Path $env:WINDIR 'Media\Alarm02.wav'
    if (-not (Test-Path $wav)) { $wav = Join-Path $env:WINDIR 'Media\Ring01.wav' }
    if (-not (Test-Path $wav)) { $wav = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav' }

    if (Test-Path $wav) {
        $player = New-Object System.Media.SoundPlayer $wav
        $player.PlayLooping()
    } else {
        $beepJob = Start-Job -ScriptBlock { while($true) { [console]::beep(880, 200); Start-Sleep -Milliseconds 200 } }
    }

    $options = [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly -bor [System.Windows.Forms.MessageBoxOptions]::ServiceNotification
    [System.Windows.Forms.MessageBox]::Show(
        "Calculation completed! Check the terminal.",
        "AI CLI Assistant",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Exclamation,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1,
        $options
    ) | Out-Null

    if ($player) { $player.Stop() }
    if ($beepJob) { Stop-Job $beepJob; Remove-Job $beepJob }
} catch { }

# Output ONLY JSON to stdout to satisfy Claude/Gemini CLI hooks requirement
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
        # Filter out existing notify-sound hooks so we can replace them cleanly
        foreach ($d in @($hooks.$Event)) {
            $hasNotifySound = $false
            foreach ($h in @($d.hooks)) {
                if ($h.command -like "*notify-sound.ps1*") {
                    $hasNotifySound = $true
                }
            }
            if (-not $hasNotifySound) {
                $defs += $d
            }
        }
    }

    # build our hook entry
    $entry = [ordered]@{ type = 'command'; command = $Command }
    if ($HookName) { $entry['name'] = $HookName }
    
    # build outer object with matcher if required (e.g. Gemini's AfterAgent)
    $newDefProps = [ordered]@{ hooks = @([pscustomobject]$entry) }
    if ($Event -eq 'AfterAgent') {
        $newDefProps['matcher'] = '*'
    } elseif ($Event -eq 'Notification') {
        $newDefProps['matcher'] = 'permission_prompt|idle_prompt'
    }
    $newDef = [pscustomobject]$newDefProps

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

# --- Claude Code (~/.claude/settings.json, "Stop" & "Notification") --------------------
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (Test-Path $claudeDir) {
    Add-CompletionHook -SettingsPath (Join-Path $claudeDir 'settings.json') -Event 'Stop' -Command $cmd -HookName ''
    Add-CompletionHook -SettingsPath (Join-Path $claudeDir 'settings.json') -Event 'Notification' -Command $cmd -HookName ''
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

# --- Codex CLI (~/.codex/config.toml, user-level "notify") -------------
# Codex accepts a command array and appends a JSON notification payload to it.
# Keep this at user level: project-local Codex config cannot override notify.
$codexConfig = Join-Path (Join-Path $env:USERPROFILE '.codex') 'config.toml'
if (Test-Path $codexConfig) {
    $tomlSoundPath = $soundPs.Replace('\', '\\').Replace('"', '\"')
    $notifyLine = 'notify = [ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "' + $tomlSoundPath + '" ]'
    $tomlLines = @(Get-Content -LiteralPath $codexConfig)
    $notifyIndexes = @(
        0..($tomlLines.Count - 1) | Where-Object { $tomlLines[$_] -match '^\s*notify\s*=' }
    )
    if ($notifyIndexes.Count -gt 0) {
        $tomlLines[$notifyIndexes[0]] = $notifyLine
        if ($notifyIndexes.Count -gt 1) {
            $tomlLines = @(
                for ($i = 0; $i -lt $tomlLines.Count; $i++) {
                    if ($notifyIndexes -notcontains $i -or $i -eq $notifyIndexes[0]) { $tomlLines[$i] }
                }
            )
        }
    } else {
        $tomlLines += $notifyLine
    }
    [System.IO.File]::WriteAllLines($codexConfig, $tomlLines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Added Codex notify -> $codexConfig" -ForegroundColor Green
} else {
    Write-Host "Codex CLI (~/.codex/config.toml) not found - skipped." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. RESTART Codex / Claude Code / Gemini CLI for the notification settings to load." -ForegroundColor Cyan
Write-Host "Test the sound now:  powershell -File `"$soundPs`"" -ForegroundColor Cyan
