# cc-toolkit

让 AI 命令行（Claude Code / Gemini CLI）更顺手的跨设备小工具集合。

## sharex-paste — 截图后在 Claude Code 里 Ctrl+V 直接粘贴图片（Windows）

如果你用 [ShareX](https://getsharex.com/) 截图，可以不装 AutoHotkey、不常驻进程、不改
Windows Terminal 设置，就让截图能在 Claude Code 里 **Ctrl+V / 右键**粘贴。

做法：把 ShareX 的「捕获后任务」从「复制图片到剪贴板」改成「保存到文件 + 复制**文件路径**到
剪贴板」。路径是纯文本，任何终端都能粘贴，Claude Code 会自动按该路径加载图片。

### 启用

前提：装了 ShareX 并至少运行过一次。

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-sharex-paste.ps1
```

脚本会自动（幂等，可重复运行）：

1. 找到 `ApplicationConfig.json`（Documents\ShareX 或 %LOCALAPPDATA%\ShareX）
2. 备份 `ApplicationConfig.json` 和 `HotkeysConfig.json` 为 `.bak`
3. 运行中的话先关闭 ShareX（避免它退出时覆盖改动）
4. 把默认 `AfterCaptureJob` 设为 `SaveImageToFile, CopyFilePathToClipboard`
5. **同时改写每个截图热键自带的 `AfterCaptureJob`**（设为复制路径、并关掉「使用默认捕获后任务」）。
   有些截图热键带了自己的捕获后任务，会**覆盖**默认值——只改默认会出现「设了却不生效、
   Ctrl+V 还是粘不进去」的坑，所以这一步直接把每个热键也改掉
6. 重启 ShareX

### 使用

1. 用 ShareX 截图（你原来的快捷键不变）
2. 在 Claude Code 输入框 **Ctrl+V** 或**右键** → 粘进来的是路径 → 回车

### 说明 / 排错

- 改完后 ShareX **不再把图片本身**放进剪贴板，因此往微信等聊天软件直接粘贴截图会失效。
  想恢复：`powershell -ExecutionPolicy Bypass -File .\setup-sharex-paste.ps1 -Revert`，
  或在 ShareX 里同时勾选「复制图片到剪贴板」和「复制文件路径到剪贴板」。
- 若某个截图快捷键单独取消了「使用默认捕获后任务」，在 ShareX 里把它重新勾上即可继承默认。

> 同样是 OS / 工具层面配置，不随账号同步，跨设备靠本仓库 + 每台机器跑一次安装脚本。

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
