# bedtime-guard v3 — 严格防熬夜强制关机

默认在北京时间 **23:45–06:00** 强制关机。23:42 开始提醒保存，23:45 执行零秒强制关机；严格模式没有延迟按钮、今晚顺延或可取消倒计时。

## 防绕过机制

- **不使用系统时间**：SYSTEM 常驻执行器每 30 秒通过 HTTPS `Date` 或 NTP 获取 UTC，再固定换算为 UTC+8。修改 Windows 时间、日期或时区不会改变判断。
- **不依赖定时触发**：Guard 和 watchdog 在开机时启动后常驻；提醒器在用户登录时启动后常驻。轮询间隔使用单调计时器。
- **断网不能绕过**：开机和瞬时网络故障各有 5 分钟宽限；超过宽限仍无法获得可信时间就立即关机。
- **没有自助顺延**：v2 的请求 inbox、15 分钟延迟、`tonight.json` 和 `Postpone-Tonight.ps1` 已全部移除。
- **旧状态不会复活**：Guard 从不读取 `runtime.json` 作决策。v3 runtime 只供提醒器读取，并带有版本号和单调新鲜度校验。

v2 曾把单调计时截止值写入 runtime。重启后计时器从零开始，旧截止值可能碰巧大于本次开机时长，导致几周前的延迟在新的一晚复活。v3 删除了整条延迟状态机，从根源上修复该漏洞。

## 安装和升级

在管理员 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Install.ps1
```

安装器会停止旧版常驻进程、部署最新版、删除旧延迟文件、重建三个任务并启动：

- `BedtimeGuard`：SYSTEM，开机常驻，获取可信时间并执行关机。
- `BedtimeGuardWatchdog`：SYSTEM，开机常驻，修复并重启 Guard/提醒任务。
- `BedtimeGuardNotify`：当前交互用户，登录常驻，只显示保存提醒。

如果可信北京时间已经处于 23:45–06:00，启动 v3 Guard 会立即关机。升级应安排在 06:00 之后进行。

## 默认配置

配置位于 `BedtimeGuard.ps1` 顶部。修改后重新运行安装器。

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `$WindowStart` / `$WindowEnd` | `23:45` / `06:00` | 强制关机窗口，支持跨午夜 |
| `$WarningLeadSeconds` | `180` | 提前提醒保存的秒数 |
| `$PollIntervalSeconds` | `30` | Guard 轮询间隔 |
| `$BootGraceMinutes` | `5` | 开机等待网络就绪的宽限 |
| `$OfflineGraceMinutes` | `5` | 持续无法取得可信时间的宽限 |
| `$TimeBudgetMs` | `8000` | 每轮联网取时总预算 |
| `$MaxBackwardSkewMinutes` | `10` | 时间源允许的最大回拨 |

SYSTEM 会话优先直连时间源，失败后尝试脚本中列出的本地代理端口。脚本只读取时间，不修改代理、VPN、系统时间或时区。

## runtime.json v3

`C:\ProgramData\BedtimeGuard\runtime.json` 只供提醒器读取：

- `policyVersion: 3`
- `updatedUtc`、`tickNow`
- `inWindow`、`inWarning`、`secondsUntilWindowStart`
- `nightId`、`beijingHHmm`、`shutdownHHmm`

其中不存在延迟截止值、延迟次数或用户请求字段。提醒器拒绝版本不是 3、跨重启或超过 120 秒未更新的 runtime。

## 验证

测试不会真的关机：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bedtime-guard\tests\Test-BedtimeGuard.ps1
```

测试覆盖窗口边界、跨午夜、旧延迟复活、零秒关机、断网宽限、任务触发方式和 runtime v3 schema。

测试专用的 `BEDTIME_TEST_TRUSTED_UTC` 只有同时使用 `-Once` 和非生产 `BEDTIME_STATE_DIR` 时才会生效，不能影响安装后的常驻任务。

## 卸载和安全边界

```powershell
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Uninstall.ps1
```

当前日常账户仍是管理员，因此你最终仍能提权终止进程、删除任务、修改脚本或运行卸载器。本工具可以堵住改时间、改时区、断网、旧状态复活和自助顺延，但无法让掌握本机管理员凭据的人失去最终控制权。

PowerShell 脚本中的中文文件需保持 UTF-8 BOM；`NotifyHidden.vbs` 保持纯 ASCII。
