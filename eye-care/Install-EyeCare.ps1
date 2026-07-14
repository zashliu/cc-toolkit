$ErrorActionPreference = 'Stop'

$appName = 'LightBulb'
$exe = Join-Path ${env:ProgramFiles(x86)} 'LightBulb\LightBulb.exe'
$settingsPath = Join-Path $env:APPDATA 'LightBulb\Settings.json'
$startupPath = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupPath 'LightBulb.lnk'
$templatePath = Join-Path $PSScriptRoot 'Settings.template.json'

if (-not (Test-Path -LiteralPath $exe)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'LightBulb is not installed and winget is unavailable.'
    }
    winget install --id Tyrrrz.LightBulb -e --silent --accept-package-agreements --accept-source-agreements
}

Get-Process -Name $appName -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

$settingsDir = Split-Path $settingsPath
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{}
}
$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json

foreach ($property in $template.PSObject.Properties) {
    if ($property.Name -eq 'DayConfiguration' -or $property.Name -eq 'NightConfiguration') {
        if (-not ($settings.PSObject.Properties.Name -contains $property.Name)) {
            $settings | Add-Member -MemberType NoteProperty -Name $property.Name -Value ([pscustomobject]@{})
        }
        foreach ($nested in $property.Value.PSObject.Properties) {
            $settings.($property.Name) | Add-Member -MemberType NoteProperty -Name $nested.Name -Value $nested.Value -Force
        }
    } else {
        $settings | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
    }
}
$settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

[Environment]::SetEnvironmentVariable('LIGHTBULB_ALLOW_AUTO_UPDATE', '0', 'User')
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $appName -ErrorAction SilentlyContinue

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = Split-Path $exe
$shortcut.WindowStyle = 7
$shortcut.Description = 'LightBulb eye comfort'
$shortcut.Save()
[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null
[Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

Start-Process -FilePath $exe -WindowStyle Minimized
Write-Host 'Eye-care configuration installed. LightBulb will start minimized and skip update checks.'
