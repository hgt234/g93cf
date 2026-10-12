targetScope = 'subscription'

metadata description = 'Additive AVD POC platform deployment. Destruction is intentionally handled outside Bicep.'

@description('Short immutable identifier used in names and the teardown safety tag.')
@minLength(3)
@maxLength(12)
param pocId string

@description('Azure region for all regional resources.')
param location string = 'centralus'

@description('Dedicated resource group. Do not place shared or production resources here.')
param resourceGroupName string = 'rg-avd-${toLower(pocId)}'

@description('Address space for the POC virtual network.')
param vnetAddressPrefix string = '10.80.0.0/16'

@description('Private session-host subnet. Outbound access is provided by NAT Gateway.')
param sessionHostSubnetPrefix string = '10.80.1.0/24'

@description('Private Azure Image Builder subnet sharing the NAT Gateway.')
param imageBuilderSubnetPrefix string = '10.80.2.0/24'

@description('Private delegated subnet for the Azure Image Builder container instance.')
param imageBuilderAciSubnetPrefix string = '10.80.3.0/24'

@description('Optional additional tags.')
param tags object = {}

var requiredTags = {
  ManagedBy: 'AzureVirtualDesktopPoc'
  PocId: pocId
  Environment: 'POC'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: union(tags, requiredTags)
}

module platform './modules/platform.bicep' = {
  name: 'avd-platform-${uniqueString(subscription().id, resourceGroupName)}'
  scope: resourceGroup
  params: {
    location: location
    pocId: pocId
    vnetAddressPrefix: vnetAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    imageBuilderSubnetPrefix: imageBuilderSubnetPrefix
    imageBuilderAciSubnetPrefix: imageBuilderAciSubnetPrefix
    tags: union(tags, requiredTags)
  }
}

output resourceGroupName string = resourceGroup.name
output hostPoolName string = platform.outputs.hostPoolName
output desktopAppGroupName string = platform.outputs.desktopAppGroupName
output desktopAppGroupId string = platform.outputs.desktopAppGroupId
output sessionHostSubnetId string = platform.outputs.sessionHostSubnetId
output imageBuilderSubnetId string = platform.outputs.imageBuilderSubnetId
output imageBuilderAciSubnetId string = platform.outputs.imageBuilderAciSubnetId
output natGatewayName string = platform.outputs.natGatewayName
