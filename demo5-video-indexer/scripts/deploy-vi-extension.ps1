<#
.SYNOPSIS
    Deploy Azure AI Video Indexer Arc Extension.

.DESCRIPTION
    Creates the Video Indexer Arc extension on an existing Arc-enabled AKS cluster.
    Aligned with: https://learn.microsoft.com/en-us/azure/azure-video-indexer/arc/azure-video-indexer-enabled-by-arc-quickstart
    And: https://github.com/Azure-Samples/azure-video-indexer-samples/tree/master/VideoIndexerEnabledByArc/aks

.PARAMETER EnvFile
    Path to environment config file (default: .env in repo root).

.EXAMPLE
    .\demo5-video-indexer\scripts\deploy-vi-extension.ps1
    .\demo5-video-indexer\scripts\deploy-vi-extension.ps1 -EnvFile .env.template.mobile
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
$ViAccountName        = $envVars['VI_ACCOUNT_NAME']
$ViAccountRg          = $envVars['VI_ACCOUNT_RESOURCE_GROUP']
$ViAccountId          = $envVars['VI_ACCOUNT_ID']
$ViExtensionName      = $envVars['VI_EXTENSION_NAME']
$ViEndpointUri        = $envVars['VI_ENDPOINT_URI']
$ViStorageClass       = $envVars['VI_STORAGE_CLASS']
$ViGpuTolerationKey   = $envVars['VI_GPU_TOLERATION_KEY']
$ViExtensionVersion   = $envVars['VI_EXTENSION_VERSION']
$ViReleaseNamespace   = $envVars['VI_RELEASE_NAMESPACE']

# Defaults
if (-not $ViExtensionName)    { $ViExtensionName    = "video-indexer" }
if (-not $ViStorageClass)     { $ViStorageClass      = "longhorn" }
if (-not $ViGpuTolerationKey) { $ViGpuTolerationKey  = "nvidia.com/gpu" }
if (-not $ViReleaseNamespace) { $ViReleaseNamespace  = "default" }

# Build the full ARM resource ID for the VI account
$ViAccountResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ViAccountRg/providers/Microsoft.VideoIndexer/accounts/$ViAccountName"

# Validate required vars
$required = @{
    'AZURE_SUBSCRIPTION_ID'     = $SubscriptionId
    'AKS_CLUSTER_NAME'          = $ClusterName
    'AZURE_RESOURCE_GROUP'      = $ClusterResourceGroup
    'VI_ACCOUNT_NAME'           = $ViAccountName
    'VI_ACCOUNT_RESOURCE_GROUP' = $ViAccountRg
    'VI_ACCOUNT_ID'             = $ViAccountId
    'VI_ENDPOINT_URI'           = $ViEndpointUri
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value }
if ($missing) {
    Write-Host "ERROR: Missing required variables in $EnvFile:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $($_.Key)" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "=== Deploy Video Indexer Arc Extension ===" -ForegroundColor Cyan
Write-Host "  Cluster:            $ClusterName"
Write-Host "  Resource Group:     $ClusterResourceGroup"
Write-Host "  VI Account:         $ViAccountName ($ViAccountRg)"
Write-Host "  VI Account ID:      $ViAccountId"
Write-Host "  VI Resource ID:     $ViAccountResourceId"
Write-Host "  Extension Name:     $ViExtensionName"
Write-Host "  Endpoint URI:       $ViEndpointUri"
Write-Host "  Release Namespace:  $ViReleaseNamespace"
Write-Host "  Storage Class:      $ViStorageClass"
Write-Host "  GPU Toleration:     $ViGpuTolerationKey"
if ($ViExtensionVersion) { Write-Host "  Version:            $ViExtensionVersion" }
Write-Host ""

# Set subscription
az account set --subscription $SubscriptionId

# Step 1: Register providers
Write-Host "[1/4] Registering Azure resource providers..." -ForegroundColor Yellow
@("Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation") | ForEach-Object {
    az provider register --namespace $_ --output none 2>$null
    Write-Host "  Registered: $_" -ForegroundColor Gray
}

# Step 2: Install cert-manager extension (prerequisite)
Write-Host "[2/4] Checking cert-manager extension..." -ForegroundColor Yellow
$cmExists = az k8s-extension show `
    --name "azure-cert-manager" `
    --cluster-name $ClusterName `
    --resource-group $ClusterResourceGroup `
    --cluster-type connectedClusters `
    --query name -o tsv 2>$null

if ($cmExists) {
    Write-Host "  [OK] cert-manager already installed" -ForegroundColor Green
} else {
    Write-Host "  Installing cert-manager..." -ForegroundColor Gray
    az k8s-extension create `
        --cluster-name $ClusterName `
        --name "azure-cert-manager" `
        --resource-group $ClusterResourceGroup `
        --cluster-type connectedClusters `
        --extension-type Microsoft.CertManagement `
        --scope cluster
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] cert-manager installation had errors" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] cert-manager installed" -ForegroundColor Green
    }
}

# Step 3: Create or update VI extension
Write-Host "[3/4] Deploying Video Indexer extension..." -ForegroundColor Yellow
$existing = az k8s-extension show `
    --name $ViExtensionName `
    --cluster-name $ClusterName `
    --resource-group $ClusterResourceGroup `
    --cluster-type connectedClusters `
    --query name -o tsv 2>$null

# Build the az k8s-extension arguments
$extArgs = @(
    "--name", $ViExtensionName,
    "--extension-type", "Microsoft.videoIndexer",
    "--scope", "cluster",
    "--release-namespace", $ViReleaseNamespace,
    "--cluster-name", $ClusterName,
    "--resource-group", $ClusterResourceGroup,
    "--cluster-type", "connectedClusters",
    "--release-train", "preview",
    "--auto-upgrade-minor-version", "false",
    "--config", "videoIndexer.accountId=$ViAccountId",
    "--config", "videoIndexer.accountResourceId=$ViAccountResourceId",
    "--config", "videoIndexer.endpointUri=$ViEndpointUri",
    "--config", "videoIndexer.mediaUploadsEnabled=true",
    "--config", "videoIndexer.liveVideoStreamEnabled=true",
    "--config", "ViAi.gpu.enabled=true",
    "--config", "ViAi.gpu.tolerations.key=$ViGpuTolerationKey",
    "--config", "ViAi.deepstream.nodeSelector.workload=deepstream",
    "--config", "storage.storageClass=$ViStorageClass",
    "--config", "storage.accessMode=ReadWriteMany"
)

if ($ViExtensionVersion) {
    $extArgs += @("--version", $ViExtensionVersion)
}

if ($existing) {
    Write-Host "  Extension '$ViExtensionName' already exists — updating..." -ForegroundColor Gray
    az k8s-extension update @extArgs --yes
} else {
    Write-Host "  Creating extension '$ViExtensionName'..." -ForegroundColor Gray
    az k8s-extension create @extArgs
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Extension deployment failed" -ForegroundColor Red
    Write-Host "  Verify your subscription is approved: https://aka.ms/vi-register" -ForegroundColor Yellow
    exit 1
}
Write-Host "  [OK] VI extension deployed" -ForegroundColor Green

# Step 4: Verify
Write-Host "[4/4] Verifying extension status..." -ForegroundColor Yellow
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
Write-Host "  1. Label GPU node for deepstream:  kubectl label node <gpu-node> workload=deepstream"
Write-Host "  2. Open portal:  https://$ViEndpointUri"
Write-Host "  3. Upload video files or configure live camera streams in the portal"
