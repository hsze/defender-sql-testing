targetScope = 'subscription'

@description('Deployment type to create: SQL on Azure VM, Azure SQL Database, or both.')
@allowed([
  'IaaS'
  'PaaS'
  'Both'
])
param deploymentType string

@description('Azure region for the deployment.')
param location string

@description('Name of the resource group to create for the deployment.')
param resourceGroupName string

@description('Name of the SQL Server virtual machine when deploying IaaS resources.')
param vmName string

@description('Azure VM size for the SQL Server virtual machine.')
param vmSize string = 'Standard_D4s_v5'

@description('Local administrator username for the Windows virtual machine.')
param adminUsername string

@description('Local administrator password for the Windows virtual machine.')
@secure()
param adminPassword string

@description('SQL authentication username for the SQL Server virtual machine.')
param sqlAuthUsername string

@description('SQL authentication password for the SQL Server virtual machine.')
@secure()
param sqlAuthPassword string

@description('Name of the Azure SQL logical server when deploying PaaS resources.')
param serverName string

@description('Name of the Azure SQL database when deploying PaaS resources.')
param databaseName string

@description('SQL administrator login for the Azure SQL logical server.')
param adminLogin string

@description('SQL administrator password for the Azure SQL logical server.')
@secure()
param adminLoginPassword string

var deployIaaS = contains([
  'IaaS'
  'Both'
], deploymentType)
var deployPaaS = contains([
  'PaaS'
  'Both'
], deploymentType)

resource deploymentResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

module defender 'modules/defender.bicep' = {
  name: 'defender-${uniqueString(subscription().subscriptionId, resourceGroupName)}'
}

module sqlVm 'modules/sql-vm.bicep' = if (deployIaaS) {
  name: 'sql-vm-${uniqueString(resourceGroupName, vmName)}'
  scope: resourceGroup(resourceGroupName)
  params: {
    adminPassword: adminPassword
    adminUsername: adminUsername
    location: location
    sqlAuthPassword: sqlAuthPassword
    sqlAuthUsername: sqlAuthUsername
    vmName: vmName
    vmSize: vmSize
  }
  dependsOn: [
    deploymentResourceGroup
    defender
  ]
}

module sqlDatabase 'modules/sql-database.bicep' = if (deployPaaS) {
  name: 'sql-database-${uniqueString(resourceGroupName, serverName, databaseName)}'
  scope: resourceGroup(resourceGroupName)
  params: {
    adminLogin: adminLogin
    adminPassword: adminLoginPassword
    databaseName: databaseName
    location: location
    serverName: serverName
  }
  dependsOn: [
    deploymentResourceGroup
    defender
  ]
}

output resourceGroupId string = deploymentResourceGroup.id
output deployedResourceGroupName string = deploymentResourceGroup.name
output defenderPricingStatus object = defender.outputs.currentPricingStatus
output iaasConnectionInfo object = deployIaaS ? {
  vmId: sqlVm!.outputs.vmId
  publicIpAddress: sqlVm!.outputs.publicIpAddress
  rdpEndpoint: '${sqlVm!.outputs.publicIpAddress}:3389'
  sqlEndpoint: '${sqlVm!.outputs.sqlFqdn},1433'
  sqlFqdn: sqlVm!.outputs.sqlFqdn
} : {}
output paasConnectionInfo object = deployPaaS ? {
  databaseId: sqlDatabase!.outputs.databaseId
  serverFqdn: sqlDatabase!.outputs.serverFqdn
  serverId: sqlDatabase!.outputs.serverId
  sqlEndpoint: '${sqlDatabase!.outputs.serverFqdn},1433'
} : {}
output connectionInfo object = {
  deploymentType: deploymentType
  resourceGroupName: deploymentResourceGroup.name
  defenderPricingStatus: defender.outputs.currentPricingStatus
  iaas: deployIaaS ? {
    vmId: sqlVm!.outputs.vmId
    publicIpAddress: sqlVm!.outputs.publicIpAddress
    rdpEndpoint: '${sqlVm!.outputs.publicIpAddress}:3389'
    sqlEndpoint: '${sqlVm!.outputs.sqlFqdn},1433'
    sqlFqdn: sqlVm!.outputs.sqlFqdn
  } : null
  paas: deployPaaS ? {
    databaseId: sqlDatabase!.outputs.databaseId
    serverFqdn: sqlDatabase!.outputs.serverFqdn
    serverId: sqlDatabase!.outputs.serverId
    sqlEndpoint: '${sqlDatabase!.outputs.serverFqdn},1433'
  } : null
}
