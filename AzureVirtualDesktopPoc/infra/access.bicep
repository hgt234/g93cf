targetScope = 'subscription'

metadata description = 'POC-scoped, no-delete custom roles for AVD session-host automation.'

param pocId string
param resourceGroupName string

@description('Object ID of the workload identity used to deploy session hosts.')
param deploymentPrincipalId string

@description('Object ID of the workload identity used for readiness checks.')
param readinessPrincipalId string

@description('Object ID of the workload identity used for final user assignment.')
param assignmentPrincipalId string

resource pocResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

resource deploymentRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-deployment')
  properties: {
    roleName: 'AVD POC Deployment ${pocId}'
    description: 'Deploy or update private session hosts and obtain AVD registration tokens. No delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      pocResourceGroup.id
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
          'Microsoft.Resources/deployments/operationStatuses/read'
          'Microsoft.Compute/*/read'
          'Microsoft.Compute/virtualMachines/write'
          'Microsoft.Compute/virtualMachines/extensions/write'
          'Microsoft.Compute/disks/write'
          'Microsoft.Network/*/read'
          'Microsoft.Network/networkInterfaces/write'
          'Microsoft.Network/networkInterfaces/join/action'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
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
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-readiness')
  properties: {
    roleName: 'AVD POC Readiness ${pocId}'
    description: 'Read AVD/VM state and run the required-app inventory command. No delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      pocResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/*/read'
          'Microsoft.Compute/virtualMachines/runCommand/action'
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
  name: guid(subscription().id, resourceGroupName, pocId, 'avd-assignment')
  properties: {
    roleName: 'AVD POC Assignment ${pocId}'
    description: 'Grant user access and assign an Available personal session host. No delete actions.'
    type: 'CustomRole'
    assignableScopes: [
      pocResourceGroup.id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Authorization/roleAssignments/read'
          'Microsoft.Authorization/roleAssignments/write'
          'Microsoft.Compute/virtualMachines/read'
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

module roleAssignments './modules/access-assignments.bicep' = {
  name: 'avd-access-assignments-${uniqueString(pocResourceGroup.id)}'
  scope: pocResourceGroup
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
