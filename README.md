# cc-toolkit

让 AI 命令行（Claude Code / Gemini CLI）更顺手的跨设备小工具集合。

## clip-paste — 在 Claude Code 里 Alt+V 截图后直接 Ctrl+V 粘贴图片

Windows Terminal 默认把 Ctrl+V 当「粘贴文本」拦截，所以截图（纯图片）按 Ctrl+V
传不到 Claude Code。这个脚本用 AutoHotkey 在 **Windows Terminal 激活时**拦截 Ctrl+V：
剪贴板是图片就先存成 PNG、把文件路径放回剪贴板再粘贴，Claude Code 读取该路径加载图片；
不是图片时 Ctrl+V 行为照旧。其他程序里的 Ctrl+V 完全不受影响。

### 在一台新电脑上启用

前提：Windows 10/11、用 **Windows Terminal** 运行 Claude Code。

```powershell
# 1. 拿到本仓库
git clone https://github.com/zashliu/cc-toolkit.git
cd cc-toolkit

# 2. 一键安装（可重复运行）
powershell -ExecutionPolicy Bypass -File .\setup-clip-paste.ps1
```

或者更省事：在新电脑的 Claude Code 里直接说「clone 我的 cc-toolkit 仓库并运行 setup-clip-paste.ps1」。

脚本会自动：

1. 用 winget 安装 AutoHotkey v2（已装则跳过）
2. 在 `%USERPROFILE%\.cc-clippaste\` 生成 `clip-paste.ahk` 和 `save-clip-image.ps1`
3. 在启动文件夹建快捷方式（开机自启）
4. 在 Windows Terminal 的 `settings.json` 里解绑 Ctrl+V
5. 立即启动拦截脚本

### 使用

1. **Alt+V**（或任意能把图片放进剪贴板的截图工具）截图
2. 在 Claude Code 输入框 **Ctrl+V**

### 说明 / 排错

- 临时图片存在 `%TEMP%\cc-clip\`，可随时清空，不影响功能。
- 没反应时先看托盘里有没有 AutoHotkey 绿色 H 图标；没有就手动运行
  `%USERPROFILE%\.cc-clippaste\clip-paste.ahk`，或重跑安装脚本。
- 第 4 步若提示无法自动改 `settings.json`，手动在 Windows Terminal 设置里把
  Ctrl+V 解绑（unbound）即可。
- 卸载：删掉启动文件夹里的 `cc-clip-paste.lnk` 和 `%USERPROFILE%\.cc-clippaste\`，
  并把 Windows Terminal 的 Ctrl+V 改回 `paste`。

> 注意：这套功能是**操作系统层面**的配置，不随 Claude Code 账号同步——
> 跨设备靠的是本仓库 + 在每台机器上跑一次安装脚本。

---

## notify — Claude Code / Gemini CLI 完成一轮输出时响铃提醒

让 AI 跑完当前回答时发出提示音，方便你及时回来检查结果。原理是给两个 CLI 各挂一个
"完成事件" hook，触发时播放一段系统提示音：

- **Claude Code** → `~/.claude/settings.json` 的 `Stop` hook（回答结束时触发）
- **Gemini CLI** → `~/.gemini/settings.json` 的 `AfterAgent` hook（每轮最终回复生成后触发）

### 启用

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-notify.ps1
```

脚本会自动（幂等，可重复运行）：

1. 在 `%USERPROFILE%\.cc-notify\` 生成 `notify-sound.ps1`（播放系统提示音，stdout 只输出 `{}`）
2. 把 hook 合并进 Claude Code 的 `settings.json`（`Stop`）和 Gemini CLI 的 `settings.json`（`AfterAgent`），
   保留原有配置，写回时不带 BOM（避免 JSON 解析失败）
3. 只对检测到的 CLI 生效（`~/.claude` / `~/.gemini` 存在才改）

> **改完需重启对应 CLI** 才能加载新 hook。

### 说明 / 排错

- 测试声音：`powershell -File "%USERPROFILE%\.cc-notify\notify-sound.ps1"`
- Gemini hook 要求脚本 stdout **只能是 JSON**，所以响铃脚本播完声音输出 `{}`，不打印别的。
- 卸载：编辑两个 `settings.json` 删掉对应的 hook 条目，并删除 `%USERPROFILE%\.cc-notify\`。

> 同样是 OS / CLI 层面配置，不随账号同步，跨设备靠本仓库 + 每台机器跑一次安装脚本。
