# Claude Code caps-lock blinker - tray app.
# Lives in the taskbar notification area (behind the ^ chevron). Right-click for
# per-state toggles and Exit. Launched hidden by hook-state.ps1, start-blink.cmd,
# or the ClaudeCapsBlink scheduled task (elevated -> LED mode).
#
# States (driven by flag files written by Claude Code hooks):
#   working   -> slow blink   (green icon)
#   attention -> fast blink   (red icon)    - permission prompts, errors
#   done      -> 3 quick flashes, then dark (blue icon during flash)
#
# Two blink backends:
#   LED mode    - requires admin. Drives the keyboard LED directly via
#                 IOCTL_KEYBOARD_SET_INDICATORS; the real Caps Lock state is
#                 never touched, so typing is never affected (same idea as
#                 macOS IOKit tools). Run setup-led-mode.ps1 once to enable.
#   toggle mode - no admin. Really toggles Caps Lock with short asymmetric
#                 pulses (~120ms deviation per cycle) plus a typing guard:
#                 any real keyboard/mouse input restores the original caps
#                 state within one 50ms tick and pauses blinking until 4s idle.
#
# A 'pause' marker file in the base dir suspends blinking (used by setup to
# kill/restart this process safely). All scripts must stay ASCII (PS 5.1 reads
# BOM-less files as ANSI).

$ErrorActionPreference = 'SilentlyContinue'

$baseDir  = Join-Path $env:LOCALAPPDATA 'claude-caps-blink'
$flagDir  = Join-Path $baseDir 'flags'
$cfgPath  = Join-Path $baseDir 'config.json'
$disabled = Join-Path $baseDir 'disabled'
$pausePath = Join-Path $baseDir 'pause'
$modePath  = Join-Path $baseDir 'mode.txt'

New-Item -ItemType Directory -Force -Path $flagDir | Out-Null

# A manual launch (start-blink.cmd / scheduled task) re-enables after a tray
# Exit; hook-state.ps1 refuses to launch while the marker exists.
Remove-Item -Force $disabled

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ClaudeCapsBlinker', [ref]$created)
if (-not $created) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class CapsBlink {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]   public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")]   public static extern short GetKeyState(int nVirtKey);
    [DllImport("user32.dll")]   public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();

    const int VK_CAPITAL = 0x14;
    const uint KEYEVENTF_KEYUP = 0x2;

    public static bool CapsOn()   { return (GetKeyState(0x14) & 1) == 1; }
    public static bool NumOn()    { return (GetKeyState(0x90) & 1) == 1; }
    public static bool ScrollOn() { return (GetKeyState(0x91) & 1) == 1; }
    public static void Toggle() {
        keybd_event((byte)VK_CAPITAL, 0x45, 0, UIntPtr.Zero);
        keybd_event((byte)VK_CAPITAL, 0x45, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
    public static uint LastInputTick() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref lii);
        return lii.dwTime;
    }
}

