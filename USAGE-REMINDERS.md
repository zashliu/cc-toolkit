# AI usage reset reminders

The reminder uses Windows Task Scheduler and registers only the next reset for each limit. When it fires, it plays the Windows notification sound, shows a notification, and schedules the following reset.

Edit `usage-reminders.json` before installation:

- `period: "5h"` means a rolling five-hour reset.
- `period: "weekly"` means a seven-day reset.
- `anchor` must be the provider's known reset time in ISO 8601 format, including the time-zone offset, for example `2026-08-05T01:59:00+08:00`.
- Set `enabled` to `true` for a reminder. Claude entries are enabled from the supplied usage screenshot; Codex entries remain disabled until its own reset times are entered.

Install or refresh the tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-usage-reminders.ps1
```

Inspect the next scheduled alerts:

```powershell
powershell -ExecutionPolicy Bypass -File .\usage-reminder.ps1 -Action ShowNext
```
