$ErrorActionPreference = 'Stop'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'LightBulb.lnk'
Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name LightBulb -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable('LIGHTBULB_ALLOW_AUTO_UPDATE', $null, 'User')
Write-Host 'Eye-care startup customization removed. LightBulb itself was not uninstalled.'
