<#
.SYNOPSIS
    Deploy booth-analytics to the mobile VI cluster.
    Run after the VI extension is deployed and cameras are configured.
.PARAMETER ClusterName
    Connected cluster name. Default: mobile-geoint
.PARAMETER ResourceGroup
    Resource group. Default: acx-geoint-mobile
.PARAMETER AcrName
    ACR name. Default: acrgeointdemo
.PARAMETER BuildImage
    If set, builds and pushes the booth-analytics image to ACR.
.PARAMETER SpClientSecret
    Service principal client secret for the geoint-vi-token-refresh SP.
    Can also be set via VI_SP_CLIENT_SECRET environment variable.
.EXAMPLE
    .\scripts\deploy-mobile-booth.ps1 -SpClientSecret $secret
    .\scripts\deploy-mobile-booth.ps1 -BuildImage -SpClientSecret $secret
#>

param(
    [string]$ClusterName   = "mobile-geoint",
    [string]$ResourceGroup = "acx-geoint-mobile",
    [string]$AcrName       = "acrgeointdemo",
    [switch]$BuildImage,
    [string]$SpClientSecret = $env:VI_SP_CLIENT_SECRET
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

# --- Constants ---
$SubscriptionId = "fbaf508b-cb61-4383-9cda-a42bfa0c7bc9"
$ViAccountName  = "AC-VI"
$ViAccountRg    = "AdaptiveCloud-VideoIndexer"
$Namespace      = "geoint-booth"
$SpTenantId     = "d1623670-9777-4399-aaf6-01d87b84ef1d"
$SpClientId     = "b648a0dd-7b96-40bb-ba39-ca4e7f9ffd7c"

# --- Validate inputs ---
if (-not $SpClientSecret) {
    Write-Host "ERROR: -SpClientSecret or VI_SP_CLIENT_SECRET env var is required." -ForegroundColor Red
    Write-Host "  This is the client secret for the geoint-vi-token-refresh SP." -ForegroundColor Gray
    exit 1
}

$proxyProcess = $null

try {
    Write-Host ""
    Write-Host "=== Deploy Booth-Analytics to Mobile Cluster ===" -ForegroundColor Cyan
    Write-Host "  Cluster:        $ClusterName"
    Write-Host "  Resource Group: $ResourceGroup"
    Write-Host "  ACR:            $AcrName"
    Write-Host "  Namespace:      $Namespace"
    Write-Host ""

    az account set --subscription $SubscriptionId

    # ── Step 1: Connect to the cluster via proxy ─────────────────────
    Write-Host "[1/9] Connecting to cluster via az connectedk8s proxy..." -ForegroundColor Yellow
    $proxyPort = Get-Random -Minimum 47000 -Maximum 48000
    $proxyProcess = Start-Process -FilePath "powershell" `
        -ArgumentList "-NoProfile", "-Command", `
            "az connectedk8s proxy --name $ClusterName --resource-group $ResourceGroup --port $proxyPort 2>&1 | Out-Null" `
        -PassThru -WindowStyle Hidden

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $null = kubectl cluster-info 2>$null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    if ($ready) {
        Write-Host "  [OK] Cluster proxy connected on port $proxyPort" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Proxy may not be fully ready — continuing anyway" -ForegroundColor Yellow
    }

    # ── Step 2: Build and push image ─────────────────────────────────
    if ($BuildImage) {
        Write-Host "[2/9] Building booth-analytics image via ACR Tasks..." -ForegroundColor Yellow
        az acr build `
            --registry $AcrName `
            --image "geoint/booth-analytics:latest" `
            --file "$repoRoot\demo5-video-indexer\booth-app\Dockerfile" `
            "$repoRoot\demo5-video-indexer\booth-app"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] ACR build may have failed" -ForegroundColor Yellow
        } else {
            Write-Host "  [OK] Image pushed to $AcrName.azurecr.io/geoint/booth-analytics:latest" -ForegroundColor Green
        }
    } else {
        Write-Host "[2/9] Skipping image build (use -BuildImage to build)" -ForegroundColor Gray
    }

    # ── Step 3: Create namespace (idempotent) ────────────────────────
    Write-Host "[3/9] Creating namespace $Namespace..." -ForegroundColor Yellow
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
    Write-Host "  [OK] Namespace $Namespace ready" -ForegroundColor Green

    # ── Step 4: Create ACR pull secret ───────────────────────────────
    # Secret name matches booth-analytics-mobile.yaml imagePullSecrets
    Write-Host "[4/9] Creating ACR pull secret..." -ForegroundColor Yellow
    az acr update --name $AcrName --admin-enabled true --output none
    $acrPwd = az acr credential show --name $AcrName --query "passwords[0].value" -o tsv
    kubectl create secret docker-registry acr-secret `
        --docker-server="$AcrName.azurecr.io" `
        --docker-username=$AcrName `
        --docker-password=$acrPwd `
        -n $Namespace --dry-run=client -o yaml | kubectl apply -f -
    Write-Host "  [OK] ACR pull secret created in $Namespace" -ForegroundColor Green

    # ── Step 5: Generate VI extension token ──────────────────────────
    Write-Host "[5/9] Generating VI extension access token..." -ForegroundColor Yellow
    $extensionsJson = az rest --method get `
        --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$ClusterName/providers/Microsoft.KubernetesConfiguration/extensions?api-version=2023-05-01"
    $viExt = ($extensionsJson | ConvertFrom-Json).value |
        Where-Object { $_.properties.extensionType -eq "microsoft.videoindexer" }

    if (-not $viExt) {
        Write-Host "  [WARN] No VI extension found on cluster — skipping token generation" -ForegroundColor Yellow
    } else {
        $extensionId = $viExt.id
        Write-Host "  Extension: $extensionId" -ForegroundColor Gray

        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            $body = @{
                permissionType = "Contributor"
                scope          = "Account"
                extensionId    = $extensionId
            } | ConvertTo-Json
            Set-Content -Path $bodyFile -Value $body

            $tokenResult = az rest --method post `
                --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ViAccountRg/providers/Microsoft.VideoIndexer/accounts/$ViAccountName/generateExtensionAccessToken?api-version=2023-06-02-preview" `
                --body "@$bodyFile" `
                --headers "Content-Type=application/json"

            $token = ($tokenResult | ConvertFrom-Json).accessToken
            if ($token) {
                kubectl create secret generic vi-token `
                    --from-literal=token=$token `
                    -n $Namespace --dry-run=client -o yaml | kubectl apply -f -
                Write-Host "  [OK] vi-token secret created (expires in ~65 min)" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Failed to generate VI token" -ForegroundColor Yellow
            }
        } finally {
            Remove-Item $bodyFile -ErrorAction SilentlyContinue
        }
    }

    # ── Step 6: Create SP credentials secret ─────────────────────────
    Write-Host "[6/9] Creating SP credentials secret (geoint-vi-token-refresh)..." -ForegroundColor Yellow
    kubectl create secret generic vi-sp-credentials -n $Namespace `
        --from-literal=tenant-id=$SpTenantId `
        --from-literal=client-id=$SpClientId `
        --from-literal=client-secret=$SpClientSecret `
        --dry-run=client -o yaml | kubectl apply -f -
    Write-Host "  [OK] vi-sp-credentials secret created" -ForegroundColor Green

    # ── Step 7: Apply the booth-analytics deployment ─────────────────
    Write-Host "[7/9] Applying booth-analytics deployment..." -ForegroundColor Yellow
    kubectl apply -f "$repoRoot\demo5-video-indexer\infra\booth-analytics-mobile.yaml"
    Write-Host "  [OK] Deployment applied" -ForegroundColor Green

    # ── Step 8: Enable HLS on MediaMTX (non-critical) ───────────────
    Write-Host "[8/9] Checking MediaMTX media server for HLS..." -ForegroundColor Yellow
    $savedPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $allConfigMaps = kubectl get configmap -A -o json 2>$null
    $mediaServerCm = $null
    if ($allConfigMaps) {
        $mediaServerCm = ($allConfigMaps | ConvertFrom-Json).items |
            Where-Object { $_.metadata.name -match "media-server" } |
            Select-Object -First 1
    }

    if ($mediaServerCm) {
        $cmName = $mediaServerCm.metadata.name
        $cmNs   = $mediaServerCm.metadata.namespace
        Write-Host "  Found configmap: $cmName in $cmNs" -ForegroundColor Gray

        $cmJson = kubectl get configmap $cmName -n $cmNs -o json 2>$null | ConvertFrom-Json
        $yamlKey = ($cmJson.data.PSObject.Properties | Select-Object -First 1).Name
        if ($yamlKey) {
            $configContent = $cmJson.data.$yamlKey
            if ($configContent -match "hls:\s*no") {
                $configContent = $configContent -replace "hls:\s*no", "hls: yes"
                $patchObj = @{ data = @{ $yamlKey = $configContent } } | ConvertTo-Json -Compress -Depth 5
                kubectl patch configmap $cmName -n $cmNs --type merge -p $patchObj
                Write-Host "  [OK] Patched HLS from 'no' to 'yes'" -ForegroundColor Green

                # Restart matching media server deployment
                $allDeploys = kubectl get deployment -n $cmNs -o json 2>$null
                if ($allDeploys) {
                    $mediaDeploy = ($allDeploys | ConvertFrom-Json).items |
                        Where-Object { $_.metadata.name -match "media-server" } |
                        Select-Object -First 1
                    if ($mediaDeploy) {
                        kubectl rollout restart deployment/$($mediaDeploy.metadata.name) -n $cmNs
                        Write-Host "  [OK] Media server deployment restarted" -ForegroundColor Green
                    }
                }
            } else {
                Write-Host "  [OK] HLS already enabled or not configured" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  [SKIP] MediaMTX configmap not found — HLS patching skipped" -ForegroundColor Gray
    }

    $ErrorActionPreference = $savedPref

    # ── Step 9: Wait for rollout and verify ──────────────────────────
    Write-Host "[9/9] Waiting for rollout..." -ForegroundColor Yellow
    kubectl rollout status deployment/booth-analytics -n $Namespace --timeout=120s
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] booth-analytics is running" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Rollout did not complete within timeout" -ForegroundColor Yellow
    }

    Write-Host "  Verifying health endpoint..." -ForegroundColor Gray
    kubectl exec deployment/booth-analytics -n $Namespace -- `
        python -c "import requests; r=requests.get('http://localhost:8080/api/health',timeout=5); print(r.json())" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] Health check failed — pod may still be starting" -ForegroundColor Yellow
    }

    # ── Summary ──────────────────────────────────────────────────────
    $nodeIp = kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type=='InternalIP')].address}" 2>$null
    if (-not $nodeIp) { $nodeIp = "<node-ip>" }

    Write-Host ""
    Write-Host "=== Booth-Analytics Deployed ===" -ForegroundColor Green
    Write-Host "  Booth URL:  http://$($nodeIp):30080/"
    Write-Host "  Namespace:  $Namespace"
    Write-Host "  Cluster:    $ClusterName"
    Write-Host ""
    Write-Host "  Token refresh: .\scripts\refresh-vi-token.ps1 (run every 45 min)" -ForegroundColor Gray
    Write-Host ""

} finally {
    # Clean up the proxy process
    if ($proxyProcess -and -not $proxyProcess.HasExited) {
        Write-Host "Cleaning up cluster proxy (PID $($proxyProcess.Id))..." -ForegroundColor Gray
        Stop-Process -Id $proxyProcess.Id -ErrorAction SilentlyContinue
    }
}
