# bedtime-guard — 防熬夜强制关机（按北京时间，防改时间/断网绕过）

到了就寝时段（默认**北京时间 23:45–06:00**）自动强制关机，帮你戒掉持续熬夜。
关机前 3 分钟会先弹出可**延迟 15 分钟（每晚一次）**的窗口，方便保存手头工作；未延迟则到点进入 180 秒关机倒计时。

和普通的定时关机脚本不同，它专门防住了自己会用的绕过手段：

- **改本地系统时间无效**：本地时钟**完全不参与判断**。每分钟联网问一次真实时间，
  两条通道任选其一——HTTPS 响应头的 `Date`（443/TCP）或 NTP（123/UDP）。系统时钟随便改，无效。
- **断网无效**：取不到真实时间 = 不知道现在几点 = **按最坏情况处理，直接关机**（有宽限期防误杀）。
  早期版本会在断网时用「单调计时器 + 上次联网锚点」推算钟点，但**断网 + 重启**会让锚点冻结，
  是个真实可用的漏洞；v2 已彻底移除该推算，单调计时器只用来量「过了多久」，不再用来推算「现在几点」。
- **伪造时间源无效**：拿到的时间若比上次可信时间明显回拨，判为伪造并拒绝采信。

> 代价要清楚：**断网超过宽限期就会关机，不分白天黑夜**。这是「不知道几点就当作是深夜」的必然结果 ——
> 断网时无法判断当前时刻，也就无法只在夜间执行。不接受的话把 `$OfflineGraceMinutes` 调大即可。

## 网络可靠性（实测，别想当然）

在 Clash/Mihomo 这类 **TUN + fake-IP** 代理环境下（域名全解析到 `198.18.x.x`），实测发现：

- 两条通道**各自都会整条间歇性挂掉**：同一台机器 20:00 时 HTTPS 3/3 通、NTP 8/9 超时；20:08 时正好反过来。
- 所以脚本**不写死通道优先级**，而是把上次成功的探针（通道+站点+出口）记进 `state.json` 的
  `lastGoodProbe`，下次优先复用，失败再轮换。
- SYSTEM 会话没有用户的 IE 代理设置，`HttpWebRequest` 默认会触发 **WPAD 自动探测**——又慢又必失败。
  因此代码显式 `$req.Proxy = $null`（直连），不通再依次试常见本地代理端口。
- 全流程有 `$TimeBudgetMs`（默认 8 秒）总预算。没有它，「N 个站 × M 个出口」会乘出**分钟级**耗时，
  而任务是每分钟触发一次。命中缓存的探针时通常 **1–3 秒**返回。

> 脚本只是**只读地问一下时间**，不修改任何系统代理 / VPN 设置（不动 `netsh winhttp`、
> 不动注册表 `Internet Settings`、不动代理软件配置）。VPN 开着关着都能正常工作。

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
| `$BootGraceMinutes` | `5` | 开机宽限期，给网络就绪时间，避免开机误关 |
| `$OfflineGraceMinutes` | `5` | 持续联不上网多久后关机。**嫌容易误关就调大这个** |
| `$TimeBudgetMs` | `8000` | 每轮取时间的总耗时上限，超了就判定断网 |
| `$SamplesWanted` | `1` | 需要几个来源。设 2 会做交叉校验但耗时翻倍 |
| `$MaxBackwardSkewMinutes` | `10` | 允许比上次可信时间早多少分钟，超过判为伪造 |
| `$MaxSampleSpreadMinutes` | `5` | 取到多个来源时，彼此相差超过这么久就整批作废 |
| `$RejectStreakToReset` | `10` | 连续这么多次判为回拨就重置锚点（自愈，防被脏数据永久锁死） |
| `$HttpTimeUrls` / `$NtpServers` / `$LocalProxies` | 见脚本 | 时间源与出口候选 |

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
- **自锁保护**：`lastTrustedUtc` 是防回拨的锚点。万一某个站点返回一个远未来的 `Date` 把锚点顶飞，
  之后所有真实时间都会被判成“回拨”→ 无限关机循环。故加了 `$RejectStreakToReset`：连续 10 次全被拒，
  就认定是锚点自己坏了而不是全世界的时间服务器一起回拨，清空锚点自愈。
- **残留漏洞**：已堵住“改系统时间”“断网”“断网+重启”“单点伪造回拨”。真正的边界是——你是管理员，
  铁了心提权删掉两个任务当然能停；能改 hosts / 自建时间源伪造 `Date` 也能骗过。本工具的目标是按
  Fogg 行为模型**加大绕过阻力**，而不是做到绝对不可逆。
- 中国自 1991 年起无夏令时，固定 UTC+8。

## 测试用环境变量

| 变量 | 作用 |
|------|------|
| `BEDTIME_TEST_FORCE_WINDOW=1` | 强制视为“在关机窗口内” |
| `BEDTIME_TEST_NOSHUTDOWN=1` | 只记录不真正关机 |
| `BEDTIME_TEST_FORCE_OFFLINE=1` | 强制视为取不到真实时间，用来测断网分支 |
| `BEDTIME_DELAY_MINUTES=<n>` | 改延迟时长，便于测到期 |
| `BEDTIME_OFFLINE_GRACE_MINUTES=<n>` | 改断网宽限，设 0 可立即触发关机分支 |
| `BEDTIME_BOOT_GRACE_MINUTES=<n>` | 改开机宽限 |
| `BEDTIME_STATE_DIR=<路径>` | 换状态目录：**普通用户就能跑全流程**，不碰线上状态、不需要管理员 |

配好后一条命令就能本地验证（不会真关机）：

```powershell
$env:BEDTIME_STATE_DIR="$env:TEMP\bgtest"; $env:BEDTIME_TEST_NOSHUTDOWN='1'
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\BedtimeGuard.ps1
Get-Content "$env:TEMP\bgtest\guard.log"
```
