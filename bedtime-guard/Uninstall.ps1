# 卸载 BedtimeGuard（需管理员身份）
# 因两个 SYSTEM 任务互相重建，需连续删几遍以打断"复活"
#Requires -RunAsAdministrator

for ($i = 0; $i -lt 3; $i++) {
    schtasks /end    /tn 'BedtimeGuard'         2>$null | Out-Null
    schtasks /end    /tn 'BedtimeGuardWatchdog' 2>$null | Out-Null
    schtasks /delete /tn 'BedtimeGuardNotify'   /f 2>$null | Out-Null
    schtasks /delete /tn 'BedtimeGuardWatchdog' /f 2>$null | Out-Null
    schtasks /delete /tn 'BedtimeGuard'         /f 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
}

# 取消可能残留的关机倒计时
shutdown /a 2>$null

$left = @()
foreach ($n in 'BedtimeGuard','BedtimeGuardWatchdog','BedtimeGuardNotify') {
    schtasks /query /tn $n *> $null; if ($LASTEXITCODE -eq 0) { $left += $n }
}
if ($left.Count -eq 0) {
    Write-Host "[OK] 所有任务已删除。" -ForegroundColor Green
    Write-Host "     若要彻底清理，可手动删除文件夹 C:\ProgramData\BedtimeGuard" -ForegroundColor Yellow
} else {
    Write-Host "[!] 仍残留：$($left -join ', ')，请重跑本脚本。" -ForegroundColor Red
}
