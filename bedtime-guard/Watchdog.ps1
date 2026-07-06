# ============================================================
#  BedtimeGuard 看门狗
#  确保主任务 BedtimeGuard 存在且处于启用状态；
#  若被删除/禁用，立即重建并启用。与主脚本互相监护。
# ============================================================

$Guard  = 'C:\ProgramData\BedtimeGuard\BedtimeGuard.ps1'
$LogFile = 'C:\ProgramData\BedtimeGuard\guard.log'
$GuardTr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Guard

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $msg) -ErrorAction SilentlyContinue } catch {}
}

# 主任务是否存在
schtasks /query /tn 'BedtimeGuard' *> $null
if ($LASTEXITCODE -ne 0) {
    schtasks /create /tn 'BedtimeGuard' /tr $GuardTr /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f *> $null
    Write-Log 'WATCHDOG 主任务缺失 -> 已重建 BedtimeGuard'
} else {
    # 存在则确保为启用状态（可能被手动禁用）
    schtasks /change /tn 'BedtimeGuard' /enable *> $null
}

# 弹窗器任务（用户会话）缺失则尽力重建（仅影响"友好弹窗+延迟"功能，非强制项）
schtasks /query /tn 'BedtimeGuardNotify' *> $null
if ($LASTEXITCODE -ne 0) {
    $notifyTr = 'wscript.exe "C:\ProgramData\BedtimeGuard\NotifyHidden.vbs"'
    foreach ($u in (Get-CimInstance Win32_ComputerSystem).UserName) {
        if ($u) { schtasks /create /tn 'BedtimeGuardNotify' /tr $notifyTr /sc daily /st 23:00 /ri 1 /du 0007:30 /ru $u /rl LIMITED /it /f *> $null }
    }
}
