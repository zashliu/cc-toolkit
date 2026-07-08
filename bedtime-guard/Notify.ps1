# ============================================================
#  BedtimeGuard 弹窗器（运行在用户登录会话，负责显示"延迟15分钟"弹窗）
#  只做提醒 / 延迟请求；真正的关机由 SYSTEM 执行器 BedtimeGuard.ps1 处理。
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Dir         = 'C:\ProgramData\BedtimeGuard'
$RuntimeFile = Join-Path $Dir 'runtime.json'
$RequestFile = Join-Path $Dir 'delay-request.flag'
$MarkerFile  = Join-Path $Dir ("notify-shown-{0}.txt" -f $env:USERNAME)

if (-not (Test-Path $RuntimeFile)) { return }
try { $rt = Get-Content $RuntimeFile -Raw | ConvertFrom-Json } catch { return }

$notifyActive = ($rt.inWindow -or $rt.inWarning)

# 不在预警/关机窗口 → 清掉已显示标记，供下一晚重新弹出
if (-not $notifyActive) { Remove-Item $MarkerFile -Force -ErrorAction SilentlyContinue; return }
# 延迟进行中 → 不打扰
if ($rt.delaying) { return }

# 同一晚、同一状态只弹一次（delayAvailable 变化时会再弹一次"最后提醒"）
$key = "{0}|{1}" -f $rt.nightId, $rt.delayAvailable
if (Test-Path $MarkerFile) { if ((Get-Content $MarkerFile -Raw).Trim() -eq $key) { return } }

if ($rt.delayAvailable) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'BedtimeGuard · 就寝提醒'
    $form.Size = New-Object System.Drawing.Size(560, 300)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $lbl = New-Object System.Windows.Forms.Label
    if ($rt.inWarning) {
        $when = "约 3 分钟后"
    } else {
        $when = "现在"
    }
    $lbl.Text = ("睡觉时间{0}到（北京时间 {1}）。`n系统将强制关机，请立即保存工作。`n`n可延迟 15 分钟——今晚仅此一次。" -f $when, $rt.beijingHHmm)
    $lbl.SetBounds(28, 24, 500, 130)
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12)
    $form.Controls.Add($lbl)

    $btnDelay = New-Object System.Windows.Forms.Button
    $btnDelay.Text = '延迟 15 分钟（今晚仅一次）'
    $btnDelay.SetBounds(28, 190, 280, 46)
    $btnDelay.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $btnDelay.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnDelay)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '知道了，现在保存'
    $btnOk.SetBounds(330, 190, 190, 46)
    $btnOk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnOk)
    $form.AcceptButton = $btnDelay
    $form.CancelButton = $btnOk
    $form.Add_Shown({ $this.Activate(); $this.BringToFront() })

    $r = $form.ShowDialog()
    $form.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        New-Item -ItemType File -Path $RequestFile -Force | Out-Null
        # 尽力立即中止倒计时（有管理员权限才成功；否则执行器一分钟内会中止）
        cmd /c "shutdown /a" 2>$null | Out-Null
    }
} else {
    # 延迟额度已用完 → 最后提醒（无延迟按钮）
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.Opacity = 0
    $owner.Show()
    [System.Windows.Forms.MessageBox]::Show($owner,
        ("睡觉时间到（北京时间 {0}）。`n`n今晚的延迟机会已用完，系统即将强制关机，请立即保存。" -f $rt.beijingHHmm),
        'BedtimeGuard · 最后提醒',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    $owner.Close()
}

Set-Content -Path $MarkerFile -Value $key -Encoding UTF8
