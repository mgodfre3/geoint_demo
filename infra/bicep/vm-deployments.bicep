// VM Deployment on Azure Local via Azure Arc

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

@description('VM size')
param vmSize string = 'Standard_D4s_v3'

@description('OS disk size in GB')
param osDiskSizeGB int = 128

@description('Data disk size in GB')
param dataDiskSizeGB int = 64

resource vm 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  name: vmName
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
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
      osDisk: {
        osType: 'Linux'
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
      }
      dataDisks: [
        {
          diskSizeGB: dataDiskSizeGB
          createOption: 'Empty'
          lun: 0
        }
      ]
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

output vmId string = vm.id
output vmName string = vm.name
