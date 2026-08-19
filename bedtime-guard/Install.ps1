# 安装 BedtimeGuard：注册三个计划任务
#   BedtimeGuard         (SYSTEM)      —— 开机拉起常驻执行器：算时间、关机
#   BedtimeGuardWatchdog (SYSTEM)      —— 开机拉起常驻看门狗：监护执行器
#   BedtimeGuardNotify   (当前用户/交互)—— 弹窗器：显示"延迟15分钟"弹窗
# 需以【管理员】身份运行本脚本
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$Dir      = 'C:\ProgramData\BedtimeGuard'
$RequestDir = Join-Path $Dir 'requests'
$Guard    = Join-Path $Dir 'BedtimeGuard.ps1'
$Watchdog = Join-Path $Dir 'Watchdog.ps1'
$Notify   = Join-Path $Dir 'Notify.ps1'

# 若从仓库/其它位置运行，先把脚本部署到 $Dir（从本脚本所在目录复制）
$Src = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Invoke-Icacls([string[]]$Arguments) {
    & icacls.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "设置 BedtimeGuard ACL 失败：$($Arguments -join ' ')" }
}

# 旧版本可能留下“Administrators 是所有者但没有 DACL”的文件；先接管并修复，
# 否则 Copy-Item -Force 也无法更新已部署脚本。
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
if (Test-Path -LiteralPath $Dir) {
    & takeown.exe /F $Dir /A /R /D Y *> $null
    if ($LASTEXITCODE -ne 0) { throw "接管 BedtimeGuard 目录失败：$Dir" }
}

# 使用 SID 而不是本地化组名，确保中英文 Windows 都能正确收紧权限。
$systemDir  = '*S-1-5-18:(OI)(CI)(F)'
$adminsDir  = '*S-1-5-32-544:(OI)(CI)(F)'
$usersRead  = '*S-1-5-32-545:(OI)(CI)(RX)'
$systemFile = '*S-1-5-18:F'
$adminsFile = '*S-1-5-32-544:F'
$usersFile  = '*S-1-5-32-545:RX'
Invoke-Icacls @($Dir, '/inheritance:r', '/grant:r', $systemDir, $adminsDir, $usersRead)
foreach ($oldFile in (Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue)) {
    Invoke-Icacls @($oldFile.FullName, '/inheritance:r', '/grant:r', $systemFile, $adminsFile, $usersFile)
}

if ($Src -and ($Src.TrimEnd('\') -ne $Dir.TrimEnd('\'))) {
    foreach ($f in 'BedtimeGuard.ps1','BedtimeGuard.Core.psm1','Watchdog.ps1','Notify.ps1','NotifyHidden.vbs','Uninstall.ps1','Postpone-Tonight.ps1') {
        $s = Join-Path $Src $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $Dir $f) -Force }
    }
    Write-Host "[OK] 已将脚本部署到 $Dir" -ForegroundColor Green
}

foreach ($f in $Guard, $Watchdog, $Notify) { if (-not (Test-Path $f)) { throw "找不到 $f" } }

New-Item -ItemType Directory -Path $RequestDir -Force | Out-Null

# 兼容旧版：把根目录中的延迟请求迁移到用户可写 inbox。
$legacyRequest = Join-Path $Dir 'delay-request.flag'
if (Test-Path $legacyRequest) {
    Move-Item -LiteralPath $legacyRequest -Destination (Join-Path $RequestDir 'delay-request.flag') -Force
}

# 新复制的文件也要显式设置文件级 ACL；目录继承标志不能替代文件级规则。
Invoke-Icacls @($Dir, '/inheritance:r', '/grant:r', $systemDir, $adminsDir, $usersRead)
foreach ($appFile in (Get-ChildItem -LiteralPath $Dir -File -Force)) {
    Invoke-Icacls @($appFile.FullName, '/inheritance:r', '/grant:r', $systemFile, $adminsFile, $usersFile)
}

# 普通用户只能在此目录创建/写入延迟请求，不能修改执行器状态、脚本和顺延配置。
$usersRequest = '*S-1-5-32-545:(OI)(CI)(W)'
Invoke-Icacls @($RequestDir, '/inheritance:r', '/grant:r', $systemDir, $adminsDir, $usersRequest)

$guardTr  = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Guard
$wdTr     = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Watchdog
# 用 wscript 隐藏启动，避免弹窗器每分钟闪现命令行窗口
$notifyTr = 'wscript.exe "{0}\NotifyHidden.vbs"' -f $Dir

# 弹窗器要跑在交互用户会话里才能显示窗口
$interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $interactiveUser) { $interactiveUser = "$env:USERDOMAIN\$env:USERNAME" }

schtasks /create /tn 'BedtimeGuard'         /tr $guardTr  /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
schtasks /create /tn 'BedtimeGuardWatchdog' /tr $wdTr     /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
# 弹窗器只在夜间时段每分钟运行（23:00 起、持续 7.5 小时到次日 06:30），白天完全不启动
schtasks /create /tn 'BedtimeGuardNotify'   /tr $notifyTr /sc daily /st 23:00 /ri 1 /du 0007:30 /ru $interactiveUser /rl LIMITED /it /f | Out-Null

# 三个任务：允许电池供电时运行；执行器/看门狗不设运行时限
foreach ($name in 'BedtimeGuard','BedtimeGuardWatchdog','BedtimeGuardNotify') {
    $t = Get-ScheduledTask -TaskName $name
    $t.Settings.DisallowStartIfOnBatteries = $false
    $t.Settings.StopIfGoingOnBatteries     = $false
    $t.Settings.StartWhenAvailable         = $true
    if ($name -eq 'BedtimeGuardNotify') {
        $t.Settings.ExecutionTimeLimit     = 'PT15M'
    } else {
        $t.Settings.ExecutionTimeLimit     = 'PT0S'
    }
    Set-ScheduledTask -TaskName $name -Settings $t.Settings | Out-Null
}

# 常驻任务异常退出时由任务计划程序自动重启；watchdog 仍会持续检查进程。
$residentSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
foreach ($name in 'BedtimeGuard','BedtimeGuardWatchdog') {
    Set-ScheduledTask -TaskName $name -Settings $residentSettings | Out-Null
}
$notifySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName 'BedtimeGuardNotify' -Settings $notifySettings | Out-Null

Write-Host "[OK] 已安装 3 个计划任务。执行器/看门狗将在开机时常驻运行，不依赖系统当前时间。" -ForegroundColor Green
Write-Host "     关机窗口：北京时间 23:45–06:00；关机前 180 秒倒计时，可延迟 15 分钟(每晚一次)。" -ForegroundColor Green
Write-Host "     交互弹窗用户：$interactiveUser" -ForegroundColor Green
Start-ScheduledTask -TaskName 'BedtimeGuard'
Start-ScheduledTask -TaskName 'BedtimeGuardWatchdog'
Start-Sleep -Seconds 4
if (Test-Path (Join-Path $Dir 'guard.log')) {
    Write-Host "     最近日志：" -ForegroundColor Green
    Get-Content (Join-Path $Dir 'guard.log') -Tail 4
}
