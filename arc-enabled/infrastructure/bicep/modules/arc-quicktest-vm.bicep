targetScope = 'resourceGroup'

@description('Name of the Arc quick-test virtual machine.')
param vmName string

@description('Azure region for the Arc quick-test deployment.')
param location string = resourceGroup().location

@description('Azure VM size for the Arc quick-test virtual machine.')
param vmSize string = 'Standard_D4s_v3'

@description('Local administrator username for the Arc quick-test virtual machine.')
param adminUsername string

@description('Local administrator password for the Arc quick-test virtual machine.')
@secure()
param adminPassword string

@description('SQL authentication username configured on the SQL Server instance.')
param sqlAuthUsername string

@description('SQL authentication password configured on the SQL Server instance.')
@secure()
param sqlAuthPassword string

var virtualNetworkName = '${vmName}-vnet'
var subnetName = 'default'
var networkSecurityGroupName = '${vmName}-nsg'
var publicIpAddressName = '${vmName}-pip'
var networkInterfaceName = '${vmName}-nic'
var dnsLabel = 'arcsql${substring(uniqueString(resourceGroup().id, vmName), 0, 10)}'
var arcAgentInstallCommand = 'powershell -ExecutionPolicy Bypass -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQAgAD0AIAAnAFMAdABvAHAAJwAKAFsARQBuAHYAaQByAG8AbgBtAGUAbgB0AF0AOgA6AFMAZQB0AEUAbgB2AGkAcgBvAG4AbQBlAG4AdABWAGEAcgBpAGEAYgBsAGUAKAAnAE0AUwBGAFQAXwBBAFIAQwBfAFQARQBTAFQAJwAsACAAJwB0AHIAdQBlACcALAAgACcATQBhAGMAaABpAG4AZQAnACkACgAkAGEAZwBlAG4AdABNAHMAaQAgAD0AIAAnAEMAOgBcAFcAaQBuAGQAbwB3AHMAXABUAGUAbQBwAFwAQQB6AHUAcgBlAEMAbwBuAG4AZQBjAHQAZQBkAE0AYQBjAGgAaQBuAGUAQQBnAGUAbgB0AC4AbQBzAGkAJwAKAEkAbgB2AG8AawBlAC0AVwBlAGIAUgBlAHEAdQBlAHMAdAAgAC0AVQBzAGUAQgBhAHMAaQBjAFAAYQByAHMAaQBuAGcAIAAtAFUAcgBpACAAJwBoAHQAdABwAHMAOgAvAC8AYQBrAGEALgBtAHMALwBBAHoAdQByAGUAQwBvAG4AbgBlAGMAdABlAGQATQBhAGMAaABpAG4AZQBBAGcAZQBuAHQAJwAgAC0ATwB1AHQARgBpAGwAZQAgACQAYQBnAGUAbgB0AE0AcwBpAAoAUwB0AGEAcgB0AC0AUAByAG8AYwBlAHMAcwAgAC0ARgBpAGwAZQBQAGEAdABoACAAJwBtAHMAaQBlAHgAZQBjAC4AZQB4AGUAJwAgAC0AQQByAGcAdQBtAGUAbgB0AEwAaQBzAHQAIAAnAC8AaQAnACwAIAAkAGEAZwBlAG4AdABNAHMAaQAsACAAJwAvAHEAbgAnACAALQBXAGEAaQB0AA=='

@description('Network security group allowing RDP and SQL access to the Arc quick-test virtual machine.')
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

@description('Virtual network for the Arc quick-test virtual machine.')
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.40.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.40.0.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

@description('Public IP address for the Arc quick-test virtual machine.')
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

@description('Network interface attached to the Arc quick-test virtual machine.')
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

@description('Azure virtual machine running SQL Server 2022 on Windows Server 2022 for Arc testing.')
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
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
  }
}

@description('SQL Virtual Machine registration used to configure SQL authentication for the quick-test VM.')
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

@description('Custom Script Extension that prepares the VM for Azure Arc onboarding and quick validation.')
resource arcPreparationExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: virtualMachine
  name: 'prepare-arc'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      commandToExecute: arcAgentInstallCommand
    }
  }
  dependsOn: [
    sqlVmRegistration
  ]
}

output vmId string = virtualMachine.id
output publicIpAddress string = publicIp.properties.ipAddress
