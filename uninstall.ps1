# claude-caps-blink uninstaller.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
# Removes the hooks (leaving all other settings intact), the scheduled task
# (one UAC prompt if it exists), the tray app, and the data directory.

$ErrorActionPreference = 'SilentlyContinue'

# --- remove our hooks from settings, preserve everything else ---
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($settings -and $settings.PSObject.Properties['hooks']) {
        $hooks = $settings.hooks
        foreach ($name in @($hooks.PSObject.Properties.Name)) {
            $kept = @($hooks.$name) | Where-Object {
                -not (@($_.hooks) | Where-Object {
                    ($_.command -match 'hook-state') -or ((@($_.args) -join ' ') -match 'hook-state')
                })
            }
            if (@($kept).Count -eq 0) { $hooks.PSObject.Properties.Remove($name) }
            else { $hooks.$name = @($kept) }
        }
        if (@($hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
        [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 12))
        Write-Host "Hooks removed from $settingsPath"
    }
}

# --- stop the app safely (pause marker prevents a mid-pulse kill) ---
$baseDir = Join-Path $env:LOCALAPPDATA 'claude-caps-blink'
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $baseDir 'pause') | Out-Null
Start-Sleep -Milliseconds 800

schtasks /Query /TN "ClaudeCapsBlink" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    # Elevated in one shot: end the running (elevated) instance and delete the task
    Start-Process -Verb RunAs -Wait cmd.exe -ArgumentList '/c', 'schtasks /End /TN ClaudeCapsBlink & schtasks /Delete /TN ClaudeCapsBlink /F'
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'blinker\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -Confirm:$false }

Remove-Item -Recurse -Force $baseDir
Write-Host 'claude-caps-blink uninstalled. You can delete this folder now.'
