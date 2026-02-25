# Setup Guide — GEOINT Demo on Azure Local

> **Taking this to an event?** See the [Event Runbook](event-runbook.md) for step-by-step booth setup, demo operation, and troubleshooting.

## Prerequisites

1. **Azure Local Cluster** — 2-node cluster deployed and registered with Azure Arc
2. **Azure CLI** with extensions:
   ```powershell
   az extension add --name aksarc
   az extension add --name stack-hci-vm
   az extension add --name connectedk8s
   az extension add --name k8s-configuration
   ```
3. **kubectl** and **Helm** installed
4. **Docker** (for building container images locally)
5. **Azure subscription** with Contributor access

## Step 1: Deploy Infrastructure

### 1.1 Create Resource Group

```powershell
$rg = "rg-geoint-demo"
$location = "eastus"
az group create --name $rg --location $location
```

### 1.2 Deploy VMs and AKS via Bicep

```powershell
az deployment group create `
  --resource-group $rg `
  --template-file infra/bicep/main.bicep `
  --parameters clusterName="geoint-aks" `
               vmGeoServerName="vm-geoserver" `
               vmGlobeName="vm-globe"
```

### 1.3 Configure GPU Passthrough

Ensure the NVIDIA A2 GPUs are passed through to the AKS node pool:

```powershell
# Verify GPU availability on AKS nodes
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
```

## Step 2: Set Up ACR and Flux

### 2.1 Create ACR

```powershell
$acrName = "acrgeointdemo"
az acr create --resource-group $rg --name $acrName --sku Standard
```

### 2.2 Build and Push Images

```powershell
.\scripts\setup-acr.ps1 -AcrName $acrName
```

### 2.3 Configure Flux GitOps

```powershell
az k8s-configuration flux create `
  --resource-group $rg `
  --cluster-name "geoint-aks" `
  --cluster-type connectedClusters `
  --name geoint-flux `
  --namespace flux-system `
  --scope cluster `
  --url "https://github.com/<your-org>/geoint_demo" `
  --branch main `
  --kustomization name=demos path=./infra/flux
```

## Step 3: Deploy VM Workloads

### 3.1 GeoServer + PostGIS (Demo 2)

SSH into the GeoServer VM and start services:

```bash
cd /opt/geoint/demo2-geo-platform
docker compose up -d
```

### 3.2 CesiumJS Globe (Demo 3)

SSH into the Globe VM and start services:

```bash
cd /opt/geoint/demo3-tactical-globe
docker compose up -d
```

## Step 4: Load Sample Data

```powershell
.\scripts\seed-data.ps1
```

This loads:
- Satellite imagery tiles into TileServer GL
- Vector features into PostGIS
- Sample GEOINT reports into Demo 4's vector store

## Step 5: Verify

Open each demo in a browser:

| Demo | URL |
|------|-----|
| AI Vision Pipeline | `http://<node1-ip>:8081` |
| Geospatial Platform | `http://<node1-ip>:8083` |
| 3D Tactical Globe | `http://<node2-ip>:8085` |
| Analyst AI Assistant | `http://<node2-ip>:8086` |

## Teardown

```powershell
az group delete --name $rg --yes --no-wait
```
