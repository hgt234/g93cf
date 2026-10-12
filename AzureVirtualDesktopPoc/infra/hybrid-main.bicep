targetScope = 'subscription'

metadata description = 'Additive Azure foundation for AVD Hybrid session hosts running on Proxmox.'

@minLength(3)
@maxLength(12)
param pocId string

param location string = 'centralus'

param resourceGroupName string = 'rg-avd-hybrid-${toLower(pocId)}'

@description('Existing Azure-hosted AVD platform resource group containing the shared workspace.')
param existingWorkspaceResourceGroupName string

@description('Existing AVD workspace to which the hybrid desktop application group is added by the pipeline.')
param existingWorkspaceName string

param tags object = {}

var requiredTags = {
  ManagedBy: 'AzureVirtualDesktopPoc'
  PocId: pocId
  Environment: 'POC'
  HostingPlatform: 'Proxmox'
}

resource hybridResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: union(tags, requiredTags)
}

module hybridPlatform './modules/hybrid-platform.bicep' = {
  name: 'avd-hybrid-platform-${uniqueString(subscription().id, resourceGroupName)}'
  scope: hybridResourceGroup
  params: {
    location: location
    pocId: pocId
    tags: union(tags, requiredTags)
  }
}

output resourceGroupName string = hybridResourceGroup.name
output hostPoolName string = hybridPlatform.outputs.hostPoolName
output hostPoolId string = hybridPlatform.outputs.hostPoolId
output hostPoolPrincipalId string = hybridPlatform.outputs.hostPoolPrincipalId
output desktopAppGroupName string = hybridPlatform.outputs.desktopAppGroupName
output desktopAppGroupId string = hybridPlatform.outputs.desktopAppGroupId
output existingWorkspaceResourceGroupName string = existingWorkspaceResourceGroupName
output existingWorkspaceName string = existingWorkspaceName