// Direct keyboard LED control via the kbdclass driver. Opening the device
// needs administrator rights; Init() returns 0 without them and the app
// falls back to toggle mode.
public static class KbdLed {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool DefineDosDeviceW(uint dwFlags, string lpDeviceName, string lpTargetPath);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        ref KEYBOARD_INDICATOR_PARAMETERS lpInBuffer, int nInBufferSize,
        IntPtr lpOutBuffer, int nOutBufferSize, out int lpBytesReturned, IntPtr lpOverlapped);

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBOARD_INDICATOR_PARAMETERS { public ushort UnitId; public ushort LedFlags; }

    const uint DDD_RAW_TARGET_PATH = 0x1;
    const uint DDD_REMOVE_DEFINITION = 0x2;
    const uint GENERIC_WRITE = 0x40000000;
    const uint OPEN_EXISTING = 3;
    const uint IOCTL_KEYBOARD_SET_INDICATORS = 0x000B0008;
    // LedFlags bits: 1 = scroll, 2 = num, 4 = caps

    static List<IntPtr> handles = new List<IntPtr>();

    public static int Init() {
        for (int i = 0; i < 8; i++) {
            string dos = "ClaudeKbd" + i;
            if (!DefineDosDeviceW(DDD_RAW_TARGET_PATH, dos, "\\Device\\KeyboardClass" + i)) continue;
            IntPtr h = CreateFileW("\\\\.\\" + dos, GENERIC_WRITE, 0, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            DefineDosDeviceW(DDD_RAW_TARGET_PATH | DDD_REMOVE_DEFINITION, dos, "\\Device\\KeyboardClass" + i);
            if (h != IntPtr.Zero && h.ToInt64() != -1) handles.Add(h);
        }
        return handles.Count;
    }

    public static void SetLeds(bool caps, bool num, bool scroll) {
        ushort flags = 0;
        if (scroll) flags |= 1;
        if (num)    flags |= 2;
        if (caps)   flags |= 4;
        foreach (IntPtr h in handles) {
            KEYBOARD_INDICATOR_PARAMETERS p = new KEYBOARD_INDICATOR_PARAMETERS();
            p.UnitId = 0;
            p.LedFlags = flags;
            int ret;
            DeviceIoControl(h, IOCTL_KEYBOARD_SET_INDICATORS, ref p, Marshal.SizeOf(typeof(KEYBOARD_INDICATOR_PARAMETERS)),
                IntPtr.Zero, 0, out ret, IntPtr.Zero);
        }
    }
}
"@

$script:ledMode = ([KbdLed]::Init() -gt 0)
Set-Content -Path $modePath -Value $(if ($script:ledMode) { 'led' } else { 'toggle' })

function Show-CapsLed([bool]$lit) {
    # LED mode only: paint the caps LED; num/scroll always mirror reality
    [KbdLed]::SetLeds($lit, [CapsBlink]::NumOn(), [CapsBlink]::ScrollOn())
}
function Sync-Led {
    Show-CapsLed ([CapsBlink]::CapsOn())
    $script:ledLit = $false
}

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $brush.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

$icons = @{
    idle = New-DotIcon ([System.Drawing.Color]::DimGray)
    slow = New-DotIcon ([System.Drawing.Color]::LimeGreen)
    fast = New-DotIcon ([System.Drawing.Color]::OrangeRed)
    done = New-DotIcon ([System.Drawing.Color]::DodgerBlue)
}

# --- config (which states are enabled) ---
$cfg = @{ slow = $true; fast = $true; done = $true }
if (Test-Path $cfgPath) {
    try {
        $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($null -ne $j.slow) { $cfg.slow = [bool]$j.slow }
        if ($null -ne $j.fast) { $cfg.fast = [bool]$j.fast }
        if ($null -ne $j.done) { $cfg.done = [bool]$j.done }
    } catch {}
}

# --- tray icon + menu ---
$miSlow = New-Object System.Windows.Forms.ToolStripMenuItem('Working - slow blink')
$miFast = New-Object System.Windows.Forms.ToolStripMenuItem('Needs attention - fast blink')
$miDone = New-Object System.Windows.Forms.ToolStripMenuItem('Done - flash then dark')
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
foreach ($mi in @($miSlow, $miFast, $miDone)) { $mi.CheckOnClick = $true }
$miSlow.Checked = $cfg.slow
$miFast.Checked = $cfg.fast
$miDone.Checked = $cfg.done

$saveCfg = {
    @{ slow = $miSlow.Checked; fast = $miFast.Checked; done = $miDone.Checked } |
        ConvertTo-Json | Set-Content $cfgPath
}
$miSlow.add_CheckedChanged($saveCfg)
$miFast.add_CheckedChanged($saveCfg)
$miDone.add_CheckedChanged($saveCfg)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.AddRange(@(
    $miSlow, $miFast, $miDone,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $miExit
))

