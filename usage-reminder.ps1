[CmdletBinding()]
param(
    [ValidateSet('Install', 'Notify', 'ShowNext')]
    [string]$Action = 'Install',
    [string]$ConfigPath,
    [string]$Provider,
    [string]$Period
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'usage-reminders.json' }
$scriptPath = Join-Path $scriptRoot 'usage-reminder.ps1'
$TaskPrefix = 'CC Toolkit - AI usage reset'

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.reminders) { throw 'Config must contain a reminders array.' }
    return $config
}

function Get-NextReset([object]$reminder) {
    $anchor = [DateTimeOffset]::Parse($reminder.anchor)
    $now = [DateTimeOffset]::Now
    $interval = if ($reminder.period -eq '5h') {
        [TimeSpan]::FromHours(5)
    } else {
        [TimeSpan]::FromDays(7)
    }

    if ($anchor -gt $now) { return $anchor }
    $steps = [math]::Ceiling(($now - $anchor).TotalSeconds / $interval.TotalSeconds)
    return $anchor.AddTicks([int64]($interval.Ticks * $steps))
}

function Show-Reminder([object]$reminder) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Media.SystemSounds]::Exclamation.Play()
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "$($reminder.provider) usage reset"
    $notify.BalloonTipText = "The $($reminder.period) limit should have refreshed. You can use $($reminder.provider) now."
    $notify.Visible = $true
    $notify.ShowBalloonTip(10000)
    Start-Sleep -Seconds 11
    $notify.Dispose()
}

function Install-Reminder([object]$reminder) {
    if ($reminder.enabled -eq $false) { return }
    $next = Get-NextReset $reminder
    $taskName = "$TaskPrefix - $($reminder.provider) $($reminder.period)"
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Notify -Provider `"$($reminder.provider)`" -Period `"$($reminder.period)`" -ConfigPath `"$ConfigPath`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
    $trigger = New-ScheduledTaskTrigger -Once -At $next.LocalDateTime
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Output "$taskName -> $($next.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
}

switch ($Action) {
    'Install' {
        $config = Read-Config
        foreach ($reminder in $config.reminders) { Install-Reminder $reminder }
    }
    'Notify' {
        $config = Read-Config
        $reminder = @($config.reminders | Where-Object { $_.provider -eq $Provider -and $_.period -eq $Period })[0]
        if (-not $reminder) { throw "Reminder not found: $Provider / $Period" }
        if ($reminder.enabled -eq $false) { throw "Reminder is disabled: $Provider / $Period. Set enabled to true after entering its reset anchor." }
        Show-Reminder $reminder
        Install-Reminder $reminder
    }
    'ShowNext' {
        $config = Read-Config
        foreach ($reminder in $config.reminders) {
            if ($reminder.enabled -eq $false) { continue }
            $next = Get-NextReset $reminder
            Write-Output "$($reminder.provider) $($reminder.period): $($next.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        }
    }
}
