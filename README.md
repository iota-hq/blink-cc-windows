# 💡 claude-caps-blink

Your Caps Lock LED becomes a status light for [Claude Code](https://claude.com/claude-code)
on Windows: 🟢 slow blink while Claude works, 🔴 fast blink when it needs you,
🔵 three flashes when it's done. Controlled from a small tray app.

Windows counterpart of [capsOS-Agent-Tracker](https://github.com/devkriter/capsOS-Agent-Tracker) (macOS).

## 📦 Install

Requires Windows 10/11 and Claude Code. No downloads, no dependencies -
everything uses components that ship with Windows.

### 🤖 Automatic (let Claude do it)

Paste this into any Claude Code session:

> Install https://github.com/iota-hq/blink-cc-windows (clone it and run install.ps1)

### 🔧 Manual

```
git clone https://github.com/iota-hq/blink-cc-windows
cd blink-cc-windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

Either way, the installer:
1. ⚡ Compiles a tiny `hook-state.exe` locally with the built-in .NET compiler
   (fast hook reactions, ~0.5s instead of ~3s)
2. 🪝 Merges six hooks into your user-level `~/.claude/settings.json`
   (existing settings and hooks are preserved; re-running updates cleanly)
3. 🗣️ Adds a `/blink` skill, so from then on you can just tell Claude
   "turn the blinker off/on" - no reference to this repo ever needed again
4. 🔍 Adds a **Claude Caps Blink** entry to the Start Menu
5. 💡 Offers **LED mode** (recommended): one UAC approval registers a
   scheduled task so the app can drive the LED directly - your real Caps Lock
   state is then never touched
6. ▶️ Starts the tray app

Restart your Claude Code sessions (or run `/hooks` in them) to activate.
Uninstall with `uninstall.ps1` - it removes only what install added.

## 🚦 States

| State | LED | Tray icon | Triggered by |
|-------|-----|-----------|--------------|
| Working | slow blink | 🟢 green | prompt submitted, tools running |
| Needs attention | fast blink | 🔴 red | permission prompts, errors |
| Done | 3 quick flashes, then dark | 🔵 blue flash | turn finished |
| Idle | off (your real caps state) | ⚫ gray | no active sessions |

## 🎛️ Turning it on and off

The app starts automatically: hooks launch it when Claude works, and the
scheduled task starts it at logon. Preferences persist. Ways to control it:

- 🖱️ **Tray menu** (right-click the dot behind the taskbar `^` chevron):
  checkmark any of the three states on/off, or **Exit**
- 🔎 **Start Menu**: exited from the taskbar? Press Win, type "blink", and
  launch **Claude Caps Blink** to bring it back
- 📁 **`stop-blink.cmd` / `start-blink.cmd`**: manual off/on from Explorer
- 🗣️ **Ask Claude**: "turn the blinker off", "is the blinker running?" -
  works in any Claude Code session via the `/blink` skill

While stopped (Exit or stop), hooks won't relaunch it - but the logon task
brings it back at your next sign-in, so a stop lasts until then.

## 🔐 Permissions

- **Base install: none.** Runs as your user, no network, no drivers installed.
- **LED mode: one UAC approval**, once. Elevation is needed to open the
  Windows keyboard class driver and send the standard set-LED command
  (`IOCTL_KEYBOARD_SET_INDICATORS`) - the same call Windows itself makes when
  you press Caps Lock. Without it the app falls back to toggle mode.

## ⚙️ The two blink backends

**💡 LED mode** (elevated via the scheduled task): only the light blinks; the
real Caps Lock state never changes, so typing is never affected. Num/Scroll
LEDs always mirror their true state.

**⌨️ Toggle mode** (fallback, zero permissions): really toggles Caps Lock using
short asymmetric pulses (~120ms deviation per cycle) plus a typing guard: any
real keyboard/mouse input restores your caps state within ~50ms and pauses
blinking until you've been idle 4s. Intentional caps changes while paused are
adopted as the new baseline.

The tray tooltip shows the active mode.

## 🧩 How it works

Claude Code hooks (`UserPromptSubmit`, `PostToolUse`, `Notification`,
`StopFailure`, `Stop`, `SessionEnd`) invoke `hook-state.exe`, which writes
per-session state flags to `%LOCALAPPDATA%\claude-caps-blink\flags\`. The tray
app (`blinker.ps1`, hidden PowerShell + WinForms, single instance) polls the
flags every 300ms and drives the LED. Multiple sessions aggregate: attention
beats working; done fires only when nothing else is active; flags older than
2h are treated as crashed sessions and cleaned up.

Files: `blinker.ps1` (tray app), `hook-state.cs`/`.ps1` (hook helper, exe +
fallback), `install.ps1` / `uninstall.ps1`, `setup-led-mode.ps1` (scheduled
task for LED mode), `start-blink.cmd` / `stop-blink.cmd` (manual control),
`.claude/skills/blink/` (the `/blink` skill).

Scripts are ASCII-only on purpose: Windows PowerShell 5.1 misreads BOM-less
UTF-8 in `.ps1` files.

## 🙏 Credits

Idea and state design inspired by
[capsOS-Agent-Tracker](https://github.com/devkriter/capsOS-Agent-Tracker).

MIT licensed.
