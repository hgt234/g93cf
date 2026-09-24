metadata description = 'Resource-group scoped assignments for AVD Hybrid workload identities.'

param deploymentPrincipalId string
param readinessPrincipalId string
param assignmentPrincipalId string
param deploymentRoleDefinitionId string
param readinessRoleDefinitionId string
param assignmentRoleDefinitionId string

resource deploymentAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentPrincipalId, deploymentRoleDefinitionId)
  properties: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: deploymentRoleDefinitionId
  }
}

resource readinessAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, readinessPrincipalId, readinessRoleDefinitionId)
  properties: {
    principalId: readinessPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readinessRoleDefinitionId
  }
}

resource assignmentAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, assignmentPrincipalId, assignmentRoleDefinitionId)
  properties: {
    principalId: assignmentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: assignmentRoleDefinitionId
  }
}
