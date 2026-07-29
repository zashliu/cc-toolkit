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

---

## claude-plugins — 跨设备同步已装的 Claude Code 插件

Claude Code 的插件（`/plugin marketplace add` + `/plugin install`）只存在本机
`~/.claude/plugins/`，**不随账号同步**，换电脑就没了。这套脚本把「装了哪些 marketplace
和插件」导出成一份与机器无关的清单 `claude-plugins/plugins.manifest.json`，提交进本仓库，
换机后一条命令全部装回。

> 为什么不直接备份 `~/.claude/plugins/*.json`：那两个文件写死了本机绝对路径
> （`C:\Users\<你>\...`）、时间戳、commit SHA，换机/换用户名就失效。清单只抽取
> 真正跨设备需要的「marketplace 来源仓库 + 插件 id/scope」。marketplace 和插件的实际
> 内容都是 git 可重新拉取的，不必入库。

### 备份（装了新插件后跑一次，然后 commit & push）

```powershell
powershell -ExecutionPolicy Bypass -File .\claude-plugins\backup-plugins.ps1
git add claude-plugins/plugins.manifest.json
git commit -m "chore: 更新插件清单"
git push
```

### 在新电脑上还原

前提：已 `npm i -g @anthropic-ai/claude-code` 并登录过。

```powershell
git clone https://github.com/zashliu/cc-toolkit.git
cd cc-toolkit
powershell -ExecutionPolicy Bypass -File .\claude-plugins\restore-plugins.ps1
```

还原脚本读清单，逐个 `claude plugin marketplace add` + `claude plugin install`，**幂等**
（已存在的跳过，可反复跑）。跑完**重启 Claude Code**（或 `/reload-plugins`）让插件生效。

### 装的是最新版还是仓库里的旧版？——**最新版**

清单**只存来源仓库引用 + 插件 id，不存插件内容、不锁版本**。还原时 `marketplace add`
会从那个开源仓库**当场重新克隆**（=此刻的最新），`install` 再从这份新克隆安装，所以装到的
是还原那一刻 upstream 的**最新版**。还原脚本里额外跑了一步 `marketplace update`
兜底，确保即使该 marketplace 在本机已存在（`add` 不拉新）也强制刷到最新。

> 想要相反的「钉住某个版本以求可复现」？本工具不做——它的目标就是跟随上游最新。

### 说明

- 当前清单是 PowerShell 脚本（Windows）。`.ps1` 存成 **UTF-8 with BOM**，否则
  Windows PowerShell 5.1 会把中文注释读乱、解析失败。
- 内置的官方 marketplace `claude-plugins-official` 也在清单里，还原时它通常已存在 → 脚本报
  “already on disk” 跳过，无害。

> 同样不随账号同步，跨设备靠本仓库 + 每台机器跑一次还原脚本。

---

## bedtime-guard — 防熬夜强制关机（按北京时间，防改时间/断网绕过）

到就寝时段（默认**北京时间 23:45–06:00**）自动强制关机。和普通定时关机不同，它防住了「手动改本地时间」和「临时断网」两种绕过：联网用 NTP 取真实时间，断网用开机单调计时器 + 上次联网锚点推算，改系统时钟一律无效。关机前 180 秒倒计时，并弹窗可**延迟 15 分钟（每晚一次）**保存工作。

### 启用

需**管理员** PowerShell（注册 SYSTEM 计划任务）：

```powershell
powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Install.ps1
```

会部署脚本到 `C:\ProgramData\BedtimeGuard\` 并注册 3 个每分钟任务：执行器（SYSTEM，关机）、看门狗（SYSTEM，与执行器互相监护防删）、弹窗器（用户会话，仅夜间运行、隐藏不闪窗）。

### 使用与配置

到点后桌面弹窗 + 倒计时，点「延迟 15 分钟」可顺延一次。窗口时段、倒计时、延迟时长等在 `bedtime-guard/BedtimeGuard.ps1` 顶部可配。卸载：`powershell -ExecutionPolicy Bypass -File .\bedtime-guard\Uninstall.ps1`（管理员）。

详见 [`bedtime-guard/README.md`](bedtime-guard/README.md)。

> ⚠️ `.ps1` 含中文，须存为 **UTF-8 with BOM**（否则 PowerShell 5.1 按 GBK 读取报错）。目标是按 Fogg 行为模型加大熬夜/绕过的阻力，非绝对不可逆。
---

## usage-reminder - live AI quota reset reminders

The Claude watcher reads the live Claude Code OAuth usage endpoint from a `Stop` hook. The first Claude use after boot triggers one check; later checks are allowed only after five hours. It uses the returned `five_hour` and `seven_day` reset timestamps and utilization, and alerts only after an actual reset transition is observed. It does not infer a reset from a clock alone.

Install or refresh it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-usage-reminders.ps1
```

Inspect the live values:

```powershell
powershell -ExecutionPolicy Bypass -File .\usage-reminder.ps1 -Action ShowNext
```

The old fixed-time Claude tasks are removed during installation. Codex remains disabled because this repository does not yet have a comparable live Codex limit data source.
