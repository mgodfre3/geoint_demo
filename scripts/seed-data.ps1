<#
.SYNOPSIS
    Seed sample geospatial data into the GEOINT demo environment.

.DESCRIPTION
    Loads sample satellite imagery tiles, vector features, and
    GEOINT reports into the running demo services.
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Seeding GEOINT Demo Data ===" -ForegroundColor Cyan

# Seed GEOINT reports into Demo 4 vector store
Write-Host "[1/2] Ingesting GEOINT reports into vector store..." -ForegroundColor Yellow
Push-Location demo4-analyst-assistant
python backend/ingest.py
Pop-Location

# Verify services
Write-Host "[2/2] Verifying demo services..." -ForegroundColor Yellow

$services = @(
    @{ Name = "Vision Pipeline API"; Url = "http://localhost:8082/health" },
    @{ Name = "GeoServer"; Url = "http://localhost:8084/geoserver/web/" },
    @{ Name = "Tactical Globe"; Url = "http://localhost:8085/api/health" },
    @{ Name = "Analyst Assistant"; Url = "http://localhost:8087/health" }
)

foreach ($svc in $services) {
    try {
        $response = Invoke-WebRequest -Uri $svc.Url -TimeoutSec 5 -ErrorAction Stop
        Write-Host "  ✓ $($svc.Name) — OK" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ $($svc.Name) — Not reachable ($($svc.Url))" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Data Seeding Complete ===" -ForegroundColor Green
