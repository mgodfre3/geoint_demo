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
   az extension add --name azure-iot-ops
   ```
3. **kubectl** and **Helm** installed
4. **Docker** (for building container images locally)
5. **Azure subscription** with Contributor access

## Step 0: Deploy IoT Backbone (Demo 0)

The IoT Backbone must be deployed first — it provides the MQTT sensor stream and alert events that trigger the AI vision pipeline.

### 0.1 Configure Environment File

```powershell
# Copy the template and fill in your cluster values
cp .env.template .env.staging
notepad .env.staging   # set AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AKS_CLUSTER_NAME, ACR_NAME, MQTT_PASSWORD, etc.
```

### 0.2 Deploy the IoT Backbone

```powershell
# Deploy to staging (installs AIO extension, MQTT broker, pipelines, simulator, alert-processor)
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging

# Dry-run to preview all commands first
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -DryRun
```

### 0.3 Verify IoT Backbone

```powershell
# Check all pods are Running
kubectl get pods -n azure-iot-operations

# Verify MQTT broker is accepting connections
kubectl port-forward svc/geoint-broker 1883:1883 -n azure-iot-operations
# In a second terminal: mosquitto_pub -h localhost -t "test/ping" -m "hello"

# Check alert processor health
kubectl port-forward svc/alert-processor 8080:8080 -n azure-iot-operations
# Open: http://localhost:8080/health
# Live alerts: http://localhost:8080/alerts
```

See [demo0-iot-backbone/README.md](../demo0-iot-backbone/README.md) for full IoT Backbone documentation including scenario switching, MQTT topic reference, and Grafana dashboard setup.

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

> The `postgis-ingest` container requires MQTT connectivity to the IoT Operations broker that runs on the AKS worker. Export the broker host/port + credentials (values come from your `.env` file) before starting Compose:
>
> ```bash
> export MQTT_HOST=$AKS_WORKER_IP
> export MQTT_PORT=${MQTT_BROKER_NODEPORT:-31883}
> export MQTT_USERNAME=${MQTT_USERNAME:-geoint-demo}
> export MQTT_PASSWORD=${MQTT_PASSWORD:-''}
> docker compose up -d
> ```
>
> Adjust the host/credentials as needed if you customized the IoT backbone deployment.

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
| IoT Backbone (Alert Processor) | `http://localhost:8080/alerts` (port-forward) |
| AI Vision Pipeline | `http://<node1-ip>:8081` |
| Geospatial Platform | `http://<node1-ip>:8083` |
| 3D Tactical Globe | `http://<node2-ip>:8085` |
| Analyst AI Assistant | `http://<node2-ip>:8086` |

## Teardown

```powershell
# Tear down Demo 0 (IoT Backbone)
.\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -Teardown

# Tear down remaining infrastructure
az group delete --name $rg --yes --no-wait
```
