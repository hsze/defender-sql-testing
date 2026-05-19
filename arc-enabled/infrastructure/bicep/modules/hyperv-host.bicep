targetScope = 'resourceGroup'

@description('Name of the Hyper-V host virtual machine.')
param vmName string

@description('Azure region for the Hyper-V host deployment.')
param location string = resourceGroup().location

@description('Azure VM size for the Hyper-V host virtual machine.')
param vmSize string = 'Standard_D8s_v3'

@description('Local administrator username for the Hyper-V host virtual machine.')
param adminUsername string

@description('Local administrator password for the Hyper-V host virtual machine.')
@secure()
param adminPassword string

var virtualNetworkName = '${vmName}-vnet'
var subnetName = 'default'
var networkSecurityGroupName = '${vmName}-nsg'
var publicIpAddressName = '${vmName}-pip'
var networkInterfaceName = '${vmName}-nic'
var dataDiskName = '${vmName}-data01'
var dnsLabel = 'arc${substring(uniqueString(resourceGroup().id, vmName), 0, 10)}'
var hyperVInstallCommand = 'powershell -ExecutionPolicy Bypass -Command "Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart"'

@description('Network security group allowing RDP access to the Hyper-V host.')
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 1000
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

@description('Virtual network for the Hyper-V host virtual machine.')
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.30.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.30.0.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

@description('Public IP address for RDP access to the Hyper-V host.')
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpAddressName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

@description('Network interface attached to the Hyper-V host virtual machine.')
resource networkInterface 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${subnetName}'
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}

@description('Data disk used for nested virtual machine storage on the Hyper-V host.')
resource nestedVmStorageDisk 'Microsoft.Compute/disks@2023-09-01' = {
  name: dataDiskName
  location: location
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: 100
  }
}

@description('Azure virtual machine that acts as the Hyper-V host for nested virtualization testing.')
resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      adminPassword: adminPassword
      adminUsername: adminUsername
      computerName: vmName
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          managedDisk: {
            id: nestedVmStorageDisk.id
          }
        }
      ]
    }
  }
}

@description('Custom Script Extension that installs the Hyper-V role on the host virtual machine.')
resource hyperVInstallExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'install-hyperv'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      commandToExecute: hyperVInstallCommand
    }
  }
}

output vmId string = virtualMachine.id
output publicIpAddress string = publicIp.properties.ipAddress
output adminUsername string = adminUsername
