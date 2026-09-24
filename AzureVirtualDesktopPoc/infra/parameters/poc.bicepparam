using '../main.bicep'

param pocId = 'POC01'
param location = 'centralus'
param resourceGroupName = 'rg-avd-poc01'
param vnetAddressPrefix = '10.80.0.0/16'
param sessionHostSubnetPrefix = '10.80.1.0/24'
param imageBuilderSubnetPrefix = '10.80.2.0/24'
param imageBuilderAciSubnetPrefix = '10.80.3.0/24'
param tags = {
  CostCenter: 'AVD-POC'
  Owner: 'EUC'
}
