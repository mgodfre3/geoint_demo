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

# These are full ARM resource IDs (may point to a different RG than the demo)
$CustomLocationId  = $envVars['AZURE_CUSTOM_LOCATION_ID']
$LogicalNetworkId  = $envVars['AZURE_LOGICAL_NETWORK_ID']
$GalleryImageId    = $envVars['AZURE_GALLERY_IMAGE_ID']

# Export the IDs so Bicep param file can read them
[Environment]::SetEnvironmentVariable('AZURE_CUSTOM_LOCATION_ID', $CustomLocationId, 'Process')
[Environment]::SetEnvironmentVariable('AZURE_LOGICAL_NETWORK_ID', $LogicalNetworkId, 'Process')
[Environment]::SetEnvironmentVariable('AZURE_GALLERY_IMAGE_ID', $GalleryImageId, 'Process')

$AcrName           = $envVars['ACR_NAME']
$ClusterName       = $envVars['AKS_CLUSTER_NAME']
$FluxRepoUrl       = $envVars['FLUX_REPO_URL']
$FluxBranch        = $envVars['FLUX_BRANCH']
$AdminPassword     = $envVars['VM_ADMIN_PASSWORD']

# Validate required vars
$required = @{
    'AZURE_SUBSCRIPTION_ID'        = $SubId
    'AZURE_RESOURCE_GROUP'         = $Rg
    'AZURE_CUSTOM_LOCATION_ID'     = $CustomLocationId
    'AZURE_LOGICAL_NETWORK_ID'     = $LogicalNetworkId
    'AZURE_GALLERY_IMAGE_ID'       = $GalleryImageId
    'ACR_NAME'                     = $AcrName
    'VM_ADMIN_PASSWORD'            = $AdminPassword
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

# Step 2: Deploy VMs via Azure CLI (Bicep types for Azure Local VMs are not stable)
Write-Host "[2/5] Deploying infrastructure (VMs)..." -ForegroundColor Yellow
    $GeoVmName  = $envVars['VM_GEOSERVER_NAME']
    $GlobeVmName = $envVars['VM_GLOBE_NAME']
    $AdminUser   = $envVars['VM_ADMIN_USERNAME']

    # Bootstrap script URL from the same repo Flux uses
    $repoRaw = $FluxRepoUrl -replace 'github\.com', 'raw.githubusercontent.com'
    $repoRaw = $repoRaw -replace '\.git$', ''
    $bootstrapUrl = "$repoRaw/$FluxBranch/scripts/bootstrap-vm.sh"

    $vmParams = @(
        @{ Name = $GeoVmName;   Role = "geoserver"; Desc = "GeoServer (Demo 2)" },
        @{ Name = $GlobeVmName; Role = "globe";     Desc = "CesiumJS Globe (Demo 3)" }
    )

    foreach ($vm in $vmParams) {
        $exists = az stack-hci-vm show --name $vm.Name --resource-group $ResourceGroup --query name -o tsv 2>$null
        if ($exists) {
            Write-Host "  [OK] VM '$($vm.Name)' already exists - $($vm.Desc)" -ForegroundColor Green
        } else {
            # Create NIC for the VM
            $nicName = "$($vm.Name)-nic"
            $nicExists = az stack-hci-vm network nic show --name $nicName --resource-group $ResourceGroup --query name -o tsv 2>$null
            if (-not $nicExists) {
                Write-Host "  Creating NIC: $nicName..." -ForegroundColor Gray
                az stack-hci-vm network nic create `
                    --name $nicName `
                    --resource-group $ResourceGroup `
                    --custom-location $CustomLocationId `
                    --subnet-id $LogicalNetworkId `
                    --output none
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  [WARN] NIC '$nicName' creation failed" -ForegroundColor Yellow
                    continue
                }
            }

            # Create the VM with password authentication
            Write-Host "  Creating VM: $($vm.Name) ($($vm.Desc))..." -ForegroundColor Gray
            az stack-hci-vm create `
                --name $vm.Name `
                --resource-group $ResourceGroup `
                --custom-location $CustomLocationId `
                --image $GalleryImageId `
                --admin-username $AdminUser `
                --admin-password $AdminPassword `
                --authentication-type password `
                --nics $nicName `
                --computer-name $vm.Name `
                --size Default `
                --os-type linux `
                --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [WARN] VM '$($vm.Name)' deployment may have failed - check Azure Portal" -ForegroundColor Yellow
            } else {
                Write-Host "  [OK] VM '$($vm.Name)' created" -ForegroundColor Green
            }
        }

        # Install Custom Script Extension to bootstrap Docker + demo services
        $extExists = az connectedmachine extension show `
            --name "BootstrapDocker" `
            --machine-name $vm.Name `
            --resource-group $ResourceGroup `
            --query name -o tsv 2>$null
        if (-not $extExists) {
            Write-Host "  Installing bootstrap extension on '$($vm.Name)'..." -ForegroundColor Gray
            $scriptCmd = "curl -fsSL $bootstrapUrl | bash -s $($vm.Role) $FluxRepoUrl $FluxBranch"
            $settingsJson = @{ commandToExecute = $scriptCmd } | ConvertTo-Json -Compress
            $settingsFile = "$env:TEMP\cse-settings-$($vm.Name).json"
            $settingsJson | Out-File -FilePath $settingsFile -Encoding utf8
            az connectedmachine extension create `
                --name "BootstrapDocker" `
                --machine-name $vm.Name `
                --resource-group $ResourceGroup `
                --location $Location `
                --type "CustomScript" `
                --publisher "Microsoft.Azure.Extensions" `
                --type-handler-version "2.1" `
                --settings "@$settingsFile" `
                --no-wait `
                --output none
            Remove-Item $settingsFile -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [WARN] Bootstrap extension on '$($vm.Name)' may have failed" -ForegroundColor Yellow
            } else {
                Write-Host "  [OK] Bootstrap extension queued on '$($vm.Name)'" -ForegroundColor Green
            }
        } else {
            Write-Host "  [OK] Bootstrap extension already installed on '$($vm.Name)'" -ForegroundColor Green
        }
    }

# Step 3: Create ACR if needed, then build container images
Write-Host "[3/5] Building container images via ACR Tasks..." -ForegroundColor Yellow
$acrExists = az acr show --name $AcrName --query name -o tsv 2>$null
if (-not $acrExists) {
    Write-Host "  Creating ACR: $AcrName..." -ForegroundColor Gray
    az acr create --resource-group $ResourceGroup --name $AcrName --sku Standard --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN] Failed to create ACR" -ForegroundColor Yellow }
}
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

    # Create ACR pull secret — requires kubectl access to the cluster
    # Run this after connecting: az connectedk8s proxy -n <cluster> -g <rg>
    Write-Host "  [NOTE] Create ACR pull secrets manually after connecting to the cluster:" -ForegroundColor Gray
    Write-Host "         az connectedk8s proxy -n $ClusterName -g $ResourceGroup" -ForegroundColor Gray
    Write-Host "         Then run: .\scripts\create-acr-secret.ps1 -AcrName $AcrName" -ForegroundColor Gray
} else {
    Write-Host "  [SKIP] AKS cluster '$ClusterName' not found - create it first, then re-run" -ForegroundColor Yellow
    Write-Host "         az aksarc create -n $ClusterName -g $ResourceGroup --custom-location $CustomLocationId --vnet-ids $LogicalNetworkId" -ForegroundColor Gray
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
