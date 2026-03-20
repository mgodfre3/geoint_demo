// Azure AI Video Indexer Arc Extension — Real-time Analysis
// Deploys the VI extension to an Arc-connected Kubernetes cluster.
// Usage:
//   az deployment group create -g <rg> --template-file vi-extension.bicep \
//     --parameters accountId='<vi_account_id>' videoIndexerEndpointUri='https://<endpoint>' \
//     arcConnectedClusterName='<cluster_name>'

@description('Azure AI Video Indexer account ID')
param accountId string

@description('HTTPS endpoint URI for the VI extension API/portal')
param videoIndexerEndpointUri string

@description('Arc-connected Kubernetes cluster name')
param arcConnectedClusterName string

@description('Extension name')
param extensionName string = 'vi-live'

@description('Extension version')
param version string = '1.2.53'

@description('Release train (preview for real-time analysis)')
param releaseTrain string = 'preview'

@description('Storage class for RWX persistent volumes')
param storageClass string = 'longhorn'

@description('GPU toleration key')
param tolerationsKeyForGpu string = 'nvidia.com/gpu'

@description('Enable live video streaming')
param liveStreamEnabled bool = true

@description('Enable media file uploads')
param mediaFilesEnabled bool = true

@description('Enable GPU for AI processing')
param gpuEnabled bool = true

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: arcConnectedClusterName
}

resource viExtension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' = {
  name: extensionName
  scope: connectedCluster
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.videoindexer'
    autoUpgradeMinorVersion: false
    releaseTrain: releaseTrain
    version: version
    scope: {
      cluster: {}
    }
    configurationSettings: {
      'videoIndexer.endpointUri': videoIndexerEndpointUri
      'videoIndexer.accountId': accountId
      'videoIndexer.mediaFilesEnabled': string(mediaFilesEnabled)
      'videoIndexer.liveStreamEnabled': string(liveStreamEnabled)
      'mediaServerStreams.enabled': string(liveStreamEnabled)
      'storage.storageClass': storageClass
      'storage.accessMode': 'ReadWriteMany'
      'ViAi.gpu.enabled': string(gpuEnabled)
      'ViAi.gpu.tolerations.key': tolerationsKeyForGpu
    }
  }
}

output extensionName string = viExtension.name
output provisioningState string = viExtension.properties.provisioningState
