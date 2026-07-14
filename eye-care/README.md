# LightBulb 护眼配置

这套配置用于 Windows 上的 LightBulb：

- 白天色温 5600K，亮度 95%
- 夜间色温 4000K，亮度 90%
- 关闭启动时自动更新检查
- 开机自动启动并最小化
- 保留现有 LightBulb 配置中的其他设置

## 安装

在 PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-EyeCare.ps1
```

脚本会在未安装 LightBulb 时通过 `winget` 安装它。安装完成后，重启电脑即可验证开机最小化启动。

## 卸载本方案

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Uninstall-EyeCare.ps1
```

这只会移除本方案创建的启动快捷方式和自动更新环境变量，不会卸载 LightBulb，也不会删除 LightBulb 的配置文件。
