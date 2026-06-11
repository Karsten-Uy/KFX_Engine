# install_shortcut.ps1 - add a "KFX Engine GUI" entry to the Start Menu that
# launches the repo's GUI with no console window. Per-user, no admin needed.
# Safe to re-run (it overwrites the shortcut). The shortcut points back at this
# repo, so editing gui.py / git pull updates the app on the next launch.
#
# Run once:
#   powershell -ExecutionPolicy Bypass -File install_shortcut.ps1

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$vbs  = Join-Path $here 'launch_kfx_gui.vbs'
$ico  = Join-Path $here 'logo.ico'

if (-not (Test-Path $vbs)) {
    throw "launch_kfx_gui.vbs not found next to this script ($vbs)."
}

# Make sure the venv/deps exist so the launcher's fast pythonw path works.
# A missing 'uv' is only a warning - the launcher falls back to 'uv run'.
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    Write-Host "Syncing Python environment with uv..."
    Push-Location $here
    try { uv sync } catch { Write-Warning "uv sync failed: $_" }
    Pop-Location
} else {
    Write-Warning "uv not found on PATH - skipping 'uv sync'. Install uv or run 'uv sync' in $here."
}

# Create the Start Menu shortcut. Target wscript.exe explicitly so it always
# launches hidden (no console) regardless of .vbs file associations.
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnk = Join-Path $startMenu 'KFX Engine GUI.lnk'

$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($lnk)
$sc.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments        = '"' + $vbs + '"'
$sc.WorkingDirectory = $here
$sc.Description       = 'KFX Engine GUI'
if (Test-Path $ico) { $sc.IconLocation = "$ico,0" }
$sc.Save()

Write-Host ""
Write-Host "Created Start Menu shortcut:"
Write-Host "  $lnk"
Write-Host ""
Write-Host "Open Start and search 'KFX Engine GUI'. Right-click it ->"
Write-Host "'Pin to Start' (tile) or 'Pin to taskbar' to pin it."
