@echo off
setlocal
title Codex Remote Awake
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Keep-CodexRemoteAwake.ps1"
pause
