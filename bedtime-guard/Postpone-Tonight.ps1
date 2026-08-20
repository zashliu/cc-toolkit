# 今晚一次性顺延关机窗口（需管理员，因为要写 C:\ProgramData）
#   powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Postpone-Tonight.ps1 -Minutes 60
#   powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Postpone-Tonight.ps1 -Cancel
#
# 写出的 tonight.json 绑定到具体某一晚，过了这晚自动失效，不用手动改回来。
# 上限 120 分钟，由 BedtimeGuard.ps1 的 $MaxTonightShiftMinutes 再兜一次底。
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [int]$Minutes = 60,
    [switch]$Cancel
)
$ErrorActionPreference = 'Stop'

$Dir          = 'C:\ProgramData\BedtimeGuard'
$TonightFile  = Join-Path $Dir 'tonight.json'
$WindowStart  = '23:45'   # 需与 BedtimeGuard.ps1 的 $WindowStart 一致
$WindowEnd    = '06:00'

if (-not (Test-Path $Dir)) { throw "$Dir 不存在，先跑 Install.ps1" }

if ($Cancel) {
    if (Test-Path $TonightFile) { Remove-Item $TonightFile -Force; Write-Host "[OK] 已取消今晚的顺延" -ForegroundColor Green }
    else { Write-Host "[--] 本来就没有顺延" -ForegroundColor DarkGray }
    return
}

# 用真实北京时间判断“现在属于哪一晚”，别用本地时钟（可能被改过）
$utc = $null
foreach ($url in 'https://www.baidu.com/','https://www.qq.com/','https://www.cloudflare.com/') {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($url)
        $req.Method = 'HEAD'; $req.Timeout = 4000; $req.AllowAutoRedirect = $false; $req.Proxy = $null
        $resp = $req.GetResponse()
        try { $d = $resp.Headers['Date'] } finally { $resp.Close() }
        if ($d) {
            $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
            $utc = [DateTime]::Parse($d, [Globalization.CultureInfo]::InvariantCulture, $styles)
            break
        }
    } catch { continue }
}
if (-not $utc) { throw "取不到网络时间，无法确定今晚是哪一晚。连上网再试。" }

$beijing = $utc.AddHours(8)
$mins    = $beijing.Hour * 60 + $beijing.Minute
$startM  = [int]$WindowStart.Split(':')[0] * 60 + [int]$WindowStart.Split(':')[1]
$endM    = [int]$WindowEnd.Split(':')[0]   * 60 + [int]$WindowEnd.Split(':')[1]

# 跨零点时，凌晨算作前一晚
$nightStart = $beijing.Date.AddMinutes($startM)
if ($startM -gt $endM -and $mins -lt $endM) { $nightStart = $nightStart.AddDays(-1) }
$nightId = $nightStart.ToString('yyyy-MM-dd')

if ($Minutes -lt 1)   { throw "顺延分钟数必须为正" }
if ($Minutes -gt 120) { Write-Host "[!] 上限 120 分钟，已截断" -ForegroundColor Yellow; $Minutes = 120 }

[pscustomobject]@{ nightId = $nightId; shiftMinutes = $Minutes } |
    ConvertTo-Json | Set-Content -Path $TonightFile -Encoding UTF8

$newStart = $nightStart.AddMinutes($Minutes)
Write-Host ("[OK] 今晚({0})顺延 {1} 分钟：关机窗口起点 {2} -> {3}" -f $nightId, $Minutes, $WindowStart, $newStart.ToString('HH:mm')) -ForegroundColor Green
Write-Host ("     北京时间现在 {0}；明晚自动恢复 {1}，无需手动改回" -f $beijing.ToString('HH:mm:ss'), $WindowStart) -ForegroundColor Green
