<#
.SYNOPSIS
    Install prerequisites for Video Indexer Arc Extension (Longhorn + NVIDIA GPU Operator).

.PARAMETER EnvFile
    Path to environment config file.

.EXAMPLE
    .\demo5-video-indexer\scripts\install-prereqs.ps1 -EnvFile .env
#>

param(
    [string]$EnvFile = "$PSScriptRoot\\..\\..\\.env"
)

$ErrorActionPreference = "Continue"

Write-Host "=== Install Video Indexer Prerequisites ===" -ForegroundColor Cyan

# --- Check kubectl ---
$kubectlExists = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlExists) {
    Write-Host "[ERROR] kubectl not found. Connect to the cluster first:" -ForegroundColor Red
    Write-Host "  az connectedk8s proxy -n <cluster> -g <rg>" -ForegroundColor Gray
    exit 1
}

# --- Check helm ---
$helmExists = Get-Command helm -ErrorAction SilentlyContinue
if (-not $helmExists) {
    Write-Host "[ERROR] helm not found. Install helm: https://helm.sh/docs/intro/install/" -ForegroundColor Red
    exit 1
}

# --- 1. NVIDIA GPU Operator ---
Write-Host "[1/3] Installing NVIDIA GPU Operator..." -ForegroundColor Yellow

$gpuNs = kubectl get namespace gpu-operator -o name 2>$null
if ($gpuNs) {
    Write-Host "  [OK] gpu-operator namespace exists — checking pods..." -ForegroundColor Green
    kubectl get pods -n gpu-operator --no-headers | Select-Object -First 5
} else {
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>$null
    helm repo update nvidia
    helm install gpu-operator nvidia/gpu-operator `
        --namespace gpu-operator `
        --create-namespace `
        --set driver.enabled=true `
        --set toolkit.enabled=true `
        --wait --timeout 10m

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] GPU Operator install may have issues — check pods" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] NVIDIA GPU Operator installed" -ForegroundColor Green
    }
}

# --- 2. Longhorn (RWX Storage) ---
Write-Host "[2/3] Installing Longhorn (RWX storage)..." -ForegroundColor Yellow

$longhornNs = kubectl get namespace longhorn-system -o name 2>$null
if ($longhornNs) {
    Write-Host "  [OK] Longhorn already installed" -ForegroundColor Green
} else {
    helm repo add longhorn https://charts.longhorn.io 2>$null
    helm repo update longhorn
    helm install longhorn longhorn/longhorn `
        --namespace longhorn-system `
        --create-namespace `
        --set defaultSettings.defaultDataPath="/var/lib/longhorn" `
        --wait --timeout 10m

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] Longhorn install may have issues — check pods" -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Longhorn installed" -ForegroundColor Green
    }
}

# --- 3. Verify GPU availability ---
Write-Host "[3/3] Verifying GPU availability..." -ForegroundColor Yellow
$gpuNodes = kubectl get nodes -o json | ConvertFrom-Json
$gpuFound = $false
foreach ($node in $gpuNodes.items) {
    $gpuCount = $node.status.capacity.'nvidia.com/gpu'
    if ($gpuCount -and [int]$gpuCount -gt 0) {
        Write-Host "  [OK] GPU found on node '$($node.metadata.name)': $gpuCount x nvidia.com/gpu" -ForegroundColor Green
        $gpuFound = $true
    }
}
if (-not $gpuFound) {
    Write-Host "  [WARN] No GPU nodes detected. Ensure NVIDIA drivers are installed and GPU Operator is running." -ForegroundColor Yellow
    Write-Host "  Check: kubectl get pods -n gpu-operator" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Prerequisites Check Complete ===" -ForegroundColor Green
Write-Host "Storage classes:"
kubectl get storageclass --no-headers
Write-Host ""
Write-Host "Next: .\demo5-video-indexer\scripts\deploy-vi-extension.ps1 -EnvFile $EnvFile"
