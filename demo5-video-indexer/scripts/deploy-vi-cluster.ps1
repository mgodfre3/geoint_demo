<#
.SYNOPSIS
    One-stop deployment of Video Indexer on a dedicated AKS Arc cluster.

.DESCRIPTION
    Creates a dedicated AKS Arc cluster with GPU and CPU node pools,
    installs prerequisites (GPU Operator, Longhorn), deploys the
    Video Indexer Arc extension, and registers cameras.

    This script is designed for a standalone VI deployment separate
    from the main GEOINT demo cluster.

.PARAMETER EnvFile
    Path to environment config file (default: .env.template.mobile-vi)

.EXAMPLE
    .\demo5-video-indexer\scripts\deploy-vi-cluster.ps1
    .\demo5-video-indexer\scripts\deploy-vi-cluster.ps1 -EnvFile .env.template.mobile-vi
#>

param(
    [string]$EnvFile = "$PSScriptRoot\..\..\\.env.template.mobile-vi"
)

$ErrorActionPreference = "Continue"

# --- Load environment file ---
if (-not (Test-Path $EnvFile)) {
    Write-Host "ERROR: Environment file not found: $EnvFile" -ForegroundColor Red
    Write-Host "Copy .env.template.mobile-vi and fill in your values." -ForegroundColor Yellow
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

# --- Resolve variables ---
$SubscriptionId    = $envVars['AZURE_SUBSCRIPTION_ID']
$ResourceGroup     = $envVars['AZURE_RESOURCE_GROUP']
$Location          = $envVars['AZURE_LOCATION']
$CustomLocationId  = $envVars['AZURE_CUSTOM_LOCATION_ID']
$LogicalNetworkId  = $envVars['AZURE_LOGICAL_NETWORK_ID']
$ClusterName       = $envVars['VI_AKS_CLUSTER_NAME']
$KubeVersion       = $envVars['VI_AKS_KUBERNETES_VERSION']
$GpuVmSize         = $envVars['VI_GPU_NODE_VM_SIZE']
$GpuNodeCount      = $envVars['VI_GPU_NODE_COUNT']
$CpuVmSize         = $envVars['VI_CPU_NODE_VM_SIZE']
$CpuNodeCount      = $envVars['VI_CPU_NODE_COUNT']

# Defaults
if (-not $ClusterName)    { $ClusterName = "mobile-vi" }
if (-not $KubeVersion)    { $KubeVersion = "1.32.9" }
if (-not $GpuVmSize)      { $GpuVmSize = "Standard_NC8_A2" }
if (-not $GpuNodeCount)   { $GpuNodeCount = "1" }
if (-not $CpuVmSize)      { $CpuVmSize = "Standard_D16s_v3" }
if (-not $CpuNodeCount)   { $CpuNodeCount = "1" }

# Validate required vars
$required = @{
    'AZURE_SUBSCRIPTION_ID'    = $SubscriptionId
    'AZURE_RESOURCE_GROUP'     = $ResourceGroup
    'AZURE_CUSTOM_LOCATION_ID' = $CustomLocationId
    'AZURE_LOGICAL_NETWORK_ID' = $LogicalNetworkId
    'VI_ACCOUNT_ID'            = $envVars['VI_ACCOUNT_ID']
    'VI_ENDPOINT_URI'          = $envVars['VI_ENDPOINT_URI']
}
$missing = $required.GetEnumerator() | Where-Object { -not $_.Value }
if ($missing) {
    Write-Host "ERROR: Missing required variables in $EnvFile:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $($_.Key)" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "=== Video Indexer Dedicated Cluster Deployment ===" -ForegroundColor Cyan
Write-Host "  Cluster:          $ClusterName"
Write-Host "  Resource Group:   $ResourceGroup"
Write-Host "  Location:         $Location"
Write-Host "  GPU Node Pool:    $GpuVmSize × $GpuNodeCount"
Write-Host "  CPU Node Pool:    $CpuVmSize × $CpuNodeCount"
Write-Host "  VI Account:       $($envVars['VI_ACCOUNT_NAME'])"
Write-Host "  Endpoint:         $($envVars['VI_ENDPOINT_URI'])"
Write-Host ""

# Set subscription
az account set --subscription $SubscriptionId

# ═══════════════════════════════════════════════════════════════
# Step 1: Create AKS Arc cluster
# ═══════════════════════════════════════════════════════════════
Write-Host "[1/7] Creating AKS Arc cluster '$ClusterName'..." -ForegroundColor Yellow
$aksState = az aksarc show --name $ClusterName --resource-group $ResourceGroup --query "properties.provisioningState" -o tsv 2>$null
if ($aksState -eq "Succeeded") {
    Write-Host "  [OK] Cluster '$ClusterName' already exists" -ForegroundColor Green
} elseif ($CustomLocationId -and $LogicalNetworkId) {
    Write-Host "  Creating cluster (this may take 15-30 min)..." -ForegroundColor Gray
    az aksarc create `
        --name $ClusterName `
        --resource-group $ResourceGroup `
        --custom-location $CustomLocationId `
        --vnet-ids $LogicalNetworkId `
        --kubernetes-version $KubeVersion `
        --generate-ssh-keys `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] Cluster creation failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Cluster '$ClusterName' created" -ForegroundColor Green
} else {
    Write-Host "  [ERROR] Missing AZURE_CUSTOM_LOCATION_ID or AZURE_LOGICAL_NETWORK_ID" -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════
# Step 2: Add node pools
# ═══════════════════════════════════════════════════════════════
Write-Host "[2/7] Configuring node pools..." -ForegroundColor Yellow

# GPU node pool
$gpuPoolExists = az aksarc nodepool show --name gpupool --cluster-name $ClusterName --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($gpuPoolExists) {
    Write-Host "  [OK] GPU pool 'gpupool' already exists" -ForegroundColor Green
} else {
    Write-Host "  Adding GPU pool ($GpuVmSize × $GpuNodeCount)..." -ForegroundColor Gray
    az aksarc nodepool add `
        --name gpupool `
        --cluster-name $ClusterName `
        --resource-group $ResourceGroup `
        --node-count $GpuNodeCount `
        --os-type Linux `
        --node-vm-size $GpuVmSize `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] GPU pool creation may have failed" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] GPU pool created" -ForegroundColor Green
    }
}

