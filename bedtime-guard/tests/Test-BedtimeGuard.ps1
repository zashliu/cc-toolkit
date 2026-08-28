[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestDir = $PSScriptRoot
$GuardPath = Join-Path $TestDir '..\BedtimeGuard.ps1'
$CorePath = (Get-Item -LiteralPath (Join-Path $TestDir '..\BedtimeGuard.Core.psm1')).FullName
$InstallPath = Join-Path $TestDir '..\Install.ps1'
$NotifyPath = Join-Path $TestDir '..\Notify.ps1'
$WatchdogPath = Join-Path $TestDir '..\Watchdog.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function New-TestStateDir([string]$Name) {
    $path = Join-Path $env:TEMP ("bedtime-guard-{0}-{1}" -f $Name, $PID)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

$coreModule = Import-Module -Name $CorePath -Force -PassThru
$WindowStateCommand = $coreModule.ExportedCommands['Get-WindowState']
if (-not $WindowStateCommand) { throw 'Core window function was not exported' }

$start = 23 * 60 + 45
$end = 6 * 60
$night = '2026-08-19'
$warning = 180

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:41:59') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True (-not $r.InWindow -and -not $r.InWarning) '23:41:59 is outside warning window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:42:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWarning -and $r.SecondsUntilWindowStart -eq 180) '23:42:00 enters warning window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:44:59') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWarning -and $r.SecondsUntilWindowStart -eq 1) '23:44:59 remains in warning window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:45:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWindow -and -not $r.InWarning) '23:45:00 enters immediate shutdown window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-20 00:30:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWindow -and $r.NightId -eq $night) 'after midnight remains part of previous night'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-20 06:00:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True (-not $r.InWindow -and -not $r.InWarning -and $r.NightId -eq '') '06:00 exits shutdown window'

$guardText = Get-Content $GuardPath -Raw
$installText = Get-Content $InstallPath -Raw
$notifyText = Get-Content $NotifyPath -Raw
$watchdogText = Get-Content $WatchdogPath -Raw

Assert-True ($guardText -match 'Invoke-ShutdownNow' -and $guardText -match 'shutdown /s /f /t 0') 'guard uses immediate forced shutdown'
Assert-True ($guardText -notmatch 'delayUntilTick|delayUsedNight|RequestFile|TonightFile|Invoke-AbortShutdown|shutdown /a') 'guard contains no postpone path'
Assert-True ($guardText -notmatch 'Get-Date') 'guard policy and logs do not read local wall clock'
Assert-True ($installText -match "/tn 'BedtimeGuard'.*/sc onstart") 'guard uses startup trigger'
Assert-True ($installText -match "/tn 'BedtimeGuardWatchdog'.*/sc onstart") 'watchdog uses startup trigger'
Assert-True ($installText -match "/tn 'BedtimeGuardNotify'.*/sc onlogon") 'notifier uses logon trigger'
Assert-True ($installText -notmatch 'usersRequest' -and -not (Test-Path (Join-Path $TestDir '..\Postpone-Tonight.ps1'))) 'installer exposes no postpone inbox or helper'
Assert-True ($installText -match "'delay-request\.flag','tonight\.json','Postpone-Tonight\.ps1','runtime\.json'") 'installer removes legacy postpone state'
Assert-True ($notifyText -match 'policyVersion' -and $notifyText -match 'Start-Sleep -Seconds \$PollSeconds') 'notifier is resident and rejects old runtime'
Assert-True ($notifyText -notmatch 'RequestFile|shutdown /a|btnDelay|delayAvailable') 'notifier exposes no postpone control'
Assert-True ($watchdogText -match '/sc onlogon' -and $watchdogText -match 'notify process not running') 'watchdog repairs resident notifier'

$saved = @{}
$envNames = @(
    'BEDTIME_STATE_DIR',
    'BEDTIME_TEST_FORCE_WINDOW',
    'BEDTIME_TEST_NOSHUTDOWN',
    'BEDTIME_TEST_FORCE_OFFLINE',
    'BEDTIME_TEST_TRUSTED_UTC',
    'BEDTIME_OFFLINE_GRACE_MINUTES',
    'BEDTIME_BOOT_GRACE_MINUTES'
)
foreach ($name in $envNames) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

$createdDirs = @()
try {
    $staleDir = New-TestStateDir 'stale-delay'
    $createdDirs += $staleDir
    New-Item -ItemType Directory -Path (Join-Path $staleDir 'requests') -Force | Out-Null
    Set-Content -Path (Join-Path $staleDir 'requests\delay-request.flag') -Value 'legacy'
    Set-Content -Path (Join-Path $staleDir 'tonight.json') -Value '{"nightId":"2026-08-19","shiftMinutes":120}'
    Set-Content -Path (Join-Path $staleDir 'runtime.json') -Value '{"delayUntilTick":9223372036854770000,"delayUsedNight":"2026-08-07","delaying":true}'

    $env:BEDTIME_STATE_DIR = $staleDir
    $env:BEDTIME_TEST_NOSHUTDOWN = '1'
    $env:BEDTIME_TEST_TRUSTED_UTC = '2026-08-19T15:45:00Z'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardPath -Once
    Assert-True ($LASTEXITCODE -eq 0) 'stale-delay smoke execution succeeds'

    $log = Get-Content (Join-Path $staleDir 'guard.log') -Raw
    Assert-True ($log -match 'SHUTDOWN-NOW' -and $log -match 'TEST.*t=0') 'stale August delay cannot block immediate shutdown'
    Assert-True ($log -notmatch 'DELAY') 'stale postpone files are ignored'

    $runtime = Get-Content (Join-Path $staleDir 'runtime.json') -Raw | ConvertFrom-Json
    $runtimeNames = @($runtime.PSObject.Properties.Name)
    Assert-True ($runtime.policyVersion -eq 3) 'runtime schema is v3'
    Assert-True ($runtimeNames -notcontains 'delayUntilTick' -and $runtimeNames -notcontains 'delayUsedNight') 'runtime contains no delay state'
    Assert-True ($runtime.updatedUtc -eq '2026-08-19T15:45:00.0000000Z') 'decision uses injected trusted UTC'

    $offlineDir = New-TestStateDir 'offline'
    $createdDirs += $offlineDir
    $env:BEDTIME_STATE_DIR = $offlineDir
    $env:BEDTIME_TEST_TRUSTED_UTC = $null
    $env:BEDTIME_TEST_FORCE_OFFLINE = '1'
    $env:BEDTIME_OFFLINE_GRACE_MINUTES = '0'
    $env:BEDTIME_BOOT_GRACE_MINUTES = '0'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardPath -Once
    Assert-True ($LASTEXITCODE -eq 0) 'offline smoke execution succeeds'
    $offlineLog = Get-Content (Join-Path $offlineDir 'guard.log') -Raw
    Assert-True ($offlineLog -match 'UNTRUSTED' -and $offlineLog -match 'TEST.*t=0') 'offline grace expiry triggers immediate shutdown'
} finally {
    foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
    foreach ($path in $createdDirs) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}

Write-Host 'All BedtimeGuard v3 tests passed.' -ForegroundColor Cyan
