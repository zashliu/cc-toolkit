# restore-plugins.ps1
# 在一台新机器上还原 Claude Code 插件:读取 plugins.manifest.json,逐个把
# marketplace 加回来、把插件装回去。幂等 —— 已存在的会跳过,可反复跑。
#
# 前置:已安装 claude CLI(npm i -g @anthropic-ai/claude-code)并登录过。
# 用法:在 cc-toolkit\claude-plugins 目录里跑  ./restore-plugins.ps1
# 跑完后重启 Claude Code(或在会话里 /reload-plugins)让插件生效。

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PSScriptRoot 'plugins.manifest.json'
if (-not (Test-Path $manifestPath)) { throw "找不到 $manifestPath" }

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw "没找到 claude CLI。先 npm i -g @anthropic-ai/claude-code 并登录,再跑本脚本。"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

Write-Host "== 还原 marketplaces ==" -ForegroundColor Cyan
foreach ($m in $manifest.marketplaces) {
    Write-Host "  + $($m.name)  ($($m.source))"
    try {
        claude plugin marketplace add $m.source 2>&1 | Out-Host
    } catch {
        Write-Host "    (跳过/已存在:$($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

Write-Host "== 还原 plugins ==" -ForegroundColor Cyan
foreach ($p in $manifest.plugins) {
    $scope = if ($p.scope) { $p.scope } else { 'user' }
    Write-Host "  + $($p.id)  (scope=$scope)"
    try {
        claude plugin install $p.id --scope $scope 2>&1 | Out-Host
    } catch {
        Write-Host "    (跳过/已存在:$($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "完成。重启 Claude Code 或在会话里 /reload-plugins 让插件生效。" -ForegroundColor Green
