---
name: blink
description: Control the claude-caps-blink Caps Lock status light - start or stop it, check whether it is running, or change which states blink. Use when the user mentions the caps lock blinker, status light, or LED.
---

# Controlling the Caps Lock status light

claude-caps-blink blinks the Caps Lock LED while Claude Code works (slow),
needs attention (fast), or finishes (3 flashes). Runtime data lives in
`$env:LOCALAPPDATA\claude-caps-blink` (`flags\`, `config.json`, `mode.txt`,
`disabled` marker). The install directory is wherever `hook-state.exe` /
`blinker.ps1` live - find it from the hook commands in
`~/.claude/settings.json` if needed. All commands below are PowerShell.

## Status

```powershell
$b = Join-Path $env:LOCALAPPDATA 'claude-caps-blink'
$running = $false
try { ([System.Threading.Mutex]::OpenExisting('ClaudeCapsBlinker')).Dispose(); $running = $true }
catch [System.UnauthorizedAccessException] { $running = $true } catch {}
"running=$running  mode=$(Get-Content (Join-Path $b 'mode.txt') -ErrorAction SilentlyContinue)"
Get-Content (Join-Path $b 'config.json') -ErrorAction SilentlyContinue
```

`mode` is `led` (drives only the light; typing unaffected) or `toggle`
(fallback without elevation). `config.json` shows which of slow/fast/done are
enabled.

## Start (or re-enable after a stop/Exit)

```powershell
schtasks /Run /TN ClaudeCapsBlink 2>$null
```

If the task does not exist (LED mode never set up), launch directly instead:

```powershell
Start-Process -WindowStyle Hidden powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','<INSTALL_DIR>\blinker.ps1'
```

Either path clears the `disabled` marker automatically on startup.

## Stop

Create the `disabled` marker; the app notices within ~300ms, restores the
LED/caps state, exits, and hooks stop relaunching it. Works without admin even
when the app runs elevated:

```powershell
New-Item -ItemType File -Force -Path (Join-Path $env:LOCALAPPDATA 'claude-caps-blink\disabled') | Out-Null
```

## Change which states blink

The tray menu (right-click the dot behind the taskbar chevron) changes them
live - prefer pointing the user there. Programmatically: edit the booleans in
`config.json`, then stop and start the app (config is read at startup).

## LED mode setup / uninstall

Run `setup-led-mode.ps1` (one UAC prompt) or `uninstall.ps1` from the install
directory.
