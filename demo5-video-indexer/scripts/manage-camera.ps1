<#
.SYNOPSIS
    Manage cameras for Video Indexer real-time analysis.

.DESCRIPTION
    Wrapper around the vi_cli.sh script for adding, removing, and listing cameras.

.PARAMETER Action
    Action to perform: add, remove, list, show

.PARAMETER EnvFile
    Path to environment config file.

.EXAMPLE
    .\demo5-video-indexer\scripts\manage-camera.ps1 -Action add -EnvFile .env
    .\demo5-video-indexer\scripts\manage-camera.ps1 -Action list -EnvFile .env
    .\demo5-video-indexer\scripts\manage-camera.ps1 -Action remove -EnvFile .env
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("add", "remove", "list", "show")]
    [string]$Action,

    [string]$EnvFile = "$PSScriptRoot\\..\\..\\.env"
)

$ErrorActionPreference = "Stop"

# --- Load env file ---
if (-not (Test-Path $EnvFile)) {
    Write-Host "ERROR: Environment file not found: $EnvFile" -ForegroundColor Red
    exit 1
}

$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2 -and $parts[1]) {
            $envVars[$parts[0]] = $parts[1].Trim('"', "'", ' ')
        }
    }
}

$ClusterName          = $envVars['AKS_CLUSTER_NAME']
$ClusterResourceGroup = $envVars['AZURE_RESOURCE_GROUP']
$ViAccountName        = $envVars['VI_ACCOUNT_NAME']
$ViAccountRg          = $envVars['VI_ACCOUNT_RESOURCE_GROUP']
$CameraName           = $envVars['CAMERA_NAME']
$CameraRtspUrl        = $envVars['CAMERA_RTSP_URL']

# Default camera name
if (-not $CameraName) { $CameraName = "geoint-booth-cam" }

# --- Download vi_cli.sh if not present ---
$cliPath = "$PSScriptRoot\vi_cli.sh"
if (-not (Test-Path $cliPath)) {
    Write-Host "Downloading vi_cli.sh..." -ForegroundColor Gray
    $cliUrl = "https://raw.githubusercontent.com/Azure-Samples/azure-video-indexer-samples/refs/heads/live-private-preview/VideoIndexerEnabledByArc/live/vi_cli.sh"
    Invoke-WebRequest -Uri $cliUrl -OutFile $cliPath
    Write-Host "  Downloaded: $cliPath" -ForegroundColor Green
}

# --- Execute action ---
Write-Host ""
Write-Host "=== Camera Management: $Action ===" -ForegroundColor Cyan

switch ($Action) {
    "add" {
        if (-not $CameraRtspUrl) {
            Write-Host "ERROR: CAMERA_RTSP_URL not set in $EnvFile" -ForegroundColor Red
            exit 1
        }
        Write-Host "Adding camera '$CameraName'..."
        Write-Host "  RTSP URL: $CameraRtspUrl"
        Write-Host "  Cluster:  $ClusterName ($ClusterResourceGroup)"
        Write-Host ""

        # Use WSL or bash if available, otherwise show the command
        $bashExists = Get-Command bash -ErrorAction SilentlyContinue
        if ($bashExists) {
            bash $cliPath add camera `
                --clusterName $ClusterName `
                --clusterResourceGroup $ClusterResourceGroup `
                --accountName $ViAccountName `
                --accountResourceGroup $ViAccountRg `
                --cameraName $CameraName `
                --cameraAddress $CameraRtspUrl `
                --cameraStreamingEnabled true `
                --cameraRecordingEnabled true
        } else {
            Write-Host "[NOTE] bash not available. Run this in WSL or a Linux shell:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  ./vi_cli.sh add camera \\" -ForegroundColor White
            Write-Host "    --clusterName $ClusterName \\" -ForegroundColor White
            Write-Host "    --clusterResourceGroup $ClusterResourceGroup \\" -ForegroundColor White
            Write-Host "    --accountName $ViAccountName \\" -ForegroundColor White
            Write-Host "    --accountResourceGroup $ViAccountRg \\" -ForegroundColor White
            Write-Host "    --cameraName $CameraName \\" -ForegroundColor White
            Write-Host "    --cameraAddress \"$CameraRtspUrl\" \\" -ForegroundColor White
            Write-Host "    --cameraStreamingEnabled true \\" -ForegroundColor White
            Write-Host "    --cameraRecordingEnabled true" -ForegroundColor White
        }
    }

    "remove" {
        Write-Host "Removing camera '$CameraName'..."
        $bashExists = Get-Command bash -ErrorAction SilentlyContinue
        if ($bashExists) {
            bash $cliPath remove camera `
                --clusterName $ClusterName `
                --clusterResourceGroup $ClusterResourceGroup `
                --accountName $ViAccountName `
                --accountResourceGroup $ViAccountRg `
                --cameraName $CameraName
        } else {
            Write-Host "[NOTE] Run in WSL:" -ForegroundColor Yellow
            Write-Host "  ./vi_cli.sh remove camera --clusterName $ClusterName --clusterResourceGroup $ClusterResourceGroup --accountName $ViAccountName --accountResourceGroup $ViAccountRg --cameraName $CameraName"
        }
    }

    "list" {
        Write-Host "Listing cameras..."
        $bashExists = Get-Command bash -ErrorAction SilentlyContinue
        if ($bashExists) {
            bash $cliPath list cameras `
                --clusterName $ClusterName `
                --clusterResourceGroup $ClusterResourceGroup `
                --accountName $ViAccountName `
                --accountResourceGroup $ViAccountRg
        } else {
            Write-Host "[NOTE] Run in WSL:" -ForegroundColor Yellow
            Write-Host "  ./vi_cli.sh list cameras --clusterName $ClusterName --clusterResourceGroup $ClusterResourceGroup --accountName $ViAccountName --accountResourceGroup $ViAccountRg"
        }
    }

    "show" {
        Write-Host "Extension status:"
        $bashExists = Get-Command bash -ErrorAction SilentlyContinue
        if ($bashExists) {
            bash $cliPath show extension `
                --clusterName $ClusterName `
                --clusterResourceGroup $ClusterResourceGroup `
                --accountName $ViAccountName `
                --accountResourceGroup $ViAccountRg
        } else {
            Write-Host "[NOTE] Run in WSL:" -ForegroundColor Yellow
            Write-Host "  ./vi_cli.sh show extension --clusterName $ClusterName --clusterResourceGroup $ClusterResourceGroup --accountName $ViAccountName --accountResourceGroup $ViAccountRg"
        }
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
