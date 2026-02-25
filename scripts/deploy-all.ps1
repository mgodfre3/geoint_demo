<#
.SYNOPSIS
    Master deployment script for GEOINT Demo on Azure Local.

.DESCRIPTION
    Deploys infrastructure (VMs + AKS), pushes containers to ACR,
    configures Flux GitOps, and seeds sample data.

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER AcrName
    Azure Container Registry name.

.PARAMETER CustomLocationId
    Azure Local custom location resource ID.

.PARAMETER LogicalNetworkId
    Azure Local logical network resource ID.
#>

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AcrName,
    [Parameter(Mandatory)][string]$CustomLocationId,
    [Parameter(Mandatory)][string]$LogicalNetworkId,
    [string]$Location = "eastus",
    [string]$SshKeyPath = "$env:USERPROFILE\.ssh\id_rsa.pub"
)

$ErrorActionPreference = "Stop"

Write-Host "=== GEOINT Demo Deployment ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroup"
Write-Host "ACR: $AcrName"
Write-Host ""

# Step 1: Create resource group
Write-Host "[1/5] Creating resource group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

# Step 2: Deploy infrastructure via Bicep
Write-Host "[2/5] Deploying infrastructure (VMs + AKS)..." -ForegroundColor Yellow
$sshKey = Get-Content $SshKeyPath -Raw
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file infra/bicep/main.bicep `
    --parameters customLocationId=$CustomLocationId `
                 logicalNetworkId=$LogicalNetworkId `
                 sshPublicKey="$sshKey" `
    --output none

# Step 3: Push container images to ACR
Write-Host "[3/5] Building and pushing container images..." -ForegroundColor Yellow
& "$PSScriptRoot\setup-acr.ps1" -AcrName $AcrName

# Step 4: Configure Flux GitOps
Write-Host "[4/5] Configuring Flux GitOps..." -ForegroundColor Yellow
az k8s-configuration flux create `
    --resource-group $ResourceGroup `
    --cluster-name "geoint-aks" `
    --cluster-type connectedClusters `
    --name geoint-flux `
    --namespace flux-system `
    --scope cluster `
    --url "https://github.com/$env:GITHUB_ORG/geoint_demo" `
    --branch main `
    --kustomization name=demos path=./infra/flux `
    --output none

# Step 5: Seed sample data
Write-Host "[5/5] Seeding sample data..." -ForegroundColor Yellow
& "$PSScriptRoot\seed-data.ps1"

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "Demo 1 (Vision Pipeline): http://<node1-ip>:30081"
Write-Host "Demo 2 (Geo Platform):    http://<geoserver-vm-ip>:8083"
Write-Host "Demo 3 (Tactical Globe):  http://<globe-vm-ip>:8085"
Write-Host "Demo 4 (AI Assistant):    http://<node2-ip>:30086"
