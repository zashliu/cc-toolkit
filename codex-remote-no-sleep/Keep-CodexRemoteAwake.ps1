[CmdletBinding()]
param(
    [ValidateRange(5, 3600)]
    [int]$RefreshSeconds = 30
)

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CodexRemotePower {
    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@

$keepAwake = [CodexRemotePower]::ES_CONTINUOUS -bor `
    [CodexRemotePower]::ES_SYSTEM_REQUIRED -bor `
    [CodexRemotePower]::ES_DISPLAY_REQUIRED

function Set-CodexRemoteAwake {
    if ([CodexRemotePower]::SetThreadExecutionState($keepAwake) -eq 0) {
        throw "Windows could not request an awake display and system."
    }
}

Set-CodexRemoteAwake
Write-Host "Codex remote awake mode is active. Press Ctrl+C to stop."
Write-Host "The display and system will stay awake only while this window is running."

try {
    while ($true) {
        Start-Sleep -Seconds $RefreshSeconds
        Set-CodexRemoteAwake
    }
}
finally {
    [CodexRemotePower]::SetThreadExecutionState(
        [CodexRemotePower]::ES_CONTINUOUS
    ) | Out-Null
    Write-Host "Codex remote awake mode stopped. Normal power settings are restored."
}
