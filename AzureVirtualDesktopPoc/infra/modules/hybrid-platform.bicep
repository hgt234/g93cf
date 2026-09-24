metadata description = 'Personal AVD Hybrid host pool for persistent Proxmox Windows 11 session hosts.'

param location string
param pocId string
param tags object

var suffix = toLower(pocId)
var hostPoolName = 'vdpool-avd-hybrid-${suffix}'
var appGroupName = 'vdag-avd-hybrid-${suffix}'
var readerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
)

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hostPoolType: 'Personal'
    personalDesktopAssignmentType: 'Direct'
    loadBalancerType: 'Persistent'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: 1
    validationEnvironment: false
    startVMOnConnect: false
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1;redirectclipboard:i:1;redirectprinters:i:1;'
  }
}

resource hostPoolReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, hostPool.id, readerRoleDefinitionId)
  properties: {
    principalId: hostPool.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleDefinitionId
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    description: 'Personal GPU desktop application group for AVD Hybrid ${pocId}'
    friendlyName: 'AVD Hybrid GPU ${pocId}'
  }
}

output hostPoolName string = hostPool.name
output hostPoolId string = hostPool.id
output hostPoolPrincipalId string = hostPool.identity.principalId
output desktopAppGroupName string = desktopAppGroup.name
output desktopAppGroupId string = desktopAppGroup.id
