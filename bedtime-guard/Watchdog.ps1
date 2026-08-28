# ============================================================
#  BedtimeGuard watchdog (SYSTEM / resident)
#
#  The scheduled task starts this script at boot; this process keeps monitoring
#  with monotonic sleep and does not depend on Windows wall-clock time.
# ============================================================

[CmdletBinding()]
param(
    # Test-only: run one cycle and exit. The installed task does not pass this.
    [switch]$Once
)

$Dir       = 'C:\ProgramData\BedtimeGuard'
$Guard     = Join-Path $Dir 'BedtimeGuard.ps1'
$NotifyVbs = Join-Path $Dir 'NotifyHidden.vbs'
$LogFile   = Join-Path $Dir 'guard.log'
$PollSeconds = 30

$GuardTaskName    = 'BedtimeGuard'
$NotifyTaskName   = 'BedtimeGuardNotify'
$GuardTr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Guard
$NotifyTr = 'wscript.exe "{0}"' -f $NotifyVbs

function Write-Log([string]$msg) {
    try {
        $tick = [int64]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)
        Add-Content -Path $LogFile -Value ("tick={0}  {1}" -f $tick, $msg) -ErrorAction SilentlyContinue
    } catch {}
}

function Ensure-GuardTask {
    schtasks /query /tn $GuardTaskName *> $null
    if ($LASTEXITCODE -ne 0) {
        schtasks /create /tn $GuardTaskName /tr $GuardTr /sc onstart /ru SYSTEM /rl HIGHEST /f *> $null
        Write-Log 'WATCHDOG guard task missing -> recreated as startup task'
    } else {
        schtasks /change /tn $GuardTaskName /enable *> $null
    }

    # The task can exist while its process has exited; the global mutex prevents duplicates.
    $running = $false
    try {
        $running = @(
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)\\BedtimeGuard\.ps1(?:"|\s|$)' }
        ).Count -gt 0
    } catch {}
    if (-not $running) {
        Start-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
        Write-Log 'WATCHDOG guard process not running -> start requested'
    }
}

function Ensure-NotifyTask {
    $interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $interactiveUser) { return }

    schtasks /query /tn $NotifyTaskName *> $null
    if ($LASTEXITCODE -ne 0) {
        schtasks /create /tn $NotifyTaskName /tr $NotifyTr /sc onlogon /ru $interactiveUser /rl LIMITED /it /f *> $null
        Write-Log ("WATCHDOG notify task missing -> recreated as logon task for {0}" -f $interactiveUser)
    } else {
        schtasks /change /tn $NotifyTaskName /enable *> $null
    }

    $running = $false
    try {
        $running = @(
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)\\Notify\.ps1(?:"|\s|$)' }
        ).Count -gt 0
    } catch {}
    if (-not $running) {
        Start-ScheduledTask -TaskName $NotifyTaskName -ErrorAction SilentlyContinue
        Write-Log 'WATCHDOG notify process not running -> start requested'
    }
}

function Invoke-WatchdogCycle {
    Ensure-GuardTask
    Ensure-NotifyTask
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\BedtimeGuardWatchdog')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { exit 0 }

    do {
        try {
            Invoke-WatchdogCycle
        } catch {
            Write-Log ("WATCHDOG-ERROR {0}" -f $_.Exception.Message)
        }
        if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
    } while (-not $Once)
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