# CPU node pool for VI core services
$cpuPoolExists = az aksarc nodepool show --name vipool --cluster-name $ClusterName --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($cpuPoolExists) {
    Write-Host "  [OK] CPU pool 'vipool' already exists" -ForegroundColor Green
} else {
    Write-Host "  Adding CPU pool ($CpuVmSize × $CpuNodeCount)..." -ForegroundColor Gray
    az aksarc nodepool add `
        --name vipool `
        --cluster-name $ClusterName `
        --resource-group $ResourceGroup `
        --node-count $CpuNodeCount `
        --os-type Linux `
        --node-vm-size $CpuVmSize `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] CPU pool creation may have failed" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] CPU pool created" -ForegroundColor Green
    }
}

# ═══════════════════════════════════════════════════════════════
# Step 3: Install prerequisites (GPU Operator + Longhorn)
# ═══════════════════════════════════════════════════════════════
Write-Host "[3/7] Installing prerequisites..." -ForegroundColor Yellow
$prereqScript = Join-Path $PSScriptRoot "install-prereqs.ps1"
if (Test-Path $prereqScript) {
    & $prereqScript
} else {
    Write-Host "  [WARN] install-prereqs.ps1 not found — install GPU Operator and Longhorn manually" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════
# Step 4: Deploy Video Indexer extension
# ═══════════════════════════════════════════════════════════════
Write-Host "[4/7] Deploying Video Indexer extension..." -ForegroundColor Yellow

# Map env vars so deploy-vi-extension.ps1 can read them
# It expects AKS_CLUSTER_NAME, not VI_AKS_CLUSTER_NAME
[Environment]::SetEnvironmentVariable('AKS_CLUSTER_NAME', $ClusterName, 'Process')

$viDeployScript = Join-Path $PSScriptRoot "deploy-vi-extension.ps1"
if (Test-Path $viDeployScript) {
    & $viDeployScript -EnvFile $EnvFile
} else {
    Write-Host "  [ERROR] deploy-vi-extension.ps1 not found" -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════
# Step 5: Label GPU nodes for DeepStream
# ═══════════════════════════════════════════════════════════════
Write-Host "[5/7] Labeling GPU nodes for DeepStream..." -ForegroundColor Yellow
$gpuNodes = kubectl get nodes -o json | ConvertFrom-Json
$labeled = 0
foreach ($node in $gpuNodes.items) {
    $gpuCapacity = $node.status.capacity.'nvidia.com/gpu'
    if ($gpuCapacity -and [int]$gpuCapacity -gt 0) {
        $nodeName = $node.metadata.name
        kubectl label node $nodeName workload=deepstream --overwrite 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Labeled '$nodeName' with workload=deepstream" -ForegroundColor Green
            $labeled++
        }
    }
}
if ($labeled -eq 0) {
    Write-Host "  [WARN] No GPU nodes found — DeepStream pods may not schedule" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════
# Step 6: Verify deployment
# ═══════════════════════════════════════════════════════════════
Write-Host "[6/7] Verifying deployment..." -ForegroundColor Yellow
$ViExtensionName = if ($envVars['VI_EXTENSION_NAME']) { $envVars['VI_EXTENSION_NAME'] } else { "video-indexer" }
$releaseNs = if ($envVars['VI_RELEASE_NAMESPACE']) { $envVars['VI_RELEASE_NAMESPACE'] } else { "default" }

az k8s-extension show `
    --name $ViExtensionName `
    --cluster-name $ClusterName `
    --resource-group $ResourceGroup `
    --cluster-type connectedClusters `
    --query "{name:name, state:provisioningState, version:version}" `
    -o table

# Pod health
$podJson = kubectl get pods -n $releaseNs -o json 2>$null | ConvertFrom-Json
if ($podJson -and $podJson.items) {
    $total = $podJson.items.Count
    $running = ($podJson.items | Where-Object { $_.status.phase -eq "Running" }).Count
    Write-Host "  [INFO] Pods: $running/$total running in namespace '$releaseNs'" -ForegroundColor $(if ($running -eq $total) { "Green" } else { "Yellow" })
}

# ═══════════════════════════════════════════════════════════════
# Step 7: Register camera (if configured)
# ═══════════════════════════════════════════════════════════════
$CameraRtspUrl = $envVars['CAMERA_RTSP_URL']
if ($CameraRtspUrl) {
    Write-Host "[7/7] Registering camera..." -ForegroundColor Yellow
    $cameraScript = Join-Path $PSScriptRoot "manage-camera.ps1"
    if (Test-Path $cameraScript) {
        & $cameraScript -Action add -EnvFile $EnvFile
    } else {
        Write-Host "  [WARN] manage-camera.ps1 not found" -ForegroundColor Yellow
    }
} else {
    Write-Host "[7/7] Skipping camera — CAMERA_RTSP_URL not set" -ForegroundColor Gray
}

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "=== Video Indexer Deployment Complete ===" -ForegroundColor Green
Write-Host "  Cluster:   $ClusterName"
Write-Host "  Portal:    https://$($envVars['VI_ENDPOINT_URI'])"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open portal: https://$($envVars['VI_ENDPOINT_URI'])"
Write-Host "  2. Configure custom insights and area-of-interest zones"
Write-Host ""
