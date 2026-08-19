[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestDir = $PSScriptRoot
$GuardPath = Join-Path $TestDir '..\BedtimeGuard.ps1'
$CorePath = (Get-Item -LiteralPath (Join-Path $TestDir '..\BedtimeGuard.Core.psm1')).FullName
$InstallPath = Join-Path $TestDir '..\Install.ps1'
$WatchdogPath = Join-Path $TestDir '..\Watchdog.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

$coreModule = Import-Module -Name $CorePath -Force -PassThru
$WindowStateCommand = $coreModule.ExportedCommands['Get-WindowState']
if (-not $WindowStateCommand) { throw 'Core window function was not exported' }

$start = 23 * 60 + 45
$end = 6 * 60
$night = '2026-08-19'
$warning = 180

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:41:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True (-not $r.InWindow -and -not $r.InWarning) '23:41 is outside warning window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:42:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWarning -and $r.NightId -eq $night) '23:42 enters warning window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-19 23:45:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWindow -and -not $r.InWarning) '23:45 enters shutdown window'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-20 00:30:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True ($r.InWindow -and $r.NightId -eq $night) 'after midnight remains part of previous night'

$r = & $WindowStateCommand -Beijing ([DateTime]'2026-08-20 06:00:00') -StartMinutes $start -EndMinutes $end -WarningLeadSeconds $warning -NightId $night
Assert-True (-not $r.InWindow -and -not $r.InWarning -and $r.NightId -eq '') '06:00 exits shutdown window'

$installText = Get-Content $InstallPath -Raw
$watchdogText = Get-Content $WatchdogPath -Raw
Assert-True ($installText -match "/tn 'BedtimeGuard'.*/sc onstart") 'guard uses startup trigger'
Assert-True ($installText -match "/tn 'BedtimeGuardWatchdog'.*/sc onstart") 'watchdog uses startup trigger'
Assert-True ($installText -match '\$RequestDir') 'installer creates request inbox'
Assert-True ($installText -match '\*S-1-5-32-545:\(OI\)\(CI\)\(RX\)') 'users get read-only app directory access'
Assert-True ($watchdogText -match 'Start-Sleep -Seconds \$PollSeconds') 'watchdog uses resident wait loop'

$stateDir = Join-Path $env:TEMP ("bedtime-guard-test-{0}" -f $PID)
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$saved = @{}
foreach ($name in 'BEDTIME_STATE_DIR','BEDTIME_TEST_FORCE_WINDOW','BEDTIME_TEST_NOSHUTDOWN','BEDTIME_TEST_OFFLINE_GRACE_MINUTES') {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$env:BEDTIME_STATE_DIR = $stateDir
$env:BEDTIME_TEST_FORCE_WINDOW = '1'
$env:BEDTIME_TEST_NOSHUTDOWN = '1'
$env:BEDTIME_OFFLINE_GRACE_MINUTES = '0'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $GuardPath -Once
$smokeExitCode = $LASTEXITCODE
Assert-True ($smokeExitCode -eq 0) 'one-shot guard execution succeeds'
$log = Get-Content (Join-Path $stateDir 'guard.log') -Raw
Assert-True ($log -match 'TEST|WARNING|DELAY') 'smoke test writes decision log'

foreach ($name in $saved.Keys) {
    [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
}
if (Test-Path -LiteralPath $stateDir) {
    Remove-Item -LiteralPath $stateDir -Recurse -Force
}

Write-Host 'All BedtimeGuard tests passed.' -ForegroundColor Cyan
