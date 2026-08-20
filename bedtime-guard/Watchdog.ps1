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
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $msg) -ErrorAction SilentlyContinue } catch {}
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
    schtasks /query /tn $NotifyTaskName *> $null
    if ($LASTEXITCODE -ne 0) {
        foreach ($u in (Get-CimInstance Win32_ComputerSystem).UserName) {
            if ($u) {
                schtasks /create /tn $NotifyTaskName /tr $NotifyTr /sc daily /st 23:00 /ri 1 /du 0007:30 /ru $u /rl LIMITED /it /f *> $null
                Write-Log ("WATCHDOG notify task missing -> recreated for {0}" -f $u)
                break
            }
        }
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
