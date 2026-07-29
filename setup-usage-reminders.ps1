[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'usage-reminders.json' }
$script = Join-Path $scriptRoot 'usage-reminder.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "Missing $script" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing $ConfigPath" }

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Install -ConfigPath $ConfigPath
Write-Output 'Claude usage watcher installed. It reads the live usage endpoint every few minutes and only alerts after an observed reset.'
