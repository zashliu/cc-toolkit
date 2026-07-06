# ============================================================
#  BedtimeGuard —— 按北京时间强制关机，防熬夜（执行器 / SYSTEM）
#  - 联网时用 NTP 校准真实时间（改本地时钟无效）
#  - 断网时用开机单调计时器推算（改本地时钟无效，重启才失效）
#  - 关机前有倒计时警告；配套弹窗器 Notify.ps1 提供"延迟15分钟"按钮
# ============================================================

# ------------------------- 可配置项 -------------------------
$WindowStart       = '23:45'  # 关机窗口起点（北京时间，含）
$WindowEnd         = '06:00'  # 关机窗口终点（北京时间，不含）
$CountdownSeconds  = 180      # 关机前倒计时秒数（此期间可在弹窗点"延迟15分钟"）
$DelayMinutes      = 15       # 延迟时长（分钟）
$OfflineRebootMode = 'require-network'   # 'trust-local' 或 'require-network'
#   trust-local     : 重启后又断网、无法校准时，信任本地时钟（会留一个理论漏洞）
#   require-network : 重启后无法校准真实时间时，直接关机，逼你联网才能用（最严格）
$BootGraceMinutes  = 5        # 开机后给网络就绪的宽限期；此期间联不上网不关机
$NtpServers = @('ntp.aliyun.com','ntp.tencent.com','time.windows.com','pool.ntp.org')
# ------------------------------------------------------------

# 测试用环境变量（正常运行时都不设置）
$TestForceWindow = ($env:BEDTIME_TEST_FORCE_WINDOW -eq '1')  # 强制视为"在关机窗口内"
$TestNoShutdown  = ($env:BEDTIME_TEST_NOSHUTDOWN  -eq '1')   # 只记录不真正关机
if ($env:BEDTIME_DELAY_MINUTES) { $DelayMinutes = [int]$env:BEDTIME_DELAY_MINUTES }

$StateDir    = 'C:\ProgramData\BedtimeGuard'
$StateFile   = Join-Path $StateDir 'state.json'
$RuntimeFile = Join-Path $StateDir 'runtime.json'
$RequestFile = Join-Path $StateDir 'delay-request.flag'
$LogFile     = Join-Path $StateDir 'guard.log'

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

# 通过 NTP 取真实 UTC 时间（不依赖本地时钟）
function Get-NtpUtc {
    param([string[]]$Servers)
    foreach ($server in $Servers) {
        $socket = $null
        try {
            $ntpData = New-Object byte[] 48
            $ntpData[0] = 0x1B                                  # LI=0, VN=3, Mode=3(client)
            $addr = [System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if (-not $addr) { continue }
            $ipep   = New-Object System.Net.IPEndPoint($addr, 123)
            $socket = New-Object System.Net.Sockets.Socket('InterNetwork','Dgram','Udp')
            $socket.ReceiveTimeout = 2000
            $socket.SendTimeout    = 2000
            $socket.Connect($ipep)
            [void]$socket.Send($ntpData)
            [void]$socket.Receive($ntpData)
            # 传输时间戳（Transmit Timestamp）从第 40 字节开始，大端序，1900 纪元
            $intPart  = ([uint64]$ntpData[40] -shl 24) -bor ([uint64]$ntpData[41] -shl 16) -bor ([uint64]$ntpData[42] -shl 8) -bor [uint64]$ntpData[43]
            $fracPart = ([uint64]$ntpData[44] -shl 24) -bor ([uint64]$ntpData[45] -shl 16) -bor ([uint64]$ntpData[46] -shl 8) -bor [uint64]$ntpData[47]
            if ($intPart -eq 0) { continue }
            $ms  = ($intPart * 1000.0) + (($fracPart * 1000.0) / 4294967296.0)
            $utc = (New-Object DateTime(1900,1,1,0,0,0,[DateTimeKind]::Utc)).AddMilliseconds($ms)
            if ($utc -gt (New-Object DateTime(2020,1,1,0,0,0,[DateTimeKind]::Utc))) { return $utc }
        } catch { continue } finally { if ($socket) { $socket.Close() } }
    }
    return $null
}

# 开机以来的毫秒数，单调递增，改系统时钟无效，重启才归零
# 用 QueryPerformanceCounter（Stopwatch），因为 .NET Framework 没有 TickCount64
$tickNow = [int64]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)

# 监护看门狗任务：若被删除则重建（与 Watchdog.ps1 互相监护，增加破解阻力）
schtasks /query /tn 'BedtimeGuardWatchdog' *> $null
if ($LASTEXITCODE -ne 0) {
    $wdTr = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\BedtimeGuard\Watchdog.ps1"'
    schtasks /create /tn 'BedtimeGuardWatchdog' /tr $wdTr /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f *> $null
    Write-Log '看门狗任务缺失 -> 已重建 BedtimeGuardWatchdog'
} else {
    schtasks /change /tn 'BedtimeGuardWatchdog' /enable *> $null
}