$modeLabel = $(if ($script:ledMode) { 'LED mode' } else { 'toggle mode' })
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $icons.idle
$notify.Text = "Claude blink - idle ($modeLabel)"
$notify.ContextMenuStrip = $menu
$notify.Visible = $true

$miExit.add_Click({
    New-Item -ItemType File -Path $disabled -Force | Out-Null
    [System.Windows.Forms.Application]::Exit()
})

# --- blink state machine ---
$script:mode         = 'idle'    # idle | slow | fast | doneAnim
$script:displayState = 'idle'
$script:suspended    = $false    # pause marker present
$script:donePulses   = 0
$script:pollCounter  = 0
$script:lastToggle   = [uint32]0
# LED mode state
$script:ledLit       = $false    # LED currently deviating from real caps state
# toggle mode state
$script:tracking     = $false    # true while we own the caps state
$script:original     = $false    # caps state to restore
$script:deviated     = $false    # caps currently differs from original
$script:pausedByUser = $false
$script:lastSyn      = [uint32]0 # tick of our last synthetic keypress

$idleGraceMs = 4000

function Restore-Caps {
    if ([CapsBlink]::CapsOn() -ne $script:original) {
        [CapsBlink]::Toggle()
        $script:lastSyn = [CapsBlink]::GetTickCount()
    }
    $script:deviated = $false
}

