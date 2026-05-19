targetScope = 'subscription'

@description('Deployment mode for the Arc-enabled SQL Server testing environment.')
@allowed([
  'nested-hyperv'
  'quick-test'
])
param deploymentMode string

@description('Azure region for the Arc-enabled SQL Server testing environment.')
param location string

@description('Name of the resource group to create for the Arc-enabled SQL Server testing environment.')
param resourceGroupName string

@description('Name of the primary virtual machine created for the selected deployment mode.')
param vmName string

@description('Azure VM size for the primary virtual machine created for the selected deployment mode.')
param vmSize string

@description('Local administrator username for the deployed virtual machine.')
param adminUsername string

@description('Local administrator password for the deployed virtual machine.')
@secure()
param adminPassword string

@description('SQL authentication username used only for the quick-test deployment mode.')
param sqlAuthUsername string = ''

@description('SQL authentication password used only for the quick-test deployment mode.')
@secure()
param sqlAuthPassword string = ''

var deployNestedHyperV = deploymentMode == 'nested-hyperv'
var deployQuickTest = deploymentMode == 'quick-test'
var nestedDeploymentCommand = 'az deployment sub create --location ${location} --template-file main.bicep --parameters parameters/nested-hyperv.parameters.json'
var quickTestDeploymentCommand = 'az deployment sub create --location ${location} --template-file main.bicep --parameters parameters/quick-test.parameters.json'

@description('Resource group that holds the Arc-enabled SQL Server testing resources.')
resource testingResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

@description('Subscription-level Defender for SQL enablement for Azure VMs and Arc-connected machines.')
module defenderArc 'modules/defender-arc.bicep' = {
  name: 'defender-arc-${uniqueString(subscription().subscriptionId, resourceGroupName)}'
}

@description('Nested Hyper-V host deployment for Arc-enabled SQL Server testing.')
module hyperVHost 'modules/hyperv-host.bicep' = if (deployNestedHyperV) {
  name: 'hyperv-host-${uniqueString(resourceGroupName, vmName)}'
  scope: resourceGroup(resourceGroupName)
  params: {
    adminPassword: adminPassword
    adminUsername: adminUsername
    location: location
    vmName: vmName
    vmSize: vmSize
  }
  dependsOn: [
    testingResourceGroup
    defenderArc
  ]
}

@description('Quick-test SQL VM deployment for Arc-enabled SQL Server validation.')
module quickTestVm 'modules/arc-quicktest-vm.bicep' = if (deployQuickTest) {
  name: 'arc-quicktest-${uniqueString(resourceGroupName, vmName)}'
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
    testingResourceGroup
    defenderArc
  ]
}

output resourceGroupId string = testingResourceGroup.id
output defenderPricingStatus string = defenderArc.outputs.pricingTierStatus
output connectionInfo object = deployNestedHyperV ? {
  adminUsername: hyperVHost!.outputs.adminUsername
  deploymentMode: deploymentMode
  publicIpAddress: hyperVHost!.outputs.publicIpAddress
  rdpEndpoint: '${hyperVHost!.outputs.publicIpAddress}:3389'
  resourceGroupName: resourceGroupName
  vmId: hyperVHost!.outputs.vmId
  vmName: vmName
} : {
  adminUsername: adminUsername
  deploymentMode: deploymentMode
  publicIpAddress: quickTestVm!.outputs.publicIpAddress
  rdpEndpoint: '${quickTestVm!.outputs.publicIpAddress}:3389'
  resourceGroupName: resourceGroupName
  sqlAuthUsername: sqlAuthUsername
  vmId: quickTestVm!.outputs.vmId
  vmName: vmName
}
output nextSteps object = deployNestedHyperV ? {
  deploymentCommand: nestedDeploymentCommand
  steps: [
    'Connect to the Hyper-V host with RDP using ${adminUsername}@${hyperVHost!.outputs.publicIpAddress}:3389.'
    'After the first reboot from Hyper-V installation, run the follow-up PowerShell script to create the internal vSwitch and configure NAT for nested VMs.'
    'Create the nested SQL Server VM and onboard it to Azure Arc with the post-deployment PowerShell scripts.'
    'Verify Defender for SQL coverage for the Arc-connected SQL Server after onboarding completes.'
  ]
} : {
  deploymentCommand: quickTestDeploymentCommand
  steps: [
    'Connect to the quick-test SQL VM with RDP using ${adminUsername}@${quickTestVm!.outputs.publicIpAddress}:3389.'
    'Use your service principal credentials with the post-deployment PowerShell script to run azcmagent connect.'
    'Confirm the MSFT_ARC_TEST environment variable and Azure Connected Machine agent installation before onboarding.'
    'Verify Defender for SQL coverage after the VM appears as an Arc-enabled SQL Server.'
  ]
}
