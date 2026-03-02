// ============================================================
// GEOINT Demo — Azure IoT Operations Extension (Bicep)
// ============================================================
// Installs the Azure IoT Operations k8s-extension on an
// Arc-enabled AKS cluster.  All values come from parameters —
// no cluster names, subscription IDs, or credentials are hardcoded.
//
// Deploy with:
//   az deployment group create \
//     --resource-group <clusterRG> \
//     --template-file iot-operations.bicep \
//     --parameters clusterName=<name> clusterResourceGroup=<rg>
// ============================================================

@description('Name of the Arc-connected Kubernetes cluster.')
param clusterName string

@description('Resource group that contains the Arc-connected cluster.')
param clusterResourceGroup string

@description('Azure IoT Operations extension version to install. Use "latest" for the newest stable release.')
param extensionVersion string = 'latest'

@description('Azure region for any extension-related resources.')
param location string = resourceGroup().location

// ── Reference the existing Arc-enabled cluster (idempotent) ──────
resource aksCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: clusterName
  scope: resourceGroup(clusterResourceGroup)
}

// ── Azure IoT Operations k8s extension ───────────────────────────
resource iotOpsExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  name: 'azure-iot-operations'
  // Extensions are scoped to the connected cluster resource
  scope: aksCluster
  properties: {
    extensionType: 'microsoft.iotoperations'
    autoUpgradeMinorVersion: true
    // Pin to a specific version when extensionVersion != 'latest'
    version: extensionVersion == 'latest' ? null : extensionVersion
    releaseTrain: 'stable'
    configurationSettings: {
      // Schema registry namespace — required by AIO
      'schemaRegistry.namespace': 'azure-iot-operations'
      // Enable the MQTT broker component
      'mqttBroker.enabled': 'true'
      // Enable the data processor / pipeline component
      'dataProcessor.enabled': 'true'
    }
    configurationProtectedSettings: {}
  }
}

// ── Outputs ──────────────────────────────────────────────────────
@description('The name of the installed IoT Operations extension.')
output extensionName string = iotOpsExtension.name

@description('Provisioning state of the IoT Operations extension.')
output provisioningState string = iotOpsExtension.properties.provisioningState
