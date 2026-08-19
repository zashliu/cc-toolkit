# ============================================================
#  BedtimeGuard —— 按北京时间强制关机，防熬夜（执行器 / SYSTEM）
#
#  时间来源策略（v2，严格模式）：
#   - 只认【联网取到的真实时间】：NTP（UDP 123）+ HTTPS 响应头 Date 双通道
#   - 本地系统时钟【完全不参与】任何判断，随便改，无效
#   - 不再用「单调计时器 + 上次锚点」推算钟点，因为断网重启会让它冻结
#   - 取不到真实时间（断网 / UDP 被封 / DNS 被改）→ 过宽限期直接关机
#   - 拿到的时间若比上次可信时间明显回拨 → 视为伪造，拒绝采信
#
#  关机前有倒计时警告；配套弹窗器 Notify.ps1 提供“延迟15分钟”按钮
# ============================================================

[CmdletBinding()]
param(
    # 安装后的计划任务不传此参数；测试时用它执行一次后退出。
    [switch]$Once
)

$CorePath = Join-Path $PSScriptRoot 'BedtimeGuard.Core.psm1'
if (-not (Test-Path -LiteralPath $CorePath)) { throw "找不到 $CorePath" }
$CoreModule = Import-Module -Name $CorePath -Force -PassThru
$WindowStateCommand = $CoreModule.ExportedCommands['Get-WindowState']
if (-not $WindowStateCommand) { throw '核心窗口函数未导出' }

# ------------------------- 可配置项 -------------------------
$WindowStart       = '23:45'  # 关机窗口起点（北京时间，含）
$WindowEnd         = '06:00'  # 关机窗口终点（北京时间，不含）
$CountdownSeconds  = 180      # 关机前倒计时秒数
$WarningLeadSeconds = 180     # 提前多少秒弹出“延迟15分钟”窗口
$DelayMinutes      = 15       # 延迟时长（分钟）
$PollIntervalSeconds = 30     # 常驻守护轮询间隔；不依赖系统墙上时钟
# 「今晚临时顺延」的上限。必须有上限：顺延过头会让 startM 越过 $WindowEnd，
# 窗口判断翻转成“全天关机”。默认 2 小时，23:45 最多顺到 01:45。
$MaxTonightShiftMinutes = 120

# —— 断网策略：取不到真实时间就关机 ——
$BootGraceMinutes    = 5      # 开机后给网络就绪的宽限期，此期间联不上网不关机
$OfflineGraceMinutes = 5      # 持续联不上网多久后关机（容忍瞬时抖动，防误杀）
$MaxBackwardSkewMinutes = 10  # 允许比“上次可信时间”早多少分钟；超过视为伪造时间源

# —— 时间源 ——
# 两条通道：HTTPS 响应头 Date（443/TCP）和 NTP（123/UDP）。
# 实测在 Clash/Mihomo 这类 TUN+fake-IP 代理下，两条都会【间歇性整条挂掉】，
# 但很少同时挂。所以不写死优先级，靠 state 里的 lastGoodProbe 自适应（见下方函数）。
$HttpTimeUrls = @(
    'https://www.baidu.com/','https://www.qq.com/','https://www.taobao.com/',
    'https://www.cloudflare.com/','https://www.microsoft.com/'
)
$NtpServers = @('pool.ntp.org','time.windows.com','ntp.aliyun.com','ntp.tencent.com','ntp.ntsc.ac.cn')
# SYSTEM 会话没有用户的 IE 代理设置，默认代理探测(WPAD)只会拖慢并失败。
# 因此显式先直连；不通再试常见本地代理端口（Clash/Mihomo/V2Ray）。
# 注意：这只影响本脚本自己发的请求，不会修改任何系统代理 / VPN 设置。
$LocalProxies = @('http://127.0.0.1:7897','http://127.0.0.1:7890','http://127.0.0.1:10809')
$HttpTimeoutMs = 2500
$NtpTimeoutMs  = 1500
# 总预算要小：本脚本每分钟触发一次，只需要精确到分钟，没必要为了几秒精度死磕。
# 网络正常时命中第一个探针就返回（约 1-2 秒）；全挂时最多烧掉这么多就判定断网，
# 再由 $OfflineGraceMinutes 决定要不要关机。
$TimeBudgetMs  = 8000
$SamplesWanted = 1            # 拿到 1 个可信来源就够，别为了交叉验证把耗时翻倍
$MaxSampleSpreadMinutes = 5   # 万一顺手拿到 2 个：差太多说明有一个在胡说，整批作废
$RejectStreakToReset = 10     # 连续这么多次判为“回拨”就重置锚点，防被脏数据永久锁死
# ------------------------------------------------------------

