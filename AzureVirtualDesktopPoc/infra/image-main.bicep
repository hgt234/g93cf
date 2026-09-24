targetScope = 'subscription'

metadata description = 'Additive Azure Image Builder and Compute Gallery foundation for the AVD POC.'

param pocId string
param location string = 'centralus'
param resourceGroupName string
param imageBuilderSubnetId string
param imageBuilderAciSubnetId string
param customizationScriptUri string

@description('SHA-256 checksum for the immutable customization script content.')
@minLength(64)
@maxLength(64)
param customizationScriptSha256 string

param stagingResourceGroupName string = 'rg-avd-${toLower(pocId)}-aib-stage'
param tags object = {}

resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

resource imageBuilderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, resourceGroupName, 'avd-poc-image-builder', pocId)
  properties: {
    roleName: 'AVD POC Image Builder ${pocId}'
    description: 'Create Compute Gallery image versions and join the private build subnet. Contains no delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      targetResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

module image './modules/image-builder.bicep' = {
  name: 'avd-image-builder-${uniqueString(subscription().id, resourceGroupName)}'
  scope: targetResourceGroup
  params: {
    pocId: pocId
    location: location
    imageBuilderSubnetId: imageBuilderSubnetId
    imageBuilderAciSubnetId: imageBuilderAciSubnetId
    customizationScriptUri: customizationScriptUri
    customizationScriptSha256: customizationScriptSha256
    stagingResourceGroupId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${stagingResourceGroupName}'
    imageBuilderRoleDefinitionId: imageBuilderRole.id
    tags: union(tags, {
      ManagedBy: 'AzureVirtualDesktopPoc'
      PocId: pocId
      Environment: 'POC'
    })
  }
}

output imageTemplateName string = image.outputs.imageTemplateName
output galleryName string = image.outputs.galleryName
output imageDefinitionName string = image.outputs.imageDefinitionName
output imageDefinitionId string = image.outputs.imageDefinitionId
output stagingResourceGroupName string = stagingResourceGroupName
output imageBuilderRoleDefinitionId string = imageBuilderRole.id
