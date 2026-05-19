targetScope = 'resourceGroup'

@description('Name of the SQL Server virtual machine.')
param vmName string

@description('Azure region for the SQL Server virtual machine resources.')
param location string = resourceGroup().location

@description('Azure VM size for the SQL Server virtual machine.')
param vmSize string = 'Standard_D4s_v5'

@description('Local administrator username for the Windows virtual machine.')
param adminUsername string

@description('Local administrator password for the Windows virtual machine.')
@secure()
param adminPassword string

@description('SQL authentication username to configure on the SQL Server instance.')
param sqlAuthUsername string

@description('SQL authentication password to configure on the SQL Server instance.')
@secure()
param sqlAuthPassword string

var virtualNetworkName = '${vmName}-vnet'
var subnetName = 'default'
var networkSecurityGroupName = '${vmName}-nsg'
var publicIpAddressName = '${vmName}-pip'
var networkInterfaceName = '${vmName}-nic'
var dnsLabel = 'sql${substring(uniqueString(resourceGroup().id, vmName), 0, 10)}'

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
      {
        name: 'Allow-SQL'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 1010
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1433'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.20.0.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpAddressName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

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

resource virtualMachine 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  plan: {
    name: 'sqldev-gen2'
    publisher: 'MicrosoftSQLServer'
    product: 'sql2022-ws2022'
  }
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
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: 'sqldev-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
  }
}

resource sqlVmRegistration 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: vmName
  location: location
  properties: {
    virtualMachineResourceId: virtualMachine.id
    sqlManagement: 'Full'
    serverConfigurationsManagementSettings: {
      sqlConnectivityUpdateSettings: {
        connectivityType: 'PUBLIC'
        port: 1433
        sqlAuthUpdatePassword: sqlAuthPassword
        sqlAuthUpdateUserName: sqlAuthUsername
      }
    }
  }
}

resource defenderForSqlExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'MicrosoftDefenderforSQL'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.AzureDefender'
    type: 'SqlAdvancedThreatProtection'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
  }
  dependsOn: [
    sqlVmRegistration
  ]
}

output vmId string = virtualMachine.id
output publicIpAddress string = publicIp.properties.ipAddress
output sqlFqdn string = publicIp.properties.dnsSettings.fqdn
