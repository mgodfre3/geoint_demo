using 'main.bicep'

// ============================================================
// Bicep parameter file — GEOINT Demo
// Copy and customize per cluster target.
// ============================================================

param clusterName = readEnvironmentVariable('AKS_CLUSTER_NAME', 'geoint-aks')

param customLocationId = readEnvironmentVariable('AZURE_CUSTOM_LOCATION_ID')

param logicalNetworkId = readEnvironmentVariable('AZURE_LOGICAL_NETWORK_ID')

param galleryImageId = readEnvironmentVariable('AZURE_GALLERY_IMAGE_ID')

param adminUsername = readEnvironmentVariable('VM_ADMIN_USERNAME', 'azureuser')

param vmGeoServerName = readEnvironmentVariable('VM_GEOSERVER_NAME', 'vm-geoserver')

param vmGlobeName = readEnvironmentVariable('VM_GLOBE_NAME', 'vm-globe')

param sshPublicKey = readEnvironmentVariable('SSH_PUBLIC_KEY')