# 测试用环境变量（正常运行时都不设置）
$TestForceWindow = ($env:BEDTIME_TEST_FORCE_WINDOW -eq '1')  # 强制视为“在关机窗口内”
$TestNoShutdown  = ($env:BEDTIME_TEST_NOSHUTDOWN  -eq '1')   # 只记录不真正关机
$TestForceOffline = ($env:BEDTIME_TEST_FORCE_OFFLINE -eq '1') # 强制视为取不到时间
if ($env:BEDTIME_DELAY_MINUTES) { $DelayMinutes = [int]$env:BEDTIME_DELAY_MINUTES }
if ($env:BEDTIME_OFFLINE_GRACE_MINUTES) { $OfflineGraceMinutes = [int]$env:BEDTIME_OFFLINE_GRACE_MINUTES }
if ($env:BEDTIME_BOOT_GRACE_MINUTES)    { $BootGraceMinutes    = [int]$env:BEDTIME_BOOT_GRACE_MINUTES }

$StateDir    = 'C:\ProgramData\BedtimeGuard'
# 测试用：换个状态目录就能以普通用户跑全流程，不污染线上状态、也不需要管理员
if ($env:BEDTIME_STATE_DIR) { $StateDir = $env:BEDTIME_STATE_DIR }
$StateFile   = Join-Path $StateDir 'state.json'
$RuntimeFile = Join-Path $StateDir 'runtime.json'
$RequestDir  = Join-Path $StateDir 'requests'
$RequestFile = Join-Path $RequestDir 'delay-request.flag'
$TonightFile = Join-Path $StateDir 'tonight.json'   # 一次性顺延，见下方 TONIGHT-SHIFT
$LogFile     = Join-Path $StateDir 'guard.log'

# 安装脚本会预先创建并锁定这些目录；测试模式使用临时目录时由执行器补建。
try {
    New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $RequestDir -Force -ErrorAction SilentlyContinue | Out-Null
} catch {}

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date).ToString('o'), $msg) -ErrorAction SilentlyContinue } catch {}
}
function Invoke-Shutdown([int]$secs, [string]$msg) {
    if ($TestNoShutdown) { Write-Log "TEST 模拟关机(未真正执行) t=$secs"; return }
    shutdown /s /f /t $secs /c $msg 2>$null
}
function Invoke-AbortShutdown() {
    if ($TestNoShutdown) { return }
    shutdown /a 2>$null
}
function ConvertTo-Minutes([string]$hhmm) { $p = $hhmm.Split(':'); [int]$p[0] * 60 + [int]$p[1] }

$MinSaneUtc = New-Object DateTime(2020,1,1,0,0,0,[DateTimeKind]::Utc)

# 向单个 NTP 服务器要真实 UTC（不依赖本地时钟）。成功返回 DateTime，失败返回 $null。
function Get-NtpUtcOne {
    param([string]$Server)
    $socket = $null
    try {
        $ntpData = New-Object byte[] 48
        $ntpData[0] = 0x1B                                  # LI=0, VN=3, Mode=3(client)
        $addr = [System.Net.Dns]::GetHostAddresses($Server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $addr) { return $null }
        $ipep   = New-Object System.Net.IPEndPoint($addr, 123)
        $socket = New-Object System.Net.Sockets.Socket('InterNetwork','Dgram','Udp')
        $socket.ReceiveTimeout = $NtpTimeoutMs
        $socket.SendTimeout    = $NtpTimeoutMs
        $socket.Connect($ipep)
        [void]$socket.Send($ntpData)
        [void]$socket.Receive($ntpData)
        # 传输时间戳（Transmit Timestamp）从第 40 字节开始，大端序，1900 纪元
        $intPart  = ([uint64]$ntpData[40] -shl 24) -bor ([uint64]$ntpData[41] -shl 16) -bor ([uint64]$ntpData[42] -shl 8) -bor [uint64]$ntpData[43]
        $fracPart = ([uint64]$ntpData[44] -shl 24) -bor ([uint64]$ntpData[45] -shl 16) -bor ([uint64]$ntpData[46] -shl 8) -bor [uint64]$ntpData[47]
        if ($intPart -eq 0) { return $null }
        $ms  = ($intPart * 1000.0) + (($fracPart * 1000.0) / 4294967296.0)
        $utc = (New-Object DateTime(1900,1,1,0,0,0,[DateTimeKind]::Utc)).AddMilliseconds($ms)
        if ($utc -gt $MinSaneUtc) { return $utc }
    } catch { return $null } finally { if ($socket) { $socket.Close() } }
    return $null
}

