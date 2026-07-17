# One-time setup for LED mode: registers the ClaudeCapsBlink scheduled task,
# which runs blinker.ps1 elevated (highest privileges) at logon and on demand.
# Elevated, the blinker can drive the keyboard LED directly and never touches
# the real Caps Lock state. Self-elevates via UAC when run without admin.

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    exit
}

$baseDir = Join-Path $env:LOCALAPPDATA 'claude-caps-blink'
$pause = Join-Path $baseDir 'pause'
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null

# Suspend blinking so killing the running instance cannot strand Caps Lock
# mid-pulse, then stop it (the elevated task instance replaces it).
New-Item -ItemType File -Force -Path $pause | Out-Null
Start-Sleep -Milliseconds 800
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'blinker\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue }

$scriptPath = Join-Path $PSScriptRoot 'blinker.ps1'
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $scriptPath"
schtasks /Create /TN "ClaudeCapsBlink" /TR $tr /SC ONLOGON /RL HIGHEST /F | Out-Null

Remove-Item -Force $pause -ErrorAction SilentlyContinue
schtasks /Run /TN "ClaudeCapsBlink" | Out-Null
