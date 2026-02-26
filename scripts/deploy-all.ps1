<#
.SYNOPSIS
    Master deployment script for GEOINT Demo on Azure Local.

.DESCRIPTION
    Deploys infrastructure (VMs + AKS), pushes containers to ACR,
    configures Flux GitOps, and seeds sample data.
    All cluster-specific config is loaded from an env file.

.PARAMETER EnvFile
    Path to environment config file (default: .env in repo root).
    Copy .env.template and fill in your cluster values.

.EXAMPLE
    .\scripts\deploy-all.ps1
    .\scripts\deploy-all.ps1 -EnvFile .env.geoint2026
#>

param(
    [string]$EnvFile = "$PSScriptRoot\..\.env"
)

$ErrorActionPreference = "Continue"

# --- Load environment file ---
if (-not (Test-Path $EnvFile)) {
    Write-Host "ERROR: Environment file not found: $EnvFile" -ForegroundColor Red
    Write-Host "Copy .env.template to .env and fill in your cluster values." -ForegroundColor Yellow
    exit 1
}

Write-Host "Loading config from: $EnvFile" -ForegroundColor Gray
$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2 -and $parts[1]) {
            $val = $parts[1].Trim('"', "'", ' ')
            $envVars[$parts[0]] = $val
            [Environment]::SetEnvironmentVariable($parts[0], $val, 'Process')
        }
    }
}

# --- Resolve required variables ---
$ResourceGroup     = $envVars['AZURE_RESOURCE_GROUP']
$Location          = $envVars['AZURE_LOCATION']
$SubscriptionId    = $envVars['AZURE_SUBSCRIPTION_ID']
# --- Build full ARM resource IDs from subscription + RG + name ---
$SubId = $envVars['AZURE_SUBSCRIPTION_ID']
$Rg    = $envVars['AZURE_RESOURCE_GROUP']

$CustomLocationName = $envVars['AZURE_CUSTOM_LOCATION_NAME']
$LogicalNetworkName = $envVars['AZURE_LOGICAL_NETWORK_NAME']

$CustomLocationId  = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.ExtendedLocation/customLocations/$CustomLocationName"
$LogicalNetworkId  = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.AzureStackHCI/logicalNetworks/$LogicalNetworkName"

# Gallery image is a full resource ID (may be in a different RG)
$GalleryImageId    = $envVars['AZURE_GALLERY_IMAGE_ID']

# Export the computed IDs so Bicep param file can read them
[Environment]::SetEnvironmentVariable('AZURE_CUSTOM_LOCATION_ID', $CustomLocationId, 'Process')
[Environment]::SetEnvironmentVariable('AZURE_LOGICAL_NETWORK_ID', $LogicalNetworkId, 'Process')
[Environment]::SetEnvironmentVariable('AZURE_GALLERY_IMAGE_ID', $GalleryImageId, 'Process')

$AcrName           = $envVars['ACR_NAME']
$ClusterName       = $envVars['AKS_CLUSTER_NAME']
$FluxRepoUrl       = $envVars['FLUX_REPO_URL']
$FluxBranch        = $envVars['FLUX_BRANCH']
$SshKeyPath        = $envVars['VM_SSH_KEY_PATH']

# Expand ~ in SSH key path
if ($SshKeyPath -and $SshKeyPath.StartsWith('~')) {
    $SshKeyPath = $SshKeyPath.Replace('~', $env:USERPROFILE)
}

# Validate required vars
$required = @{
    'AZURE_SUBSCRIPTION_ID'        = $SubId
    'AZURE_RESOURCE_GROUP'         = $Rg
    'AZURE_CUSTOM_LOCATION_NAME'   = $CustomLocationName
    'AZURE_LOGICAL_NETWORK_NAME'   = $LogicalNetworkName
    'AZURE_GALLERY_IMAGE_ID'       = $GalleryImageId
    'ACR_NAME'                     = $AcrName
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value -or $_.Value -match '<.+>' }
if ($missing) {
    Write-Host "ERROR: Missing or placeholder values in $EnvFile`:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $($_.Key)" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "=== GEOINT Demo Deployment ===" -ForegroundColor Cyan
Write-Host "  Env File:       $EnvFile"
Write-Host "  Resource Group: $ResourceGroup"
Write-Host "  Location:       $Location"
Write-Host "  ACR:            $AcrName"
Write-Host "  AKS Cluster:    $ClusterName"
Write-Host "  Custom Location: $CustomLocationId"
Write-Host ""

# Set subscription if provided
if ($SubId) {
    az account set --subscription $SubId
}

# Step 1: Create resource group
Write-Host "[1/5] Creating resource group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] Resource group may already exist" -ForegroundColor Yellow }

# Step 2: Deploy infrastructure via Bicep
Write-Host "[2/5] Deploying infrastructure (VMs)..." -ForegroundColor Yellow
if (Test-Path $SshKeyPath) {
    $sshKey = Get-Content $SshKeyPath -Raw
    az deployment group create `
        --resource-group $ResourceGroup `
        --template-file infra/bicep/main.bicep `
        --parameters infra/bicep/main.bicepparam `
        --parameters sshPublicKey="$sshKey" `
        --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] Bicep deployment had errors - check Azure Portal" -ForegroundColor Yellow }
} else {
    Write-Host "  [SKIP] SSH key not found at $SshKeyPath - skipping VM deployment" -ForegroundColor Yellow
}

# Step 3: Push container images to ACR
Write-Host "[3/5] Building container images via ACR Tasks..." -ForegroundColor Yellow
& "$PSScriptRoot\setup-acr.ps1" -AcrName $AcrName

# Step 4: Configure Flux GitOps (requires AKS cluster to exist)
Write-Host "[4/5] Configuring Flux GitOps..." -ForegroundColor Yellow
$aksExists = az connectedk8s show --name $ClusterName --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($aksExists) {
    az k8s-configuration flux create `
        --resource-group $ResourceGroup `
        --cluster-name $ClusterName `
        --cluster-type connectedClusters `
        --name geoint-flux `
        --namespace flux-system `
        --scope cluster `
        --url $FluxRepoUrl `
        --branch $FluxBranch `
        --kustomization name=demos path=./infra/flux `
        --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] Flux configuration had errors" -ForegroundColor Yellow }
} else {
    Write-Host "  [SKIP] AKS cluster '$ClusterName' not found - create it first, then re-run" -ForegroundColor Yellow
    Write-Host "         az aksarc create -n $ClusterName -g $ResourceGroup --custom-location $($envVars['AZURE_CUSTOM_LOCATION_NAME']) --vnet-ids $LogicalNetworkId" -ForegroundColor Gray
}

# Step 5: Seed sample data (only if services are running)
Write-Host "[5/5] Verifying services..." -ForegroundColor Yellow
& "$PSScriptRoot\seed-data.ps1"

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "Demo 1 (Vision Pipeline): http://$($envVars['NODE1_IP']):30081"
Write-Host "Demo 2 (Geo Platform):    http://$($envVars['VM_GEOSERVER_IP']):8083"
Write-Host "Demo 3 (Tactical Globe):  http://$($envVars['VM_GLOBE_IP']):8085"
Write-Host "Demo 4 (AI Assistant):    http://$($envVars['NODE2_IP']):30086"
Write-Host ""
Write-Host "Kiosk Launcher:           scripts\kiosk-launcher.html"
