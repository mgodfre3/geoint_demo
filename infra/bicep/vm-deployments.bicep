// VM Deployment on Azure Local via Azure Arc
// Azure Local VMs require a HybridCompute/machines parent resource
// with a virtualMachineInstances/default child extension resource.

@description('VM name')
param vmName string

@description('Azure Local custom location resource ID')
param customLocationId string

@description('Azure Local logical network resource ID')
param logicalNetworkId string

@description('Admin username')
param adminUsername string = 'azureuser'

@description('SSH public key')
@secure()
param sshPublicKey string

@description('Number of vCPUs for the VM')
param vCPUCount int = 4

@description('Memory in MB for the VM')
param memoryMB int = 8192

@description('Gallery image resource ID for the VM OS')
param galleryImageId string

@description('Storage path ID for VM disks (from: az stack-hci-vm storagepath list)')
param storagePathId string = ''

// Parent Arc machine resource
resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' = {
  name: vmName
  location: resourceGroup().location
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
}

// VM instance as extension resource on the Arc machine
resource vmInstance 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  name: 'default'
  scope: arcMachine
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      processors: vCPUCount
      memoryMB: memoryMB
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        id: galleryImageId
      }
      vmConfigStoragePathId: storagePathId != '' ? storagePathId : null
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: logicalNetworkId
        }
      ]
    }
  }
}

output vmId string = arcMachine.id
output vmName string = arcMachine.name
