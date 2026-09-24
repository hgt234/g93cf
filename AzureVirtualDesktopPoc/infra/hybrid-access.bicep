targetScope = 'subscription'

metadata description = 'POC-scoped no-delete roles for AVD Hybrid onboarding and readiness.'

param pocId string
param resourceGroupName string
param deploymentPrincipalId string
param readinessPrincipalId string
param assignmentPrincipalId string

resource hybridResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

resource deploymentRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-hybrid-deployment')
  properties: {
    roleName: 'AVD Hybrid POC Deployment ${pocId}'
    description: 'Configure Arc extensions and AVD Hybrid registration without delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      hybridResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Resources/subscriptions/resourceGroups/read'
          'Microsoft.Resources/deployments/read'
          'Microsoft.Resources/deployments/write'
          'Microsoft.Resources/deployments/validate/action'
          'Microsoft.Resources/deployments/whatIf/action'
          'Microsoft.Resources/deployments/operations/read'
          'Microsoft.HybridCompute/machines/read'
          'Microsoft.HybridCompute/machines/write'
          'Microsoft.HybridCompute/machines/extensions/read'
          'Microsoft.HybridCompute/machines/extensions/write'
          'Microsoft.DesktopVirtualization/hostPools/read'
          'Microsoft.DesktopVirtualization/hostPools/write'
          'Microsoft.DesktopVirtualization/hostPools/retrieveRegistrationToken/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource readinessRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-hybrid-readiness')
  properties: {
    roleName: 'AVD Hybrid POC Readiness ${pocId}'
    description: 'Read Arc and AVD state and create or update fixed Arc Run Command checks. No delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      hybridResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.HybridCompute/machines/read'
          'Microsoft.HybridCompute/machines/extensions/read'
          'Microsoft.HybridCompute/machines/runCommands/read'
          'Microsoft.HybridCompute/machines/runCommands/write'
          'Microsoft.DesktopVirtualization/hostPools/read'
          'Microsoft.DesktopVirtualization/hostPools/sessionHosts/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource assignmentRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-hybrid-assignment')
  properties: {
    roleName: 'AVD Hybrid POC Assignment ${pocId}'
    description: 'Grant user access and assign an Available personal AVD Hybrid host. No delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      hybridResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Authorization/roleAssignments/read'
          'Microsoft.Authorization/roleAssignments/write'
          'Microsoft.HybridCompute/machines/read'
          'Microsoft.DesktopVirtualization/applicationGroups/read'
          'Microsoft.DesktopVirtualization/hostPools/read'
          'Microsoft.DesktopVirtualization/hostPools/sessionHosts/read'
          'Microsoft.DesktopVirtualization/hostPools/sessionHosts/write'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

module assignments './modules/hybrid-access-assignments.bicep' = {
  name: 'avd-hybrid-access-${uniqueString(hybridResourceGroup.id)}'
  scope: hybridResourceGroup
  params: {
    deploymentPrincipalId: deploymentPrincipalId
    readinessPrincipalId: readinessPrincipalId
    assignmentPrincipalId: assignmentPrincipalId
    deploymentRoleDefinitionId: deploymentRole.id
    readinessRoleDefinitionId: readinessRole.id
    assignmentRoleDefinitionId: assignmentRole.id
  }
}

output deploymentRoleDefinitionId string = deploymentRole.id
output readinessRoleDefinitionId string = readinessRole.id
output assignmentRoleDefinitionId string = assignmentRole.id
