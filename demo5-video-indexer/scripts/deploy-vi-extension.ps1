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

# Pre-flight: Ensure GPU Operator and Longhorn are installed
Write-Host "[0/5] Checking prerequisites..." -ForegroundColor Yellow
$gpuNs = kubectl get namespace gpu-operator -o name 2>$null
$longhornSc = kubectl get storageclass $ViStorageClass -o name 2>$null

if (-not $gpuNs -or -not $longhornSc) {
    Write-Host "  Prerequisites missing — installing GPU Operator and Longhorn..." -ForegroundColor Gray
    $prereqScript = Join-Path $PSScriptRoot "install-prereqs.ps1"
    if (Test-Path $prereqScript) {
        & $prereqScript -EnvFile $EnvFile
    } else {
        Write-Host "  [WARN] install-prereqs.ps1 not found at: $prereqScript" -ForegroundColor Yellow
        if (-not $gpuNs) { Write-Host "  [WARN] GPU Operator not installed — DeepStream will not schedule" -ForegroundColor Yellow }
        if (-not $longhornSc) { Write-Host "  [WARN] Storage class '$ViStorageClass' not found — VI recording may fail" -ForegroundColor Yellow }
    }
} else {
    Write-Host "  [OK] GPU Operator installed" -ForegroundColor Green
    Write-Host "  [OK] Storage class '$ViStorageClass' available" -ForegroundColor Green
}

# Set subscription
az account set --subscription $SubscriptionId

# Step 1: Register providers
Write-Host "[1/5] Registering Azure resource providers..." -ForegroundColor Yellow
@("Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation") | ForEach-Object {
    az provider register --namespace $_ --output none 2>$null
    Write-Host "  Registered: $_" -ForegroundColor Gray
}

# Step 2: Install cert-manager extension (prerequisite)
Write-Host "[2/5] Checking cert-manager extension..." -ForegroundColor Yellow
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
Write-Host "[3/5] Deploying Video Indexer extension..." -ForegroundColor Yellow
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

# Step 4: Verify extension deployment with polling
Write-Host "[4/5] Verifying extension deployment..." -ForegroundColor Yellow
$maxWait = 300  # 5 minutes
$elapsed = 0
$interval = 15

while ($elapsed -lt $maxWait) {
    $state = az k8s-extension show `
        --name $ViExtensionName `
        --cluster-name $ClusterName `
        --resource-group $ClusterResourceGroup `
        --cluster-type connectedClusters `
        --query "provisioningState" -o tsv 2>$null
    
    if ($state -eq "Succeeded") {
        Write-Host "  [OK] Extension provisioning succeeded" -ForegroundColor Green
        break
    } elseif ($state -eq "Failed") {
        Write-Host "  [ERROR] Extension provisioning failed" -ForegroundColor Red
        az k8s-extension show --name $ViExtensionName --cluster-name $ClusterName --resource-group $ClusterResourceGroup --cluster-type connectedClusters --query "{name:name, state:provisioningState, error:errorInfo}" -o table
        exit 1
    }
    
    Write-Host "  Extension state: $state — waiting ${interval}s ($elapsed/${maxWait}s)..." -ForegroundColor Gray
    Start-Sleep -Seconds $interval
    $elapsed += $interval
}

if ($elapsed -ge $maxWait) {
    Write-Host "  [WARN] Extension did not reach Succeeded state within ${maxWait}s" -ForegroundColor Yellow
    Write-Host "         Check: az k8s-extension show --name $ViExtensionName --cluster-name $ClusterName --resource-group $ClusterResourceGroup --cluster-type connectedClusters" -ForegroundColor Yellow
}

# Check pod health
$releaseNs = if ($ViReleaseNamespace) { $ViReleaseNamespace } else { "default" }
Write-Host "  Checking pods in namespace '$releaseNs'..." -ForegroundColor Gray
$podJson = kubectl get pods -n $releaseNs -l app.kubernetes.io/part-of=video-indexer -o json 2>$null | ConvertFrom-Json
if ($podJson -and $podJson.items) {
    $total = $podJson.items.Count
    $ready = ($podJson.items | Where-Object { $_.status.phase -eq "Running" }).Count
    Write-Host "  [INFO] VI Pods: $ready/$total running in namespace '$releaseNs'" -ForegroundColor $(if ($ready -eq $total) { "Green" } else { "Yellow" })
} else {
    Write-Host "  [INFO] No VI pods found yet — they may still be starting" -ForegroundColor Gray
}

# Step 4.5: Label GPU nodes for DeepStream scheduling
Write-Host "[4.5/5] Labeling GPU nodes for DeepStream..." -ForegroundColor Yellow
$gpuNodes = kubectl get nodes -o json | ConvertFrom-Json
$labeled = 0
foreach ($node in $gpuNodes.items) {
    $gpuCapacity = $node.status.capacity.'nvidia.com/gpu'
    if ($gpuCapacity -and [int]$gpuCapacity -gt 0) {
        $nodeName = $node.metadata.name
        kubectl label node $nodeName workload=deepstream --overwrite 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Labeled node '$nodeName' with workload=deepstream" -ForegroundColor Green
            $labeled++
        } else {
            Write-Host "  [WARN] Failed to label node '$nodeName'" -ForegroundColor Yellow
        }
    }
}
if ($labeled -eq 0) {
    Write-Host "  [WARN] No GPU nodes found. DeepStream pods may not schedule." -ForegroundColor Yellow
    Write-Host "         Ensure GPU operator is installed and nodes have nvidia.com/gpu capacity." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Video Indexer Extension Deployed ===" -ForegroundColor Green
Write-Host "Portal: https://$ViEndpointUri" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open portal:  https://$ViEndpointUri"
Write-Host "  2. Upload video files or configure live camera streams in the portal"