function Complete-DonePulse {
    $script:donePulses++
    if ($script:donePulses -ge 3) {
        $script:mode = 'idle'
        $script:tracking = $false
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.add_Tick({
    # ---- poll flag files every ~300ms ----
    $script:pollCounter++
    if ($script:pollCounter -ge 6) {
        $script:pollCounter = 0
        # External stop request: tray Exit, stop-blink.cmd, or the /blink skill
        # create this marker; exit gracefully so the LED/caps state is restored.
        if (Test-Path $disabled) { [System.Windows.Forms.Application]::Exit(); return }
        $script:suspended = Test-Path $pausePath
        $working = $false; $attention = $false; $doneFiles = @()
        foreach ($f in @(Get-ChildItem $flagDir -Filter '*.flag')) {
            if ($f.LastWriteTime -lt (Get-Date).AddHours(-2)) { Remove-Item $f.FullName -Force; continue }
            $s = Get-Content $f.FullName -TotalCount 1
            if ($s -eq 'attention')  { $attention = $true }
            elseif ($s -eq 'done')   { $doneFiles += $f.FullName }
            else                     { $working = $true }
        }
        if ($doneFiles.Count -gt 0) { $doneFiles | Remove-Item -Force }

        if ($attention)   { $script:mode = 'fast' }
        elseif ($working) { $script:mode = 'slow' }
        elseif ($script:mode -eq 'doneAnim') { }  # let the animation finish
        elseif ($doneFiles.Count -gt 0) {
            if ($miDone.Checked) { $script:mode = 'doneAnim'; $script:donePulses = 0 }
            else { $script:mode = 'idle' }
        }
        else { $script:mode = 'idle' }

        $disp = 'idle'
        if ($script:mode -eq 'fast') { $disp = 'fast' }
        elseif ($script:mode -eq 'slow') { $disp = 'slow' }
        elseif ($script:mode -eq 'doneAnim') { $disp = 'done' }
        if ($disp -ne $script:displayState) {
            $script:displayState = $disp
            $notify.Icon = $icons[$disp]
            if ($disp -eq 'fast')     { $notify.Text = "Claude blink - needs attention ($modeLabel)" }
            elseif ($disp -eq 'slow') { $notify.Text = "Claude blink - working ($modeLabel)" }
            elseif ($disp -eq 'done') { $notify.Text = "Claude blink - done ($modeLabel)" }
            else                      { $notify.Text = "Claude blink - idle ($modeLabel)" }
        }
    }

    # ---- pulse durations ----
    $onMs = 0; $offMs = 0
    if ($script:ledMode) {
        # LED-only: typing is unaffected, so symmetric blinking looks best
        if ($script:mode -eq 'slow' -and $miSlow.Checked)     { $onMs = 400; $offMs = 600 }
        elseif ($script:mode -eq 'fast' -and $miFast.Checked) { $onMs = 150; $offMs = 150 }
        elseif ($script:mode -eq 'doneAnim')                  { $onMs = 150; $offMs = 150 }
    }
    else {
        # Toggle mode: keep the deviation window as short as possible
        if ($script:mode -eq 'slow' -and $miSlow.Checked)     { $onMs = 120; $offMs = 900 }
        elseif ($script:mode -eq 'fast' -and $miFast.Checked) { $onMs = 100; $offMs = 200 }
        elseif ($script:mode -eq 'doneAnim')                  { $onMs = 120; $offMs = 180 }
    }
    $idle = ($onMs -eq 0 -or $script:suspended)

    # ================= LED mode =================
    if ($script:ledMode) {
        if ($idle) {
            if ($script:ledLit) { Sync-Led }
            if ($script:mode -eq 'doneAnim' -and $script:suspended) { $script:mode = 'idle' }
            return
        }
        $now = [CapsBlink]::GetTickCount()
        if ($script:ledLit) {
            if (($now - $script:lastToggle) -ge $onMs) {
                Sync-Led
                $script:lastToggle = $now
                if ($script:mode -eq 'doneAnim') { Complete-DonePulse }
            }
        }
        else {
            if (($now - $script:lastToggle) -ge $offMs) {
                Show-CapsLed (-not [CapsBlink]::CapsOn())
                $script:ledLit = $true
                $script:lastToggle = $now
            }
        }
        return
    }

    # ================= toggle mode =================
    if ($idle) {
        if ($script:tracking) {
            Restore-Caps
            $script:tracking = $false
            $script:pausedByUser = $false
        }
        if ($script:mode -eq 'doneAnim' -and $script:suspended) { $script:mode = 'idle' }
        return
    }

    # Our own synthetic keypresses also update GetLastInputInfo, so only treat
    # input newer than our last synthetic toggle as real user activity.
    $now  = [CapsBlink]::GetTickCount()
    $last = [CapsBlink]::LastInputTick()
    $userActive = ($last -gt ($script:lastSyn + 100)) -and (($now - $last) -lt $idleGraceMs)

    if ($userActive) {
        if ($script:tracking) {
            if (-not $script:pausedByUser) {
                Restore-Caps
                $script:pausedByUser = $true
            }
            else {
                # Adopt intentional caps changes the user makes while paused
                $script:original = [CapsBlink]::CapsOn()
            }
        }
        return
    }

    $script:pausedByUser = $false
    if (-not $script:tracking) {
        $script:original = [CapsBlink]::CapsOn()
        $script:tracking = $true
        $script:deviated = $false
        $script:lastToggle = [uint32]0
    }

    if ($script:deviated) {
        if (($now - $script:lastToggle) -ge $onMs) {
            [CapsBlink]::Toggle()
            $script:lastSyn = [CapsBlink]::GetTickCount()
            $script:lastToggle = $now
            $script:deviated = $false
            if ($script:mode -eq 'doneAnim') {
                Complete-DonePulse
                if ($script:mode -eq 'idle') { Restore-Caps }
            }
        }
    }
    else {
        if (($now - $script:lastToggle) -ge $offMs) {
            [CapsBlink]::Toggle()
            $script:lastSyn = [CapsBlink]::GetTickCount()
            $script:lastToggle = $now
            $script:deviated = $true
        }
    }
})

$timer.Start()
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))

# Exit was clicked: clean up
$timer.Stop()
if ($script:ledMode) { Sync-Led }
elseif ($script:tracking) { Restore-Caps }
$notify.Visible = $false
$notify.Dispose()
$mutex.ReleaseMutex()
