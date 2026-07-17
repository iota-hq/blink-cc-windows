@echo off
rem Stops the blinker tray app gracefully (within ~300ms, restoring the LED)
rem and prevents Claude Code hooks from relaunching it. Works without admin
rem even when the app runs elevated. Re-enable with start-blink.cmd.
if not exist "%LOCALAPPDATA%\claude-caps-blink" mkdir "%LOCALAPPDATA%\claude-caps-blink"
type nul > "%LOCALAPPDATA%\claude-caps-blink\disabled"
