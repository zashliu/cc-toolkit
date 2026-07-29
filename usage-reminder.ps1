[CmdletBinding()]
param(
    [ValidateSet('Install', 'Poll', 'ShowNext')]
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
$taskName = 'CC Toolkit - Claude usage watcher'
$oldTaskNames = @(
    'CC Toolkit - AI usage reset - Claude Code 5h',
    'CC Toolkit - AI usage reset - Claude Code weekly'
)

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
        updated_at = [DateTimeOffset]::Now.ToUniversalTime().ToString('o')
        five_hour = Get-WindowSnapshot $usage.five_hour
        seven_day = Get-WindowSnapshot $usage.seven_day
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-State([object]$snapshot) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Test-ActualReset([object]$before, [object]$after) {
    if (-not $before -or -not $after) { return $false }
    $oldReset = [DateTimeOffset]::Parse($before.resets_at)
    $newReset = [DateTimeOffset]::Parse($after.resets_at)
    $oldUtilization = [double]$before.utilization
    $newUtilization = [double]$after.utilization

    # A refresh is only accepted when the API reports a new future window and
    # usage falls. A clock reaching the old reset_at alone is never enough.
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
    } else {
        [System.Media.SystemSounds]::Exclamation.Play()
    }
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

function Install-PollTask([int]$minutes) {
    $next = (Get-Date).AddMinutes([math]::Max(1, $minutes))
    $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Action Poll -ConfigPath `"$ConfigPath`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
    $trigger = New-ScheduledTaskTrigger -Once -At $next
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Install-Watcher {
    $config = Read-Config
    foreach ($oldTask in $oldTaskNames) {
        Unregister-ScheduledTask -TaskName $oldTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    Install-PollTask ([int]$config.claude.poll_minutes)
    Invoke-Poll $config
}

function Invoke-Poll([object]$config) {
    try {
        $usage = Get-ClaudeUsage
        $current = Get-Snapshot $usage
        $previous = Read-State
        $resetMessages = @()
        if (Test-ActualReset $previous.five_hour $current.five_hour) {
            $resetMessages += "5-hour usage is now $([math]::Round($current.five_hour.utilization))%."
        }
        if (Test-ActualReset $previous.seven_day $current.seven_day) {
            $resetMessages += "Weekly usage is now $([math]::Round($current.seven_day.utilization))%."
        }
        Write-State $current
        if ($resetMessages.Count -gt 0) { Show-Alarm ($resetMessages -join ' ') }
        Write-Output ("Claude usage checked at {0}. 5h={1}% weekly={2}%" -f (Get-Date), [math]::Round($current.five_hour.utilization), [math]::Round($current.seven_day.utilization))
    } catch {
        Write-Warning ("Claude usage check failed: {0}" -f $_.Exception.Message)
    } finally {
        Install-PollTask ([int]$config.claude.poll_minutes)
    }
}

switch ($Action) {
    'Install' { Install-Watcher }
    'Poll' { Invoke-Poll (Read-Config) }
    'ShowNext' {
        $usage = Get-ClaudeUsage
        $snapshot = Get-Snapshot $usage
        "Claude Code 5h: $($snapshot.five_hour.resets_at) ($([math]::Round($snapshot.five_hour.utilization))% used)"
        "Claude Code weekly: $($snapshot.seven_day.resets_at) ($([math]::Round($snapshot.seven_day.utilization))% used)"
    }
}
