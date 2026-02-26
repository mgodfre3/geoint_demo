// VM Deployment on Azure Local — REFERENCE ONLY
// Azure Local VMs are deployed via CLI (az stack-hci-vm create) in deploy-all.ps1
// because Bicep type definitions for Azure Stack HCI VMs are not stable.
//
// This file documents the desired VM configuration for reference.
// Actual deployment command:
//   az stack-hci-vm create --name <name> --resource-group <rg> \
//     --custom-location <cl> --image <gallery-image-id> \
//     --admin-username azureuser --ssh-key-values ~/.ssh/id_rsa.pub \
//     --hardware-profile memory-mb=<mb> processors=<vcpu> \
//     --nic-id <logical-network-id>

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