# 主通道：读 HTTPS 响应头里的 Date（RFC 7231 规定为 GMT）。
# 走 443/TCP，代理和 VPN 都能正常转发；且经过 TLS 证书校验，比裸 NTP 难伪造。
# 只做只读的 HEAD 请求，不修改任何系统代理 / VPN 设置。
function Get-HttpDateUtc {
    param([string]$Url, [string]$Proxy)
    $dateHeader = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method            = 'HEAD'
        $req.Timeout           = $HttpTimeoutMs
        $req.ReadWriteTimeout  = $HttpTimeoutMs
        $req.AllowAutoRedirect = $false
        $req.UserAgent         = 'BedtimeGuard'
        # 关键：显式指定出口。留空会触发 WPAD 自动探测，SYSTEM 会话下又慢又必失败。
        if ($Proxy) { $req.Proxy = New-Object System.Net.WebProxy($Proxy) } else { $req.Proxy = $null }
        $resp = $req.GetResponse()
        try { $dateHeader = $resp.Headers['Date'] } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        # 4xx/5xx 的响应一样带 Date 头，照用
        try { if ($_.Exception.Response) { $dateHeader = $_.Exception.Response.Headers['Date'] } } catch {}
    } catch { return $null }
    if (-not $dateHeader) { return $null }
    try {
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $utc = [DateTime]::Parse($dateHeader, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        if ($utc -gt $MinSaneUtc) { return [DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc) }
    } catch {}
    return $null
}

# ------------------ 统一的取时间入口 ------------------
# 实测教训：HTTPS 和 NTP 这两条通道【各自都会间歇性全挂】——同一台机器上，
# 20:00 时 HTTPS 3/3 通、NTP 8/9 挂；20:08 时正好反过来。所以不能写死谁优先，
# 而是【记住上次哪条通道 / 哪个出口成功，下次先试它】，失败再轮换。
# 全程共用一个总预算：本脚本是每分钟触发的计划任务，必须一分钟内结束。
$script:GoodProbe = $null
function Get-TrustedUtcSamples {
    param([string]$PreferredProbe)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $budget = [System.Diagnostics.Stopwatch]::StartNew()

    # 探针清单：每项 = @{ Id; Kind; Target; Egress }
    # Id 会被记进 state，下次优先复用。
    $probes = @()
    foreach ($url in $HttpTimeUrls) {
        $h = ([Uri]$url).Host
        $probes += @{ Id = "http|$url|direct"; Kind = 'http'; Target = $url; Egress = 'direct'; Label = "HTTP:$h(direct)" }
    }
    foreach ($srv in $NtpServers) {
        $probes += @{ Id = "ntp|$srv"; Kind = 'ntp'; Target = $srv; Egress = ''; Label = "NTP:$srv" }
    }
    foreach ($px in $LocalProxies) {
        foreach ($url in $HttpTimeUrls) {
            $h = ([Uri]$url).Host
            $probes += @{ Id = "http|$url|$px"; Kind = 'http'; Target = $url; Egress = $px; Label = "HTTP:$h($px)" }
        }
    }
    # 上次成功的探针提到最前面
    if ($PreferredProbe) {
        $hit = @($probes | Where-Object { $_.Id -eq $PreferredProbe })
        if ($hit.Count) { $probes = @($hit) + @($probes | Where-Object { $_.Id -ne $PreferredProbe }) }
    }

    $samples = @()
    foreach ($pr in $probes) {
        if ($budget.ElapsedMilliseconds -gt $TimeBudgetMs) {
            Write-Log ("BUDGET 取时间用满 {0}ms，已拿到 {1} 个样本" -f $TimeBudgetMs, $samples.Count)
            break
        }
        $utc = if ($pr.Kind -eq 'http') {
            Get-HttpDateUtc -Url $pr.Target -Proxy $(if ($pr.Egress -eq 'direct') { $null } else { $pr.Egress })
        } else {
            Get-NtpUtcOne -Server $pr.Target
        }
        if ($utc) {
            $samples += @{ Utc = $utc; Source = $pr.Label }
            if (-not $script:GoodProbe) { $script:GoodProbe = $pr.Id }
            if ($samples.Count -ge $SamplesWanted) { break }
        }
    }

    if (-not $samples.Count) { return $null }
    $sorted = @($samples | Sort-Object { $_.Utc })
    if ($sorted.Count -ge 2) {
        # 交叉校验：两个互不相关的来源不可能同时报出同一个错误时间。
        # 差得太离谱说明有一个在胡说，宁可整批作废（按断网处理），
        # 也不能让它污染 lastTrustedUtc —— 否则之后真实时间全被判成回拨，永久关机。
        $spread = ($sorted[-1].Utc - $sorted[0].Utc).TotalMinutes
        if ($spread -gt $MaxSampleSpreadMinutes) {
            Write-Log ("REJECT 时间源互相矛盾 spread={0:N1}min [{1}] -> 整批作废" -f $spread, (($sorted | ForEach-Object { "$($_.Source)=$($_.Utc.ToString('HH:mm:ss'))" }) -join ', '))
            return $null
        }
    }
    # 取最大值：把时间往【早】了伪造需要同时骗过所有来源，成本更高
    $best = $sorted[-1]
    return @{ Utc = $best.Utc; Source = ("{0} n={1}" -f $best.Source, $sorted.Count); Count = $sorted.Count }
}

