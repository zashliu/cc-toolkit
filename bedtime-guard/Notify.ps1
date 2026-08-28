# ============================================================
#  BedtimeGuard 常驻提醒器（当前用户会话）
#  只读取 SYSTEM 写出的 v3 runtime；不提供延迟、取消或修改关机时间的入口。
# ============================================================
[CmdletBinding()]
param(
    [switch]$Once
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Dir             = 'C:\ProgramData\BedtimeGuard'
$RuntimeFile     = Join-Path $Dir 'runtime.json'
$MarkerDir       = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BedtimeGuard'
$MarkerFile      = Join-Path $MarkerDir ("notify-shown-{0}.txt" -f $env:USERNAME)
$PollSeconds     = 5
$MaxRuntimeAgeMs = 120000

function Get-MonotonicMilliseconds {
    [int64]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)
}

function Clear-NotifyMarker {
    Remove-Item -LiteralPath $MarkerFile -Force -ErrorAction SilentlyContinue
}

function Show-BedtimeWarning([object]$Runtime) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BedtimeGuard · 强制就寝提醒'
    $form.Size = New-Object System.Drawing.Size(560, 270)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 270)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $seconds = [Math]::Max(1, [int]$Runtime.secondsUntilWindowStart)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = ("北京时间 {0} 将立即强制关机。`n剩余约 {1} 秒，请马上保存并结束工作。`n`n严格模式不提供任何顺延或取消。" -f $Runtime.shutdownHHmm, $seconds)
    $lbl.SetBounds(28, 24, 500, 130)
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12)
    $form.Controls.Add($lbl)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '知道了，立即保存'
    $btnOk.SetBounds(170, 175, 220, 46)
    $btnOk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnOk
    $form.Add_Shown({ $this.Activate(); $this.BringToFront() })

    [void]$form.ShowDialog()
    $form.Dispose()
}

function Invoke-NotifyCycle {
    if (-not (Test-Path -LiteralPath $RuntimeFile)) { Clear-NotifyMarker; return }
    try { $rt = Get-Content -LiteralPath $RuntimeFile -Raw | ConvertFrom-Json } catch { Clear-NotifyMarker; return }

    if ([int]$rt.policyVersion -ne 3 -or $null -eq $rt.tickNow) { Clear-NotifyMarker; return }
    $ageMs = (Get-MonotonicMilliseconds) - [int64]$rt.tickNow
    if ($ageMs -lt 0 -or $ageMs -gt $MaxRuntimeAgeMs) { Clear-NotifyMarker; return }
    if (-not [bool]$rt.inWarning -or -not [string]$rt.nightId) { Clear-NotifyMarker; return }

    $key = [string]$rt.nightId
    if (Test-Path -LiteralPath $MarkerFile) {
        try { if ((Get-Content -LiteralPath $MarkerFile -Raw).Trim() -eq $key) { return } } catch {}
    }

    Show-BedtimeWarning -Runtime $rt
    New-Item -ItemType Directory -Path $MarkerDir -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -LiteralPath $MarkerFile -Value $key -Encoding UTF8
}

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = New-Object System.Threading.Mutex($false, ("Local\BedtimeGuardNotify.{0}" -f $sid))
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { exit 0 }
    do {
        try { Invoke-NotifyCycle } catch {}
        if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
    } while (-not $Once)
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
