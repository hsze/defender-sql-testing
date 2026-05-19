targetScope = 'subscription'

@description('Pricing tier for Microsoft Defender for SQL Server virtual machines and Arc-enabled SQL Server resources.')
@allowed([
  'Standard'
])
param pricingTier string = 'Standard'

@description('Subscription-level Defender for SQL Server virtual machines pricing configuration.')
resource sqlServerVirtualMachinesPricing 'Microsoft.Security/pricings@2023-05-01-preview' = {
  name: 'SqlServerVirtualMachines'
  properties: {
    pricingTier: pricingTier
  }
}

output pricingTierStatus string = sqlServerVirtualMachinesPricing.properties.pricingTier
