<#
.SYNOPSIS
    Refresh the VI access token for the booth-analytics pod on den-vi cluster.
    Run this before demos or set up as a scheduled task (every 45 min).
.NOTES
    Requires: az CLI logged in, kubectl context set to den-vi
#>
param(
    [string]$AccountName = "AC-VI",
    [string]$ResourceGroup = "AdaptiveCloud-VideoIndexer",
    [string]$Namespace = "geoint-booth",
    [string]$SecretName = "vi-token"
)

$ErrorActionPreference = "Stop"

Write-Host "Generating VI access token..." -ForegroundColor Yellow
$bodyFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $bodyFile -Value '{"permissionType":"Contributor","scope":"Account"}'

$result = az rest --method post `
    --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroup/providers/Microsoft.VideoIndexer/accounts/$AccountName/generateAccessToken?api-version=2025-01-01" `
    --body "@$bodyFile" `
    --headers "Content-Type=application/json" 2>&1

Remove-Item $bodyFile -ErrorAction SilentlyContinue

$token = ($result | ConvertFrom-Json).accessToken
if (-not $token) {
    Write-Error "Failed to generate token: $result"
    exit 1
}

Write-Host "Token generated (expires in ~65 min). Updating K8s secret..." -ForegroundColor Yellow
kubectl create secret generic $SecretName `
    --from-literal=token=$token `
    -n $Namespace --dry-run=client -o yaml | kubectl apply -f -

Write-Host "Restarting booth-analytics pod..." -ForegroundColor Yellow
kubectl rollout restart deployment/booth-analytics -n $Namespace
kubectl rollout status deployment/booth-analytics -n $Namespace --timeout=60s

Write-Host "Done! Booth page should connect within ~10 seconds." -ForegroundColor Green