function Get-MonotonicMilliseconds {
    # 开机以来的毫秒数，改系统时钟无效，重启才归零。
    [int64]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)
}

function Invoke-GuardCycle {
    # 单调计时器只用于测量宽限期/延迟时长，绝不用来推算北京时间。
    $tickNow = Get-MonotonicMilliseconds

# 读取历史状态（上次可信时间 + 断网起点）
$state = $null
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $state = $null }
}
$lastTrustedUtc = [DateTime]::MinValue
if ($state -and $state.lastTrustedUtc) {
    try { $lastTrustedUtc = [DateTime]::Parse($state.lastTrustedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
}
$offlineSinceTick = $null
if ($state -and $null -ne $state.offlineSinceTick) {
    try { $offlineSinceTick = [int64]$state.offlineSinceTick } catch {}
}
# 上次成功的探针（哪条通道 / 哪个站 / 哪个出口），下次优先试它，省掉整轮试错
$lastGoodProbe = $null
if ($state -and $state.lastGoodProbe) { $lastGoodProbe = [string]$state.lastGoodProbe }
$rejectStreak = 0
if ($state -and $state.rejectStreak) { try { $rejectStreak = [int]$state.rejectStreak } catch {} }

# ---------------- 取真实时间：只认网络 ----------------
$live = $null
if (-not $TestForceOffline) {
    $live = Get-TrustedUtcSamples -PreferredProbe $lastGoodProbe
}

# 防伪造：真实时间不可能大幅回拨。比上次可信时间早太多 → 拒绝采信，按断网处理。
if ($live -and $lastTrustedUtc -gt [DateTime]::MinValue) {
    if ($live.Utc -lt $lastTrustedUtc.AddMinutes(-$MaxBackwardSkewMinutes)) {
        $rejectStreak++
        if ($rejectStreak -ge $RejectStreakToReset) {
            # 连续这么多分钟所有来源都说“更早” —— 那更可能是锚点本身被脏数据顶到未来，
            # 而不是全世界的时间服务器一起回拨。重置锚点自愈，否则会永久关机。
            Write-Log ("ANCHOR-RESET 连续 {0} 次判为回拨，判定锚点 {1} 已损坏 -> 清空重来" -f $rejectStreak, $lastTrustedUtc.ToString('o'))
            $lastTrustedUtc = [DateTime]::MinValue
            $rejectStreak = 0
        } else {
            Write-Log ("REJECT 时间源回拨 source={0} got={1} lastTrusted={2} streak={3} -> 视为不可信" -f $live.Source, $live.Utc.ToString('o'), $lastTrustedUtc.ToString('o'), $rejectStreak)
            $live = $null
        }
    } else { $rejectStreak = 0 }
} elseif ($live) { $rejectStreak = 0 }

if (-not $live) {
    # 取不到可信时间。本地时钟一律不采信 —— 宁可关机，也不给「断网就随便熬」的口子。
    if ($null -eq $offlineSinceTick -or $offlineSinceTick -gt $tickNow) {
        # 没记录，或计时器比记录小（说明重启过）→ 从现在开始计断网时长
        $offlineSinceTick = $tickNow
    }
    $offlineMs = $tickNow - $offlineSinceTick
    try {
        [pscustomobject]@{
            lastTrustedUtc   = $(if ($lastTrustedUtc -gt [DateTime]::MinValue) { $lastTrustedUtc.ToString('o') } else { $null })
            offlineSinceTick = $offlineSinceTick
            lastGoodProbe    = $lastGoodProbe
            rejectStreak     = $rejectStreak
        } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    } catch {}

    if ($tickNow -lt ($BootGraceMinutes * 60000)) {
        Write-Log ("WAIT 开机宽限期内({0}分钟)，等待联网校准；offline={1}s" -f $BootGraceMinutes, [int]($offlineMs / 1000))
        return
    }
    if ($offlineMs -lt ($OfflineGraceMinutes * 60000)) {
        Write-Log ("WAIT 联网失败 {0}s，未超过宽限 {1}分钟，暂不关机" -f [int]($offlineMs / 1000), $OfflineGraceMinutes)
        return
    }
    Write-Log ("UNTRUSTED 断网 {0}s 仍无法取得真实时间 -> 强制关机" -f [int]($offlineMs / 1000))
    Invoke-Shutdown $CountdownSeconds ("无法联网校准真实时间（已断网 {0} 分钟），{1} 秒后关机。请连网后再使用。" -f [int]($offlineMs / 60000), $CountdownSeconds)
    return
}

$trustedUtc = $live.Utc
$source     = $live.Source
if ($trustedUtc -gt $lastTrustedUtc) { $lastTrustedUtc = $trustedUtc }
try {
    [pscustomobject]@{
        # 没有两源互证过就写 $null，别把 DateTime.MinValue 当锚点存进去
        lastTrustedUtc   = $(if ($lastTrustedUtc -gt [DateTime]::MinValue) { $lastTrustedUtc.ToString('o') } else { $null })
        offlineSinceTick = $null          # 联网成功，清掉断网计时
        lastGoodProbe    = $(if ($script:GoodProbe) { $script:GoodProbe } else { $lastGoodProbe })
        rejectStreak     = 0
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
} catch {}

# 转北京时间（中国自 1991 年起无夏令时，固定 UTC+8）
$beijing = $trustedUtc.AddHours(8)
$mins    = $beijing.Hour * 60 + $beijing.Minute
$startM  = ConvertTo-Minutes $WindowStart
$endM    = ConvertTo-Minutes $WindowEnd

# —— 今晚临时顺延（TONIGHT-SHIFT）——
# tonight.json = { "nightId": "2026-08-07", "shiftMinutes": 60 }
# 绑定到具体某一晚，过了这晚自动失效，不需要手动改回来。
# 先用【原始】窗口算出“当前属于哪一晚”，否则顺延后的窗口会把日期算歪。
$baseStartM = $startM
$baseWindowStartToday = $beijing.Date.AddMinutes($baseStartM)
if     ($baseStartM -le $endM) { $baseNightStart = $baseWindowStartToday }
elseif ($mins -lt $endM)       { $baseNightStart = $baseWindowStartToday.AddDays(-1) }
else                           { $baseNightStart = $baseWindowStartToday }
$baseNightId = $baseNightStart.ToString('yyyy-MM-dd')

$shiftMinutes = 0
if (Test-Path $TonightFile) {
    try {
        $tn = Get-Content $TonightFile -Raw | ConvertFrom-Json
        if ([string]$tn.nightId -eq $baseNightId) {
            $shiftMinutes = [int]$tn.shiftMinutes
            if ($shiftMinutes -lt 0) { $shiftMinutes = 0 }
            if ($shiftMinutes -gt $MaxTonightShiftMinutes) { $shiftMinutes = $MaxTonightShiftMinutes }
        }
    } catch {}
}
if ($shiftMinutes -gt 0) {
    $startM = ($baseStartM + $shiftMinutes) % 1440
    Write-Log ("TONIGHT-SHIFT night={0} +{1}min -> 关机窗口起点 {2:00}:{3:00}" -f $baseNightId, $shiftMinutes, [int]($startM / 60), ($startM % 60))
}

# 判断是否在关机窗口内，并计算预警/今晚标识。
# 例：23:45 开始关机，23:42-23:45 弹窗；凌晨归到前一晚，保证延迟额度按整晚计。
$window = & $WindowStateCommand -Beijing $beijing -StartMinutes $startM -EndMinutes $endM `
    -WarningLeadSeconds $WarningLeadSeconds -NightId $baseNightId
$inWindow = $window.InWindow
$inWarning = $window.InWarning
$windowStartForNight = $window.WindowStartForNight
$secondsUntilWindowStart = $window.SecondsUntilWindowStart
$nightId = $window.NightId

if ($TestForceWindow) { $inWindow = $true; $inWarning = $false; if (-not $nightId) { $nightId = $beijing.ToString('yyyy-MM-dd') } }

# 读取运行时状态（延迟额度）
$delayUntilTick = 0; $delayUsedNight = ''
if (Test-Path $RuntimeFile) {
    try { $rt = Get-Content $RuntimeFile -Raw | ConvertFrom-Json; $delayUntilTick = [int64]$rt.delayUntilTick; $delayUsedNight = [string]$rt.delayUsedNight } catch {}
}

$delaying = $false

if ($inWindow -or $inWarning) {
    if ($delayUntilTick -gt 0 -and $tickNow -lt $delayUntilTick) {
        # 延迟进行中：不关机；清掉延迟期间产生的多余请求，避免到期时误判
        $delaying = $true
        if (Test-Path $RequestFile) { Remove-Item $RequestFile -Force -ErrorAction SilentlyContinue }
        Write-Log ("DELAYING night={0} 剩余{1}秒" -f $nightId, [int](($delayUntilTick - $tickNow) / 1000))
    }
    elseif (Test-Path $RequestFile) {
        # 收到延迟请求
        Remove-Item $RequestFile -Force -ErrorAction SilentlyContinue
        if ($delayUsedNight -ne $nightId) {
            $extraUntilWindowMs = if ($inWarning) { [Math]::Max(0, $secondsUntilWindowStart * 1000) } else { 0 }
            $delayUntilTick = $tickNow + $extraUntilWindowMs + ($DelayMinutes * 60000)
            $delayUsedNight = $nightId
            $delaying = $true
            Invoke-AbortShutdown
            Write-Log ("DELAY GRANTED {0}min night={1}" -f $DelayMinutes, $nightId)
        } else {
            Write-Log ("DELAY DENIED 今晚已用过 night={0} -> 关机" -f $nightId)
            Invoke-Shutdown $CountdownSeconds ("睡觉时间到（北京时间 {0}），{1}秒后关机。今晚延迟机会已用完。" -f $beijing.ToString('HH:mm'), $CountdownSeconds)
        }
    }
    elseif ($inWarning) {
        Write-Log ("WARNING night={0} beijing={1} shutdownIn={2}s source={3}" -f $nightId, $beijing.ToString('HH:mm:ss'), $secondsUntilWindowStart, $source)
    }
    else {
        # 到点且无延迟：武装/维持关机倒计时（重复调用不会重置已在进行的倒计时）
        Write-Log ("SHUTDOWN-ARM night={0} beijing={1} source={2}" -f $nightId, $beijing.ToString('HH:mm:ss'), $source)
        Invoke-Shutdown $CountdownSeconds ("睡觉时间到（北京时间 {0}），{1}秒后关机，请立即保存。" -f $beijing.ToString('HH:mm'), $CountdownSeconds)
    }
} else {
    Write-Log ("OK source={0} beijing={1}" -f $source, $beijing.ToString('yyyy-MM-dd HH:mm:ss'))
}

# 写运行时状态供弹窗器读取
$delayAvailable = ($delayUsedNight -ne $nightId)
try {
    [pscustomobject]@{
        updatedUtc     = $trustedUtc.ToString('o')
        tickNow        = $tickNow
        inWindow       = $inWindow
        inWarning      = $inWarning
        secondsUntilWindowStart = $secondsUntilWindowStart
        delaying       = $delaying
        delayAvailable = $delayAvailable
        nightId        = $nightId
        beijingHHmm    = $beijing.ToString('HH:mm')
        delayUntilTick = $delayUntilTick
        delayUsedNight = $delayUsedNight
    } | ConvertTo-Json | Set-Content -Path $RuntimeFile -Encoding UTF8
} catch {}
}

# 计划任务只负责在开机时拉起本进程；真正的轮询由 Stopwatch + Sleep 驱动，
# 因此运行期间修改 Windows 当前时间或时区不会让下一次检查消失。
$mutexName = if ($env:BEDTIME_STATE_DIR) { "Global\BedtimeGuard.Test.$PID" } else { 'Global\BedtimeGuard' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { exit 0 }

    do {
        try {
            Invoke-GuardCycle
        } catch {
            Write-Log ("CYCLE-ERROR {0}" -f $_.Exception.Message)
        }
        if (-not $Once) { Start-Sleep -Seconds $PollIntervalSeconds }
    } while (-not $Once)
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
