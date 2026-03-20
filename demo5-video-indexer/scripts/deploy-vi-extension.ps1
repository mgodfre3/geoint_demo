<#
.SYNOPSIS
    Deploy Azure AI Video Indexer Arc Extension for real-time analysis.

.DESCRIPTION
    Creates the Video Indexer Arc extension on an existing Arc-enabled AKS cluster.
    Configures live streaming, GPU support, and RWX storage.

.PARAMETER EnvFile
    Path to environment config file (default: .env in repo root).

.EXAMPLE
    .\demo5-video-indexer\scripts\deploy-vi-extension.ps1
    .\demo5-video-indexer\scripts\deploy-vi-extension.ps1 -EnvFile .env.mobile
#>

param(
    [string]$EnvFile = "$PSScriptRoot\\..\\..\\.env"
)

$ErrorActionPreference = "Stop"

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
        }
    }
}

# --- Resolve variables ---
$SubscriptionId       = $envVars['AZURE_SUBSCRIPTION_ID']
$ClusterName          = $envVars['AKS_CLUSTER_NAME']
$ClusterResourceGroup = $envVars['AZURE_RESOURCE_GROUP']
$ViAccountId          = $envVars['VI_ACCOUNT_ID']
$ViExtensionName      = $envVars['VI_EXTENSION_NAME']
$ViEndpointUri        = $envVars['VI_ENDPOINT_URI']
$ViStorageClass       = $envVars['VI_STORAGE_CLASS']
$ViGpuTolerationKey   = $envVars['VI_GPU_TOLERATION_KEY']
$ViExtensionVersion   = $envVars['VI_EXTENSION_VERSION']

# Defaults
if (-not $ViExtensionName)    { $ViExtensionName    = "vi-live" }
if (-not $ViStorageClass)     { $ViStorageClass      = "longhorn" }
if (-not $ViGpuTolerationKey) { $ViGpuTolerationKey  = "nvidia.com/gpu" }
if (-not $ViExtensionVersion) { $ViExtensionVersion  = "1.2.53" }

# Validate required vars
$required = @{
    'AZURE_SUBSCRIPTION_ID' = $SubscriptionId
    'AKS_CLUSTER_NAME'      = $ClusterName
    'AZURE_RESOURCE_GROUP'  = $ClusterResourceGroup
    'VI_ACCOUNT_ID'         = $ViAccountId
    'VI_ENDPOINT_URI'       = $ViEndpointUri
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value }
if ($missing) {
    Write-Host "ERROR: Missing required variables in $EnvFile:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $($_.Key)" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "=== Deploy Video Indexer Arc Extension ===" -ForegroundColor Cyan
Write-Host "  Cluster:        $ClusterName"
Write-Host "  Resource Group: $ClusterResourceGroup"
Write-Host "  VI Account ID:  $ViAccountId"
Write-Host "  Extension Name: $ViExtensionName"
Write-Host "  Endpoint URI:   $ViEndpointUri"
Write-Host "  Storage Class:  $ViStorageClass"
Write-Host "  GPU Toleration: $ViGpuTolerationKey"
Write-Host "  Version:        $ViExtensionVersion"
Write-Host ""

# Set subscription
az account set --subscription $SubscriptionId

# Check if extension already exists
Write-Host "[1/3] Checking for existing VI extension..." -ForegroundColor Yellow
$existing = az k8s-extension show `
    --name $ViExtensionName `
    --cluster-name $ClusterName `
    --resource-group $ClusterResourceGroup `
    --cluster-type connectedClusters `
    --query name -o tsv 2>$null

if ($existing) {
    Write-Host "  [OK] Extension '$ViExtensionName' already exists" -ForegroundColor Green
    Write-Host "  To update, use: az k8s-extension update ..." -ForegroundColor Gray

    $update = Read-Host "  Update extension? (y/N)"
    if ($update -eq 'y') {
        Write-Host "[2/3] Updating VI extension..." -ForegroundColor Yellow
        az k8s-extension update `
            --name $ViExtensionName `
            --extension-type "Microsoft.videoIndexer" `
            --scope cluster `
            --release-namespace "video-indexer" `
            --cluster-name $ClusterName `
            --resource-group $ClusterResourceGroup `
            --cluster-type "connectedClusters" `
            --version $ViExtensionVersion `
            --release-train "preview" `
            --config "videoIndexer.endpointUri=$ViEndpointUri"
    }
} else {
    # Register required providers
    Write-Host "[1/3] Registering Azure resource providers..." -ForegroundColor Yellow
    @("Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation") | ForEach-Object {
        az provider register --namespace $_ --output none 2>$null
        Write-Host "  Registered: $_" -ForegroundColor Gray
    }

    # Create the extension
    Write-Host "[2/3] Creating VI Arc extension..." -ForegroundColor Yellow
    az k8s-extension create `
        --name $ViExtensionName `
        --extension-type "Microsoft.videoIndexer" `
        --scope cluster `
        --release-namespace "video-indexer" `
        --cluster-name $ClusterName `
        --resource-group $ClusterResourceGroup `
        --cluster-type "connectedClusters" `
        --version $ViExtensionVersion `
        --release-train "preview" `
        --auto-upgrade-minor-version "false" `
        --config "videoIndexer.accountId=$ViAccountId" `
        --config "videoIndexer.endpointUri=$ViEndpointUri" `
        --config AI.nodeSelector."beta\.kubernetes\.io/os"=linux `
        --config "storage.storageClass=$ViStorageClass" `
        --config "storage.accessMode=ReadWriteMany" `
        --config "ViAi.gpu.enabled=true" `
        --config "ViAi.gpu.tolerations.key=$ViGpuTolerationKey" `
        --config "videoIndexer.liveStreamEnabled=true" `
        --config "videoIndexer.mediaFilesEnabled=true"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] Extension creation failed" -ForegroundColor Red
        Write-Host "  Verify your subscription is approved: https://aka.ms/vi-live-register" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "  [OK] VI extension created" -ForegroundColor Green
}

# Verify
Write-Host "[3/3] Verifying extension status..." -ForegroundColor Yellow
az k8s-extension show `
    --name $ViExtensionName `
    --cluster-name $ClusterName `
    --resource-group $ClusterResourceGroup `
    --cluster-type connectedClusters `
    --query "{name:name, state:provisioningState, version:version}" `
    -o table

Write-Host ""
Write-Host "=== Video Indexer Extension Deployed ===" -ForegroundColor Green
Write-Host "Portal: https://$ViEndpointUri" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Add a camera:  .\demo5-video-indexer\scripts\manage-camera.ps1 -Action add -EnvFile $EnvFile"
Write-Host "  2. Open portal:   https://$ViEndpointUri"
Write-Host "  3. Configure custom insights and area of interest in the portal"
