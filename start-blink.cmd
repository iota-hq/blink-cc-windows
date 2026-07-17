@echo off
rem Re-enables and starts the blinker tray app after a tray Exit.
rem Prefers the scheduled task so the app runs elevated (LED mode);
rem falls back to a direct (toggle mode) launch if the task is absent.
schtasks /Run /TN ClaudeCapsBlink >nul 2>&1
if errorlevel 1 start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0blinker.ps1"
