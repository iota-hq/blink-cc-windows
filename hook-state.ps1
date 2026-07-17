# Claude Code hook: record this session's state for the caps-lock blinker.
# Receives hook JSON on stdin. Usage: hook-state.ps1 -State <state> [-Launch]
#   working   - Claude is working (UserPromptSubmit creates the flag; PostToolUse
#               only updates an existing one, so it cannot resurrect a finished session)
#   attention - needs the user (permission prompt, stop failure)
#   done      - turn finished; tray app plays the done flash and removes the flag
#   end       - session closed; remove the flag immediately
# -Launch also starts the tray app if it is not running and not user-disabled.

param(
    [Parameter(Mandatory)][ValidateSet('working', 'attention', 'done', 'end')]
    [string]$State,
    [switch]$Launch
)

$ErrorActionPreference = 'SilentlyContinue'

$baseDir  = Join-Path $env:LOCALAPPDATA 'claude-caps-blink'
$flagDir  = Join-Path $baseDir 'flags'
$disabled = Join-Path $baseDir 'disabled'
New-Item -ItemType Directory -Force -Path $flagDir | Out-Null

$sid = $null
try { $sid = ([Console]::In.ReadToEnd() | ConvertFrom-Json).session_id } catch {}
if (-not $sid) { $sid = 'unknown' }
$file = Join-Path $flagDir "$sid.flag"

switch ($State) {
    'end'  { Remove-Item -Force $file }
    'done' { Set-Content -Path $file -Value 'done' }
    'attention' {
        # Only while a turn is in progress: the idle "waiting for your input"
        # notification fires after a turn ends and must not re-arm the light
        if ((Test-Path $file) -and ((Get-Content $file -TotalCount 1) -ne 'done')) {
            Set-Content -Path $file -Value 'attention'
        }
    }
    'working' {
        if ($Launch) { Set-Content -Path $file -Value 'working' }
        elseif ((Test-Path $file) -and ((Get-Content $file -TotalCount 1) -ne 'done')) {
            Set-Content -Path $file -Value 'working'
        }
    }
}

if ($Launch) {
    Get-ChildItem $flagDir -Filter '*.flag' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-2) } |
        Remove-Item -Force

    if (-not (Test-Path $disabled)) {
        $running = $false
        try {
            $m = [System.Threading.Mutex]::OpenExisting('ClaudeCapsBlinker')
            $m.Dispose()
            $running = $true
        } catch {}
        if (-not $running) {
            # Prefer the scheduled task: it runs the blinker elevated (LED mode)
            schtasks /Run /TN "ClaudeCapsBlink" 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Start-Process -WindowStyle Hidden powershell.exe -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', "$PSScriptRoot\blinker.ps1"
                )
            }
        }
    }
}
