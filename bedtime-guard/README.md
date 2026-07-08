# bedtime-guard — 防熬夜强制关机（按北京时间，防改时间/断网绕过）

到了就寝时段（默认**北京时间 23:45–06:00**）自动强制关机，帮你戒掉持续熬夜。
关机前 3 分钟会先弹出可**延迟 15 分钟（每晚一次）**的窗口，方便保存手头工作；未延迟则到点进入 180 秒关机倒计时。

和普通的定时关机脚本不同，它专门防住了自己会用的两种绕过手段：

- **改本地系统时间无效**：联网时用 NTP 直接问时间服务器（返回的是服务器真实时间，与本地时钟无关）；
  断网时用开机以来的**单调计时器**（QueryPerformanceCounter）+ 上次联网锚点推算，改系统时钟同样无效。
- **临时断网无效**：同一次开机内靠锚点推算；`require-network` 模式下，重启后若联不上网无法校准，直接关机。

## 启用

需**管理员**运行（注册 SYSTEM 计划任务）：

```powershell
# 在仓库目录下，管理员 PowerShell：
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Install.ps1
```

脚本会（幂等，可重复运行）：

1. 把脚本部署到 `C:\ProgramData\BedtimeGuard\`
2. 注册 3 个每分钟触发的计划任务：
   - `BedtimeGuard`（SYSTEM）——执行器：校准时间、到点关机
   - `BedtimeGuardWatchdog`（SYSTEM）——看门狗：与执行器**互相监护**，删/禁其一，另一个 1 分钟内重建
   - `BedtimeGuardNotify`（当前用户会话）——弹窗器：显示延迟弹窗（仅 23:00–06:30 运行，wscript 隐藏启动不闪窗）

## 使用

默认 23:42 左右：桌面弹出提醒。点「延迟 15 分钟」会把 23:45 的关机点顺延到约 00:00；不管它则 23:45 进入 180 秒倒计时并自动关机。
即使 `shutdown /a` 取消，下一分钟会再次触发。

## 配置

改 `bedtime-guard/BedtimeGuard.ps1` 顶部（改完重跑 Install 或直接改 `C:\ProgramData\BedtimeGuard\BedtimeGuard.ps1`，下一分钟自动生效）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `$WindowStart` / `$WindowEnd` | `23:45` / `06:00` | 关机窗口（北京时间，跨零点自动处理） |
| `$CountdownSeconds` | `180` | 关机前倒计时秒数 |
| `$WarningLeadSeconds` | `180` | 提前弹出延迟窗口的秒数 |
| `$DelayMinutes` | `15` | 延迟时长 |
| `$OfflineRebootMode` | `require-network` | `require-network`（重启断网即关机，最严格）/ `trust-local`（信任本地钟，留漏洞） |
| `$BootGraceMinutes` | `5` | 开机宽限期，给网络就绪时间，避免开机误关 |

> ⚠️ 脚本含中文，必须存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 GBK 读取导致解析报错。`.vbs` 保持纯 ASCII（不加 BOM）。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Uninstall.ps1   # 需管理员
```

因两个 SYSTEM 任务互相重建，卸载脚本会连删几遍打断“复活”。

## 设计说明 / 局限

- **弹窗为什么单独一个任务**：SYSTEM 任务运行在会话 0，无法在用户桌面弹窗；故执行器（SYSTEM）只写
  `runtime.json` 决策，弹窗器在用户会话读它显示 WinForms 窗口，点延迟写 `delay-request.flag`，
  执行器读到后延迟并 `shutdown /a` 中止。**杀掉弹窗器只会失去延迟功能，执行器照常关机**（激励对齐）。
- **残留漏洞**：`require-network` 已堵住“重启+断网+改时间”。真正的边界是——你是管理员，铁了心提权删掉
  两个任务当然能停。本工具的目标是按 Fogg 行为模型**加大绕过阻力**（要提权、要同一分钟删两个任务），
  而不是做到绝对不可逆。
- 中国自 1991 年起无夏令时，固定 UTC+8。

## 测试用环境变量

| 变量 | 作用 |
|------|------|
| `BEDTIME_TEST_FORCE_WINDOW=1` | 强制视为“在关机窗口内” |
| `BEDTIME_TEST_NOSHUTDOWN=1` | 只记录不真正关机 |
| `BEDTIME_DELAY_MINUTES=<n>` | 改延迟时长，便于测到期 |
