targetScope = 'subscription'

@description('Pricing tier for Defender for SQL plans.')
@allowed([
  'Standard'
])
param pricingTier string = 'Standard'

resource sqlServersPricing 'Microsoft.Security/pricings@2023-05-01-preview' = {
  name: 'SqlServers'
  properties: {
    pricingTier: pricingTier
  }
}

resource sqlServerVirtualMachinesPricing 'Microsoft.Security/pricings@2023-05-01-preview' = {
  name: 'SqlServerVirtualMachines'
  properties: {
    pricingTier: pricingTier
  }
}

output currentPricingStatus object = {
  SqlServers: sqlServersPricing.properties.pricingTier
  SqlServerVirtualMachines: sqlServerVirtualMachinesPricing.properties.pricingTier
}
