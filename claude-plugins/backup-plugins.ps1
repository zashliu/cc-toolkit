# backup-plugins.ps1
# 把本机已安装的 Claude Code 插件 + marketplace 导出成一份「与机器无关」的清单
# (plugins.manifest.json),供提交到 git、换机后用 restore-plugins.ps1 还原。
#
# 为什么不直接备份 ~/.claude/plugins/*.json:那两个文件写死了本机绝对路径
# (C:\Users\<你>\...)、时间戳、commit SHA —— 换机/换用户名就失效。这里只抽取
# 「marketplace 来源仓库」和「插件 id + scope」,这些才是跨设备真正需要的信息。
#
# 用法:装了新插件后,跑一次本脚本,然后在 cc-toolkit 里 git commit & push。

$ErrorActionPreference = 'Stop'

$pluginsDir = Join-Path $env:USERPROFILE '.claude\plugins'
$knownPath = Join-Path $pluginsDir 'known_marketplaces.json'
$installedPath = Join-Path $pluginsDir 'installed_plugins.json'
$outPath = Join-Path $PSScriptRoot 'plugins.manifest.json'

if (-not (Test-Path $knownPath)) { throw "找不到 $knownPath —— 这台机器还没加过任何 marketplace?" }

$known = Get-Content $knownPath -Raw | ConvertFrom-Json

$marketplaces = @()
foreach ($name in $known.PSObject.Properties.Name) {
    $src = $known.$name.source
    # github 源 → 用 owner/repo;其它(URL / 本地路径)→ 用原始 source 字符串。
    $source = if ($src.source -eq 'github') { $src.repo } else { $src.source }
    $marketplaces += [ordered]@{ name = $name; source = $source }
}

$plugins = @()
if (Test-Path $installedPath) {
    $installed = Get-Content $installedPath -Raw | ConvertFrom-Json
    foreach ($id in $installed.plugins.PSObject.Properties.Name) {
        $entries = $installed.plugins.$id
        $scope = if ($entries -and $entries[0].scope) { $entries[0].scope } else { 'user' }
        $plugins += [ordered]@{ id = $id; scope = $scope }
    }
}

$manifest = [ordered]@{
    _comment = '由 backup-plugins.ps1 生成。换机后用 restore-plugins.ps1 还原。装了新插件就重跑备份脚本并提交。'
    generatedAt = (Get-Date).ToString('o')
    marketplaces = $marketplaces
    plugins = $plugins
}

$manifest | ConvertTo-Json -Depth 6 | Out-File $outPath -Encoding utf8
Write-Host "已写入 $outPath" -ForegroundColor Green
Write-Host "  marketplaces: $($marketplaces.Count)，plugins: $($plugins.Count)"
Write-Host "记得在 cc-toolkit 里 git add/commit/push。" -ForegroundColor Yellow
