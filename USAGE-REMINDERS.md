# AI usage reset reminders

The Claude watcher reads the same live OAuth usage endpoint used by Claude Code:

`https://api.anthropic.com/api/oauth/usage`

It reads `five_hour` and `seven_day` usage, reset timestamps, and utilization. It runs from Claude Code's `Stop` hook: the first Claude use after boot triggers one check, then another check is allowed only after five hours. It stores only the latest non-secret snapshot in `%LOCALAPPDATA%\cc-toolkit\usage-reminder-state.json`.

An alert is emitted only when both conditions are true:

1. The API reports a new future reset window after the previous window ended.
2. Utilization falls by at least 10 percentage points (or to 5% or less).

Therefore a clock reaching the old `resets_at` does not by itself trigger an alert. If Claude only applies the reset after the next user prompt, the hook after that prompt performs the next eligible check and detects the actual API transition.

Install or refresh the watcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-usage-reminders.ps1
```

Inspect live data without changing tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\usage-reminder.ps1 -Action ShowNext
```

The endpoint is an internal Claude Code OAuth endpoint rather than a stable public API. If Anthropic changes it, the watcher fails closed and warns instead of generating a false reset alert. Codex remains disabled until a comparable live data source is available.
