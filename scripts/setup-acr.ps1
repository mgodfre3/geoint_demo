<#
.SYNOPSIS
    Build and push GEOINT demo container images to Azure Container Registry.
    Uses 'az acr build' for cloud-side builds (no local Docker required).

.PARAMETER AcrName
    Azure Container Registry name.
#>

param(
    [Parameter(Mandatory)][string]$AcrName
)

$ErrorActionPreference = "Stop"

$images = @(
    @{ Name = "geoint/vision-api"; Context = "demo1-vision-pipeline"; Dockerfile = "Dockerfile" },
    @{ Name = "geoint/yolov8-satellite"; Context = "demo1-vision-pipeline"; Dockerfile = "Dockerfile.yolo" },
    @{ Name = "geoint/vision-ui"; Context = "demo1-vision-pipeline/frontend"; Dockerfile = "Dockerfile" },
    @{ Name = "geoint/chat-api"; Context = "demo4-analyst-assistant"; Dockerfile = "Dockerfile" }
)

foreach ($img in $images) {
    $tag = "$AcrName.azurecr.io/$($img.Name):latest"
    Write-Host "Building $tag via ACR Tasks..." -ForegroundColor Yellow
    az acr build `
        --registry $AcrName `
        --image "$($img.Name):latest" `
        --file "$($img.Context)\$($img.Dockerfile)" `
        "$($img.Context)" `
        --no-logs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] Failed to build $tag - skipping" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] $tag" -ForegroundColor Green
    }
}

Write-Host "ACR image builds complete." -ForegroundColor Green
