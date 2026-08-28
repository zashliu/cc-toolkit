# 安装 BedtimeGuard：注册三个计划任务
#   BedtimeGuard         (SYSTEM)      —— 开机拉起常驻执行器：算时间、关机
#   BedtimeGuardWatchdog (SYSTEM)      —— 开机拉起常驻看门狗：监护执行器
#   BedtimeGuardNotify   (当前用户/交互)—— 登录后常驻，只显示保存提醒
# 需以【管理员】身份运行本脚本
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$Dir      = 'C:\ProgramData\BedtimeGuard'
$LegacyRequestDir = Join-Path $Dir 'requests'
$Guard    = Join-Path $Dir 'BedtimeGuard.ps1'
$Watchdog = Join-Path $Dir 'Watchdog.ps1'
$Notify   = Join-Path $Dir 'Notify.ps1'

# 若从仓库/其它位置运行，先把脚本部署到 $Dir（从本脚本所在目录复制）
$Src = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Invoke-Icacls([string[]]$Arguments) {
    & icacls.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "设置 BedtimeGuard ACL 失败：$($Arguments -join ' ')" }
}

# Upgrade in place: stop the old watchdog first so it cannot revive the old guard
# while files and task definitions are being replaced.
foreach ($name in 'BedtimeGuardWatchdog','BedtimeGuard','BedtimeGuardNotify') {
    $existingTask = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existingTask) {
        Disable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Out-Null
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 1
$residentScriptPattern = '(?i)\\(?:BedtimeGuard|Watchdog|Notify)\.ps1(?:"|\s|$)'
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $residentScriptPattern } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null }

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
    foreach ($f in 'BedtimeGuard.ps1','BedtimeGuard.Core.psm1','Watchdog.ps1','Notify.ps1','NotifyHidden.vbs','Uninstall.ps1') {
        $s = Join-Path $Src $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $Dir $f) -Force }
    }
    Write-Host "[OK] 已将脚本部署到 $Dir" -ForegroundColor Green
}

foreach ($f in $Guard, $Watchdog, $Notify) { if (-not (Test-Path $f)) { throw "找不到 $f" } }

# v3 完全取消顺延。只清理精确的旧路径，避免残留 runtime/tick 再次复活。
foreach ($legacyFileName in 'delay-request.flag','tonight.json','Postpone-Tonight.ps1','runtime.json') {
    $legacyFile = Join-Path $Dir $legacyFileName
    if (Test-Path -LiteralPath $legacyFile) { Remove-Item -LiteralPath $legacyFile -Force }
}
$expectedLegacyRequestDir = [IO.Path]::GetFullPath('C:\ProgramData\BedtimeGuard\requests')
if ([IO.Path]::GetFullPath($LegacyRequestDir) -ne $expectedLegacyRequestDir) {
    throw "拒绝清理非预期路径：$LegacyRequestDir"
}
if (Test-Path -LiteralPath $LegacyRequestDir) {
    Remove-Item -LiteralPath $LegacyRequestDir -Recurse -Force
}

# 新复制的文件也要显式设置文件级 ACL；目录继承标志不能替代文件级规则。
Invoke-Icacls @($Dir, '/inheritance:r', '/grant:r', $systemDir, $adminsDir, $usersRead)
foreach ($appFile in (Get-ChildItem -LiteralPath $Dir -File -Force)) {
    Invoke-Icacls @($appFile.FullName, '/inheritance:r', '/grant:r', $systemFile, $adminsFile, $usersFile)
}

$guardTr  = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Guard
$wdTr     = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Watchdog
# 用 wscript 隐藏常驻通知进程
$notifyTr = 'wscript.exe "{0}\NotifyHidden.vbs"' -f $Dir

# 弹窗器要跑在交互用户会话里才能显示窗口
$interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $interactiveUser) { $interactiveUser = "$env:USERDOMAIN\$env:USERNAME" }

schtasks /create /tn 'BedtimeGuard'         /tr $guardTr  /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
schtasks /create /tn 'BedtimeGuardWatchdog' /tr $wdTr     /sc onstart /ru SYSTEM /rl HIGHEST /f | Out-Null
# 登录时拉起常驻提醒器；其轮询使用单调计时器，不依赖本地时钟。
schtasks /create /tn 'BedtimeGuardNotify'   /tr $notifyTr /sc onlogon /ru $interactiveUser /rl LIMITED /it /f | Out-Null

# 三个任务都常驻：允许电池供电，不设运行时限，异常退出自动重启。
foreach ($name in 'BedtimeGuard','BedtimeGuardWatchdog','BedtimeGuardNotify') {
    $t = Get-ScheduledTask -TaskName $name
    $t.Settings.DisallowStartIfOnBatteries = $false
    $t.Settings.StopIfGoingOnBatteries     = $false
    $t.Settings.StartWhenAvailable         = $true
    $t.Settings.ExecutionTimeLimit = 'PT0S'
    Set-ScheduledTask -TaskName $name -Settings $t.Settings | Out-Null
}

# 常驻任务异常退出时由任务计划程序自动重启；watchdog 仍会持续检查进程。
$residentSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
foreach ($name in 'BedtimeGuard','BedtimeGuardWatchdog','BedtimeGuardNotify') {
    Set-ScheduledTask -TaskName $name -Settings $residentSettings | Out-Null
}

Write-Host "[OK] 已安装 3 个常驻任务，不依赖系统当前时间。" -ForegroundColor Green
Write-Host "     关机窗口：北京时间 23:45–06:00；23:42 提醒保存，23:45 立即强制关机，不可顺延。" -ForegroundColor Green
Write-Host "     交互弹窗用户：$interactiveUser" -ForegroundColor Green
Start-ScheduledTask -TaskName 'BedtimeGuard'
Start-ScheduledTask -TaskName 'BedtimeGuardWatchdog'
Start-ScheduledTask -TaskName 'BedtimeGuardNotify'
Start-Sleep -Seconds 4
if (Test-Path (Join-Path $Dir 'guard.log')) {
    Write-Host "     最近日志：" -ForegroundColor Green
    Get-Content (Join-Path $Dir 'guard.log') -Tail 4
}
