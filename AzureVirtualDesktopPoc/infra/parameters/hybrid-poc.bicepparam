using '../hybrid-main.bicep'

param pocId = 'POC01'
param location = 'centralus'
param resourceGroupName = 'rg-avd-hybrid-poc01'
param existingWorkspaceResourceGroupName = 'rg-avd-poc01'
param existingWorkspaceName = 'vdws-avd-poc01'
param tags = {
  CostCenter: 'AVD-POC'
  Owner: 'EUC'
}
