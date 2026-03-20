// Azure AI Video Indexer Arc Extension
// Deploys the VI extension to an Arc-connected Kubernetes cluster.
// Ref: https://learn.microsoft.com/en-us/azure/azure-video-indexer/arc/azure-video-indexer-enabled-by-arc-quickstart
// Usage:
//   az deployment group create -g <rg> --template-file vi-extension.bicep \
//     --parameters accountId='<guid>' accountResourceId='<arm-id>' \
//     videoIndexerEndpointUri='https://<endpoint>' arcConnectedClusterName='<cluster>'

@description('Azure AI Video Indexer account ID (GUID)')
param accountId string

@description('Full ARM resource ID of the VI account')
param accountResourceId string

@description('HTTPS endpoint URI for the VI extension API/portal')
param videoIndexerEndpointUri string

@description('Arc-connected Kubernetes cluster name')
param arcConnectedClusterName string

@description('Extension name')
param extensionName string = 'video-indexer'

@description('Release train')
param releaseTrain string = 'preview'

@description('Storage class for RWX persistent volumes')
param storageClass string = 'longhorn'

@description('GPU toleration key')
param tolerationsKeyForGpu string = 'nvidia.com/gpu'

@description('Enable live video streaming')
param liveVideoStreamEnabled bool = true

@description('Enable media file uploads')
param mediaUploadsEnabled bool = true

@description('Enable GPU for AI processing')
param gpuEnabled bool = true

@description('DeepStream node selector label value')
param deepstreamNodeSelector string = 'deepstream'

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
    scope: {
      cluster: {}
    }
    configurationSettings: {
      'videoIndexer.accountId': accountId
      'videoIndexer.accountResourceId': accountResourceId
      'videoIndexer.endpointUri': videoIndexerEndpointUri
      'videoIndexer.mediaUploadsEnabled': string(mediaUploadsEnabled)
      'videoIndexer.liveVideoStreamEnabled': string(liveVideoStreamEnabled)
      'storage.storageClass': storageClass
      'storage.accessMode': 'ReadWriteMany'
      'ViAi.gpu.enabled': string(gpuEnabled)
      'ViAi.gpu.tolerations.key': tolerationsKeyForGpu
      'ViAi.deepstream.nodeSelector.workload': deepstreamNodeSelector
    }
  }
}

output extensionName string = viExtension.name
output provisioningState string = viExtension.properties.provisioningState
