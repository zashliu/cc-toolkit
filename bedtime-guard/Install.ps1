# 安装 BedtimeGuard：注册三个计划任务
#   BedtimeGuard         (SYSTEM)      —— 执行器：算时间、关机
#   BedtimeGuardWatchdog (SYSTEM)      —— 看门狗：与执行器互相监护
#   BedtimeGuardNotify   (当前用户/交互)—— 弹窗器：显示"延迟15分钟"弹窗
# 需以【管理员】身份运行本脚本
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$Dir      = 'C:\ProgramData\BedtimeGuard'
$Guard    = Join-Path $Dir 'BedtimeGuard.ps1'
$Watchdog = Join-Path $Dir 'Watchdog.ps1'
$Notify   = Join-Path $Dir 'Notify.ps1'

# 若从仓库/其它位置运行，先把脚本部署到 $Dir（从本脚本所在目录复制）
$Src = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($Src -and ($Src.TrimEnd('\') -ne $Dir.TrimEnd('\'))) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    foreach ($f in 'BedtimeGuard.ps1','Watchdog.ps1','Notify.ps1','NotifyHidden.vbs','Uninstall.ps1') {
        $s = Join-Path $Src $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $Dir $f) -Force }
    }
    Write-Host "[OK] 已将脚本部署到 $Dir" -ForegroundColor Green
}

foreach ($f in $Guard, $Watchdog, $Notify) { if (-not (Test-Path $f)) { throw "找不到 $f" } }

$guardTr  = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Guard
$wdTr     = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Watchdog
# 用 wscript 隐藏启动，避免弹窗器每分钟闪现命令行窗口
$notifyTr = 'wscript.exe "{0}\NotifyHidden.vbs"' -f $Dir

# 弹窗器要跑在交互用户会话里才能显示窗口
$interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $interactiveUser) { $interactiveUser = "$env:USERDOMAIN\$env:USERNAME" }

schtasks /create /tn 'BedtimeGuard'         /tr $guardTr  /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f | Out-Null
schtasks /create /tn 'BedtimeGuardWatchdog' /tr $wdTr     /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f | Out-Null
# 弹窗器只在夜间时段每分钟运行（23:00 起、持续 7.5 小时到次日 06:30），白天完全不启动
schtasks /create /tn 'BedtimeGuardNotify'   /tr $notifyTr /sc daily /st 23:00 /ri 1 /du 0007:30 /ru $interactiveUser /rl LIMITED /it /f | Out-Null

# 三个任务：允许电池供电时运行、错过后尽快补跑
foreach ($name in 'BedtimeGuard','BedtimeGuardWatchdog','BedtimeGuardNotify') {
    $t = Get-ScheduledTask -TaskName $name
    $t.Settings.DisallowStartIfOnBatteries = $false
    $t.Settings.StopIfGoingOnBatteries     = $false
    $t.Settings.StartWhenAvailable         = $true
    $t.Settings.ExecutionTimeLimit         = 'PT3M'
    Set-ScheduledTask -TaskName $name -Settings $t.Settings | Out-Null
}

Write-Host "[OK] 已安装 3 个计划任务。关机窗口：北京时间 23:45–06:00；关机前 180 秒倒计时，可延迟 15 分钟(每晚一次)。" -ForegroundColor Green
Write-Host "     交互弹窗用户：$interactiveUser" -ForegroundColor Green
Start-ScheduledTask -TaskName 'BedtimeGuard'
Start-Sleep -Seconds 4
if (Test-Path (Join-Path $Dir 'guard.log')) {
    Write-Host "     最近日志：" -ForegroundColor Green
    Get-Content (Join-Path $Dir 'guard.log') -Tail 4
}
