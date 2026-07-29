[CmdletBinding()]
param(
    [ValidateSet('Install', 'OnClaudeUse', 'ShowNext')]
    [string]$Action = 'Install',
    [string]$ConfigPath,
    [switch]$NoAlarm
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'usage-reminders.json' }
$scriptPath = Join-Path $scriptRoot 'usage-reminder.ps1'
$stateDir = Join-Path $env:LOCALAPPDATA 'cc-toolkit'
$statePath = Join-Path $stateDir 'usage-reminder-state.json'
$usageCommand = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action OnClaudeUse -ConfigPath `"$ConfigPath`""

function Read-Config {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.claude.enabled) { throw 'Claude usage watcher is disabled in usage-reminders.json.' }
    return $config
}

function Get-ClaudeUsage {
    $credentialsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path -LiteralPath $credentialsPath)) { throw "Claude credentials not found: $credentialsPath" }
    $credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
    $oauth = $credentials.claudeAiOauth
    if (-not $oauth.accessToken) { throw 'Claude OAuth access token not found. Start Claude Code and sign in again.' }
    if ($oauth.expiresAt -and ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oauth.expiresAt) -lt [DateTimeOffset]::Now.AddMinutes(5))) {
        throw 'Claude OAuth token is expired or nearly expired. Start Claude Code once to refresh it.'
    }
    $headers = @{
        Accept = 'application/json'
        'Content-Type' = 'application/json'
        'User-Agent' = 'claude-code-usage-reminder'
        Authorization = "Bearer $($oauth.accessToken)"
        'anthropic-beta' = 'oauth-2025-04-20'
    }
    return Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method Get -TimeoutSec 20
}

function Get-WindowSnapshot([object]$window) {
    if (-not $window -or -not $window.resets_at) { return $null }
    return [pscustomobject]@{
        utilization = [double]$window.utilization
        resets_at = ([DateTimeOffset]::Parse([string]$window.resets_at)).ToUniversalTime().ToString('o')
    }
}

function Get-Snapshot([object]$usage) {
    return [pscustomobject]@{
        five_hour = Get-WindowSnapshot $usage.five_hour
        seven_day = Get-WindowSnapshot $usage.seven_day
    }
}

function Get-BootId {
    return ([DateTimeOffset](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime().ToString('o')
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-State([object]$snapshot, [string]$bootId) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    [pscustomobject]@{
        boot_id = $bootId
        last_checked_at = [DateTimeOffset]::Now.ToUniversalTime().ToString('o')
        five_hour = $snapshot.five_hour
        seven_day = $snapshot.seven_day
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Test-ActualReset([object]$before, [object]$after) {
    if (-not $before -or -not $after) { return $false }
    $oldReset = [DateTimeOffset]::Parse($before.resets_at)
    $newReset = [DateTimeOffset]::Parse($after.resets_at)
    $oldUtilization = [double]$before.utilization
    $newUtilization = [double]$after.utilization
    $newWindow = $newReset -gt [DateTimeOffset]::Now
    $windowRolled = $oldReset -le [DateTimeOffset]::Now -and $newReset -gt $oldReset
    $usageDropped = $newUtilization -le [math]::Max(5, $oldUtilization - 10)
    return $newWindow -and $windowRolled -and $usageDropped
}

function Show-Alarm([string]$text) {
    if ($NoAlarm) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $wav = Join-Path $env:WINDIR 'Media\Alarm02.wav'
    if (-not (Test-Path -LiteralPath $wav)) { $wav = Join-Path $env:WINDIR 'Media\Ring01.wav' }
    $player = $null
    if (Test-Path -LiteralPath $wav) {
        $player = New-Object System.Media.SoundPlayer $wav
        $player.PlayLooping()
    } else { [System.Media.SystemSounds]::Exclamation.Play() }
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = 'Claude Code limit refreshed'
    $notify.BalloonTipText = $text
    $notify.Visible = $true
    $notify.ShowBalloonTip(12000)
    Start-Sleep -Seconds 13
    if ($player) { $player.Stop() }
    $notify.Dispose()
}

function Invoke-UsageCheck([object]$config) {
    $bootId = Get-BootId
    $previous = Read-State
    $now = [DateTimeOffset]::Now
    $due = (-not $previous) -or ($previous.boot_id -ne $bootId)
    if (-not $due -and $previous.last_checked_at) {
        $due = (($now - [DateTimeOffset]::Parse($previous.last_checked_at)).TotalHours -ge [double]$config.claude.check_after_hours)
    }
    if (-not $due) { return }

    $usage = Get-ClaudeUsage
    $current = Get-Snapshot $usage
    $messages = @()
    if (Test-ActualReset $previous.five_hour $current.five_hour) {
        $messages += "5-hour usage is now $([math]::Round($current.five_hour.utilization))%."
    }
    if (Test-ActualReset $previous.seven_day $current.seven_day) {
        $messages += "Weekly usage is now $([math]::Round($current.seven_day.utilization))%."
    }
    # Claude may return null after a window's clock expires and before the
    # next prompt creates the new active window. Keep the old window metadata
    # so the next real response can still be recognized as a refresh.
    $stored = [pscustomobject]@{
        five_hour = if ($current.five_hour) { $current.five_hour } else { $previous.five_hour }
        seven_day = if ($current.seven_day) { $current.seven_day } else { $previous.seven_day }
    }
    Write-State $stored $bootId
    if ($messages.Count -gt 0) { Show-Alarm ($messages -join ' ') }
}

function Install-ClaudeHook {
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    $settingsDir = Split-Path -Parent $settingsPath
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    if (Test-Path -LiteralPath $settingsPath) {
        $json = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    } else { $json = [pscustomobject]@{} }
    if (-not $json.hooks) { $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    $defs = @()
    foreach ($definition in @($json.hooks.Stop)) {
        $ours = @($definition.hooks) | Where-Object { $_.command -like '*usage-reminder.ps1*' }
        if (-not $ours) { $defs += $definition }
    }
    $defs += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $usageCommand; name = 'cc-toolkit-usage-check' }) }
    $json.hooks.Stop = [object[]]$defs
    $out = $json | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($settingsPath, $out, (New-Object System.Text.UTF8Encoding($false)))

    # Remove the old always-on polling task and force the next Claude use to query once.
    Unregister-ScheduledTask -TaskName 'CC Toolkit - Claude usage watcher' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'CC Toolkit - AI usage reset - Claude Code 5h' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'CC Toolkit - AI usage reset - Claude Code weekly' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Write-Output "Installed Claude Stop hook -> $settingsPath"
}

switch ($Action) {
    'Install' { Read-Config | Out-Null; Install-ClaudeHook }
    'OnClaudeUse' {
        try { $config = Read-Config; Invoke-UsageCheck $config } catch { [Console]::Error.WriteLine("cc-toolkit usage check failed: $($_.Exception.Message)") }
        Write-Output '{}'
    }
    'ShowNext' {
        $usage = Get-ClaudeUsage
        $snapshot = Get-Snapshot $usage
        if ($snapshot.five_hour) {
            "Claude Code 5h: $($snapshot.five_hour.resets_at) ($([math]::Round($snapshot.five_hour.utilization))% used)"
        } else {
            'Claude Code 5h: waiting for the next Claude prompt to create the active window'
        }
        if ($snapshot.seven_day) {
            "Claude Code weekly: $($snapshot.seven_day.resets_at) ($([math]::Round($snapshot.seven_day.utilization))% used)"
        } else {
            'Claude Code weekly: unavailable'
        }
    }
}
