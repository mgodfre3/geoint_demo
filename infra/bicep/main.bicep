// GEOINT Demo — Azure Local Infrastructure
// Deploys VMs and Arc-Enabled AKS cluster with GPU support

targetScope = 'resourceGroup'

@description('Name of the AKS Arc cluster')
param clusterName string = 'geoint-aks'

@description('Name of the VM for GeoServer/Geo Platform (Demo 2)')
param vmGeoServerName string = 'vm-geoserver'

@description('Name of the VM for CesiumJS Globe (Demo 3)')
param vmGlobeName string = 'vm-globe'

@description('Azure Local custom location resource ID')
param customLocationId string

@description('Azure Local logical network resource ID')
param logicalNetworkId string

@description('SSH public key for VM access')
@secure()
param sshPublicKey string

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Gallery image resource ID for VM OS (e.g., Ubuntu 22.04 from Azure Marketplace)')
param galleryImageId string

// AKS Arc Cluster
module aksCluster 'aks-cluster.bicep' = {
  name: 'deploy-aks-cluster'
  params: {
    clusterName: clusterName
    customLocationId: customLocationId
  }
}

// GeoServer VM (Demo 2) — Node 1
module vmGeoServer 'vm-deployments.bicep' = {
  name: 'deploy-vm-geoserver'
  params: {
    vmName: vmGeoServerName
    customLocationId: customLocationId
    logicalNetworkId: logicalNetworkId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    galleryImageId: galleryImageId
    vCPUCount: 8
    memoryMB: 16384
  }
}

// CesiumJS Globe VM (Demo 3) — Node 2
module vmGlobe 'vm-deployments.bicep' = {
  name: 'deploy-vm-globe'
  params: {
    vmName: vmGlobeName
    customLocationId: customLocationId
    logicalNetworkId: logicalNetworkId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    galleryImageId: galleryImageId
    vCPUCount: 4
    memoryMB: 8192
  }
}

output aksClusterName string = aksCluster.outputs.clusterName
output geoServerVmId string = vmGeoServer.outputs.vmId
output globeVmId string = vmGlobe.outputs.vmId
