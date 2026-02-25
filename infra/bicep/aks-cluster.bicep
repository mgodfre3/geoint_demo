// Arc-Enabled AKS Cluster on Azure Local with GPU node pool

@description('AKS cluster name')
param clusterName string

@description('Azure Local custom location resource ID')
param customLocationId string

@description('Azure Local logical network resource ID')
param logicalNetworkId string

@description('Kubernetes version')
param kubernetesVersion string = '1.28.5'

resource aksCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: clusterName
}

// Note: Arc-Enabled AKS provisioned cluster definition
// Actual provisioning uses `az aksarc create` with GPU node pool
// This template captures the desired state for documentation

output clusterName string = clusterName
output customLocationId string = customLocationId
