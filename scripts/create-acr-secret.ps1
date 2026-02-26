<#
.SYNOPSIS
    Create ACR pull secrets in GEOINT demo namespaces.
    Requires kubectl access (run az connectedk8s proxy first).

.PARAMETER AcrName
    Azure Container Registry name.
#>

param(
    [Parameter(Mandatory)][string]$AcrName
)

$ErrorActionPreference = "Stop"

# Enable admin and get credentials
az acr update --name $AcrName --admin-enabled true --output none
$creds = az acr credential show --name $AcrName -o json | ConvertFrom-Json
$server = "$AcrName.azurecr.io"
$username = $creds.username
$password = $creds.passwords[0].value

foreach ($ns in @("geoint-vision", "geoint-assistant")) {
    # Ensure namespace exists
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - 2>$null

    # Create or update the pull secret
    kubectl create secret docker-registry acr-secret `
        --docker-server=$server `
        --docker-username=$username `
        --docker-password=$password `
        -n $ns `
        --dry-run=client -o yaml | kubectl apply -f -

    Write-Host "[OK] ACR pull secret created in namespace '$ns'" -ForegroundColor Green
}

Write-Host ""
Write-Host "Restart deployments to pick up the new secret:" -ForegroundColor Yellow
Write-Host "  kubectl rollout restart deployment -n geoint-vision"
Write-Host "  kubectl rollout restart deployment -n geoint-assistant"
