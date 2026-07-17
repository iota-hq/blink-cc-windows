@echo off
rem Re-enables and starts the Claude caps-lock blinker tray app after a tray Exit.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0blinker.ps1"