# 读取已有锚点
$state = $null
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $state = $null }
}

$trustedUtc = $null
$source     = ''

$ntpUtc = Get-NtpUtc -Servers $NtpServers
if ($ntpUtc) {
    # 联网成功：这是最可信的时间，同时刷新锚点
    $trustedUtc = $ntpUtc
    $source     = 'NTP'
    $state = [pscustomobject]@{
        anchorUtc      = $ntpUtc.ToString('o')
        anchorTick     = $tickNow
        lastTrustedUtc = $ntpUtc.ToString('o')
    }
    try { $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8 } catch {}
}
elseif ($state -and $state.anchorUtc) {
    $anchorUtc = [DateTime]::Parse($state.anchorUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    if ($tickNow -ge [int64]$state.anchorTick) {
        # 同一次开机会话：用单调计时器推算真实时间（改本地时钟无效）
        $elapsedMs  = $tickNow - [int64]$state.anchorTick
        $trustedUtc = $anchorUtc.AddMilliseconds($elapsedMs)
        $source     = 'ANCHOR'
    } else {
        # 计时器比锚点小 → 发生过重启，锚点失效，且当前断网无法校准
        $source = 'REBOOT-OFFLINE'
    }
} else {
    $source = 'NO-STATE'
}

# 无法取得可信时间时的兜底策略
if (-not $trustedUtc) {
    if ($OfflineRebootMode -eq 'require-network') {
        if ($tickNow -lt ($BootGraceMinutes * 60000)) {
            Write-Log ("WAIT source={0} mode=require-network 开机宽限期内({1}分钟)暂不关机，等待联网校准" -f $source, $BootGraceMinutes)
            return
        }
        Write-Log "UNTRUSTED source=$source mode=require-network -> 强制关机（需联网校准后才能正常使用）"
        Invoke-Shutdown $CountdownSeconds "无法校准真实时间，请连接网络后重新开机。系统将关机。"
        return
    }
    # trust-local：退回本地时钟，但不允许时间倒退到上次可信时间之前
    $localUtc    = [DateTime]::UtcNow
    $lastTrusted = [DateTime]::MinValue
    if ($state -and $state.lastTrustedUtc) {
        $lastTrusted = [DateTime]::Parse($state.lastTrustedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    $trustedUtc = if ($localUtc -gt $lastTrusted) { $localUtc } else { $lastTrusted }
    $source     = "FALLBACK-LOCAL($source)"
}

# 转北京时间（中国自 1991 年起无夏令时，固定 UTC+8）
$beijing = $trustedUtc.AddHours(8)
$mins    = $beijing.Hour * 60 + $beijing.Minute
$startM  = ConvertTo-Minutes $WindowStart
$endM    = ConvertTo-Minutes $WindowEnd

# 判断是否在关机窗口内（窗口跨零点时 startM > endM）
if ($startM -le $endM) { $inWindow = ($mins -ge $startM -and $mins -lt $endM) }
else                   { $inWindow = ($mins -ge $startM -or  $mins -lt $endM) }

# 计算"今晚"标识（跨零点时把凌晨归到前一天，保证延迟额度按整晚计）
if ($inWindow) {
    if ($mins -ge $startM) { $nightId = $beijing.ToString('yyyy-MM-dd') }
    else                   { $nightId = $beijing.AddDays(-1).ToString('yyyy-MM-dd') }
} else { $nightId = '' }

if ($TestForceWindow) { $inWindow = $true; if (-not $nightId) { $nightId = $beijing.ToString('yyyy-MM-dd') } }

# 读取运行时状态（延迟额度）
$delayUntilTick = 0; $delayUsedNight = ''
if (Test-Path $RuntimeFile) {
    try { $rt = Get-Content $RuntimeFile -Raw | ConvertFrom-Json; $delayUntilTick = [int64]$rt.delayUntilTick; $delayUsedNight = [string]$rt.delayUsedNight } catch {}
}

$delaying = $false

if ($inWindow) {
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
            $delayUntilTick = $tickNow + $DelayMinutes * 60000
            $delayUsedNight = $nightId
            $delaying = $true
            Invoke-AbortShutdown
            Write-Log ("DELAY GRANTED {0}min night={1}" -f $DelayMinutes, $nightId)
        } else {
            Write-Log ("DELAY DENIED 今晚已用过 night={0} -> 关机" -f $nightId)
            Invoke-Shutdown $CountdownSeconds ("睡觉时间到（北京时间 {0}），{1}秒后关机。今晚延迟机会已用完。" -f $beijing.ToString('HH:mm'), $CountdownSeconds)
        }
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
        delaying       = $delaying
        delayAvailable = $delayAvailable
        nightId        = $nightId
        beijingHHmm    = $beijing.ToString('HH:mm')
        delayUntilTick = $delayUntilTick
        delayUsedNight = $delayUsedNight
    } | ConvertTo-Json | Set-Content -Path $RuntimeFile -Encoding UTF8
} catch {}
