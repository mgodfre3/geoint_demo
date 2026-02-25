<#
.SYNOPSIS
    Build and push GEOINT demo container images to Azure Container Registry.

.PARAMETER AcrName
    Azure Container Registry name.
#>

param(
    [Parameter(Mandatory)][string]$AcrName
)

$ErrorActionPreference = "Stop"

Write-Host "Logging into ACR: $AcrName..." -ForegroundColor Yellow
az acr login --name $AcrName

$images = @(
    @{ Name = "geoint/vision-api"; Context = "demo1-vision-pipeline"; Dockerfile = "Dockerfile" },
    @{ Name = "geoint/chat-api"; Context = "demo4-analyst-assistant"; Dockerfile = "Dockerfile" }
)

foreach ($img in $images) {
    $tag = "$AcrName.azurecr.io/$($img.Name):latest"
    Write-Host "Building $tag..." -ForegroundColor Yellow
    docker build -t $tag -f "$($img.Context)\$($img.Dockerfile)" "$($img.Context)"
    Write-Host "Pushing $tag..." -ForegroundColor Yellow
    docker push $tag
}

Write-Host "All images pushed to ACR." -ForegroundColor Green
