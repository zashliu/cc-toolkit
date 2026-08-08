# Codex Remote No-Sleep

This small Windows helper keeps the computer awake and keeps the display on while you control Codex from a phone.

It does not change the Windows power plan and does not require administrator rights. The request is released when the helper exits.

## Use

1. Connect the computer from the ChatGPT mobile app.
2. Double-click `Start-CodexRemoteAwake.cmd`, or run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Keep-CodexRemoteAwake.ps1
   ```

3. Leave the helper window running while the remote connection is needed.
4. Press `Ctrl+C` or close the helper window when finished.

The helper is intentionally session-scoped: when it stops, normal Windows sleep and display settings apply again.
