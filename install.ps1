# claude-caps-blink installer.
#   powershell -ExecutionPolicy Bypass -File install.ps1
# Idempotent: safe to re-run (also serves as the update path). Compiles the
# fast hook helper, merges hooks into ~/.claude/settings.json without touching
# anything else in the file, optionally sets up LED mode, starts the tray app.

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

Write-Host "Installing claude-caps-blink from $dir"
Get-ChildItem $dir -File | Unblock-File -ErrorAction SilentlyContinue

# --- 1. compile the fast hook helper (falls back to hook-state.ps1) ---
$exePath = Join-Path $dir 'hook-state.exe'
$useExe = $false
try {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (Test-Path $exePath) { Remove-Item -Force $exePath }
    & $csc /nologo /optimize "/out:$exePath" (Join-Path $dir 'hook-state.cs') | Out-Null
    $useExe = Test-Path $exePath
} catch {}
if ($useExe) { Write-Host 'Compiled hook-state.exe (fast hooks).' }
else { Write-Warning 'Could not compile hook-state.exe; using PowerShell hooks (slower but fine).' }

# --- 2. merge hooks into user-level Claude Code settings ---
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
$settings = $null
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($null -eq $settings) { $settings = [pscustomobject]@{} }
} else { $settings = [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$hooks = $settings.hooks

$events = @(
    @{ name = 'UserPromptSubmit'; state = 'working';   launch = $true;  async = $true }
    @{ name = 'PostToolUse';      state = 'working';   launch = $false; async = $true }
    @{ name = 'Notification';     state = 'attention'; launch = $true;  async = $true }
    @{ name = 'StopFailure';      state = 'attention'; launch = $false; async = $true }
    @{ name = 'Stop';             state = 'done';      launch = $false; async = $true }
    @{ name = 'SessionEnd';       state = 'end';       launch = $false; async = $false }
)

foreach ($ev in $events) {
    $stateArgs = @('-State', $ev.state)
    if ($ev.launch) { $stateArgs += '-Launch' }
    if ($useExe) { $cmd = $exePath; $allArgs = $stateArgs }
    else {
        $cmd = 'powershell.exe'
        $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'hook-state.ps1')) + $stateArgs
    }
    $hookObj = [pscustomobject]@{ type = 'command'; command = $cmd; args = $allArgs; timeout = 15 }
    if ($ev.async) { $hookObj | Add-Member -NotePropertyName async -NotePropertyValue $true }
    $entry = [pscustomobject]@{ hooks = @($hookObj) }

    # Drop any previous claude-caps-blink entries for this event, keep everything else
    $kept = @()
    if ($hooks.PSObject.Properties[$ev.name]) {
        $kept = @($hooks.($ev.name)) | Where-Object {
            -not (@($_.hooks) | Where-Object {
                ($_.command -match 'hook-state') -or ((@($_.args) -join ' ') -match 'hook-state')
            })
        }
    }
    $newList = @($kept) + @($entry)
    if ($hooks.PSObject.Properties[$ev.name]) { $hooks.($ev.name) = $newList }
    else { $hooks | Add-Member -NotePropertyName $ev.name -NotePropertyValue $newList }
}

# Write without BOM (Windows PowerShell's UTF8 adds one; some parsers reject it)
[System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 12))
Write-Host "Hooks merged into $settingsPath"

# --- 2b. install the /blink skill so any Claude session can control the app ---
$skillSrc = Join-Path $dir '.claude\skills\blink\SKILL.md'
if (Test-Path $skillSrc) {
    $skillDst = Join-Path $env:USERPROFILE '.claude\skills\blink'
    New-Item -ItemType Directory -Force -Path $skillDst | Out-Null
    Copy-Item -Force $skillSrc $skillDst
    Write-Host 'Installed the /blink skill (tell Claude "turn the blinker off/on").'
}

# --- 2c. Start Menu shortcut so the app is searchable/startable like any app ---
try {
    $lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Caps Blink.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $dir 'start-blink.cmd'
    $lnk.WorkingDirectory = $dir
    $lnk.WindowStyle = 7  # minimized: the cmd only fires the task and exits
    $lnk.Description = 'Start the Caps Lock status light for Claude Code'
    $lnk.IconLocation = '%SystemRoot%\System32\main.cpl,1'  # keyboard icon
    $lnk.Save()
    Write-Host 'Added "Claude Caps Blink" to the Start Menu.'
} catch {}

# --- 3. optional LED mode (one UAC prompt; skipped if already set up) ---
schtasks /Query /TN "ClaudeCapsBlink" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    $ans = 'n'
    try { $ans = Read-Host 'Enable LED-only mode? Blinks just the light, never your caps state; needs one UAC approval [Y/n]' } catch {}
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'setup-led-mode.ps1')
    }
}

# --- 4. start the tray app if it is not already running ---
$running = $false
try { $m = [System.Threading.Mutex]::OpenExisting('ClaudeCapsBlinker'); $m.Dispose(); $running = $true }
catch [System.UnauthorizedAccessException] { $running = $true }
catch {}
if (-not $running) {
    schtasks /Run /TN "ClaudeCapsBlink" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Start-Process -WindowStyle Hidden powershell.exe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', (Join-Path $dir 'blinker.ps1'))
    }
}

Write-Host ''
Write-Host 'Done. Restart Claude Code sessions (or run /hooks in them) to activate.'
Write-Host 'Look for the gray dot behind the taskbar ^ chevron; right-click it for options.'
