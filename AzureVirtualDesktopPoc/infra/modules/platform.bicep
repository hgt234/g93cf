metadata description = 'Shared AVD POC platform with explicit NAT Gateway egress and no VM public IPs.'

param location string
param pocId string
param vnetAddressPrefix string
param sessionHostSubnetPrefix string
param imageBuilderSubnetPrefix string
param imageBuilderAciSubnetPrefix string
param tags object

var suffix = toLower(pocId)
var vnetName = 'vnet-avd-${suffix}'
var subnetName = 'snet-sessionhosts'
var imageBuilderSubnetName = 'snet-imagebuilder'
var imageBuilderAciSubnetName = 'snet-imagebuilder-aci'
var nsgName = 'nsg-avd-sessionhosts-${suffix}'
var natName = 'nat-avd-${suffix}'
var natPublicIpName = 'pip-nat-avd-${suffix}'
var hostPoolResourceName = 'vdpool-avd-${suffix}'
var appGroupName = 'vdag-avd-${suffix}'
var workspaceName = 'vdws-avd-${suffix}'

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: natPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource sessionHostNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource sessionHostSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: sessionHostSubnetPrefix
    defaultOutboundAccess: false
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: sessionHostNsg.id
    }
  }
}

resource imageBuilderSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: imageBuilderSubnetName
  dependsOn: [
    sessionHostSubnet
  ]
  properties: {
    addressPrefix: imageBuilderSubnetPrefix
    defaultOutboundAccess: false
    privateLinkServiceNetworkPolicies: 'Disabled'
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: sessionHostNsg.id
    }
  }
}

resource imageBuilderAciSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: imageBuilderAciSubnetName
  dependsOn: [
    imageBuilderSubnet
  ]
  properties: {
    addressPrefix: imageBuilderAciSubnetPrefix
    defaultOutboundAccess: false
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: sessionHostNsg.id
    }
    delegations: [
      {
        name: 'AzureContainerInstances'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolResourceName
  location: location
  tags: tags
  properties: {
    hostPoolType: 'Personal'
    personalDesktopAssignmentType: 'Direct'
    loadBalancerType: 'Persistent'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: 1
    validationEnvironment: true
    startVMOnConnect: false
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1;redirectclipboard:i:1;redirectprinters:i:1;'
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    description: 'Personal desktop application group for ${pocId}'
    friendlyName: 'AVD ${pocId} Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    applicationGroupReferences: [
      desktopAppGroup.id
    ]
    description: 'AVD proof-of-concept workspace for ${pocId}'
    friendlyName: 'AVD ${pocId}'
  }
}

output hostPoolName string = hostPool.name
output desktopAppGroupName string = desktopAppGroup.name
output desktopAppGroupId string = desktopAppGroup.id
output sessionHostSubnetId string = sessionHostSubnet.id
output imageBuilderSubnetId string = imageBuilderSubnet.id
output imageBuilderAciSubnetId string = imageBuilderAciSubnet.id
output natGatewayName string = natGateway.name
