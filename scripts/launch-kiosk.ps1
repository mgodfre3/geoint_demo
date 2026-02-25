<#
.SYNOPSIS
    Opens the GEOINT kiosk launcher page in full-screen kiosk mode.

.DESCRIPTION
    Launches Microsoft Edge (or Google Chrome) in kiosk mode pointing at the
    launcher HTML page. Run this on the demo machine connected to the
    presentation display.

    Prerequisites:
      - Microsoft Edge or Google Chrome installed
      - Demo services running on expected ports (5001-5004)
      - The kiosk-launcher.html file in the same directory as this script

.EXAMPLE
    .\launch-kiosk.ps1
    .\launch-kiosk.ps1 -Browser Chrome
    .\launch-kiosk.ps1 -Url "http://localhost:5002"
#>

param(
    [ValidateSet('Edge', 'Chrome')]
    [string]$Browser = 'Edge',

    [string]$Url
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$launcherPath = Join-Path $scriptDir 'kiosk-launcher.html'

if (-not $Url) {
    if (-not (Test-Path $launcherPath)) {
        Write-Error "Launcher page not found at $launcherPath"
        exit 1
    }
    $Url = "file:///$($launcherPath -replace '\\','/')"
}

$edgePath  = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$chromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'

switch ($Browser) {
    'Edge' {
        if (Test-Path $edgePath) {
            Write-Host "Launching Edge in kiosk mode → $Url"
            Start-Process $edgePath "--kiosk `"$Url`" --edge-kiosk-type=fullscreen --no-first-run"
        } else {
            Write-Warning "Edge not found at $edgePath — falling back to Chrome"
            $Browser = 'Chrome'
        }
    }
}

if ($Browser -eq 'Chrome') {
    if (Test-Path $chromePath) {
        Write-Host "Launching Chrome in kiosk mode → $Url"
        Start-Process $chromePath "--kiosk `"$Url`" --no-first-run"
    } else {
        Write-Error "Neither Edge nor Chrome found. Install one and retry."
        exit 1
    }
}
