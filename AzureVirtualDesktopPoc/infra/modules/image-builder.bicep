metadata description = 'Azure Image Builder template producing a generalized Windows 11 Enterprise Compute Gallery image.'

param pocId string
param location string
param imageBuilderSubnetId string
param imageBuilderAciSubnetId string
param customizationScriptUri string
param customizationScriptSha256 string
param stagingResourceGroupId string
param imageBuilderRoleDefinitionId string
param tags object

var suffix = toLower(pocId)
var identityName = 'id-aib-avd-${suffix}'
var galleryName = 'acgavd${replace(suffix, '-', '')}'
var imageDefinitionName = 'win11-avd-personal'
var imageTemplateName = 'aib-win11-avd-${suffix}'

resource imageBuilderIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource imageBuilderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, imageBuilderIdentity.id, imageBuilderRoleDefinitionId)
  properties: {
    roleDefinitionId: imageBuilderRoleDefinitionId
    principalId: imageBuilderIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: galleryName
  location: location
  tags: tags
  properties: {
    description: 'Versioned Windows 11 images for the AVD POC.'
  }
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: imageDefinitionName
  location: location
  tags: tags
  properties: {
    osType: 'Windows'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    architecture: 'x64'
    identifier: {
      publisher: 'Corporate'
      offer: 'AVD'
      sku: 'Windows11-24H2-Personal'
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunchSupported'
      }
    ]
  }
}

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: imageTemplateName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${imageBuilderIdentity.id}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: 180
    stagingResourceGroup: stagingResourceGroupId
    vmProfile: {
      vmSize: 'Standard_D4s_v6'
      osDiskSizeGB: 128
      vnetConfig: {
        subnetId: imageBuilderSubnetId
        containerInstanceSubnetId: imageBuilderAciSubnetId
      }
    }
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'windows-11'
      sku: 'win11-24h2-ent'
      version: 'latest'
    }
    customize: [
      {
        type: 'PowerShell'
        name: 'CorporateBaseline'
        scriptUri: customizationScriptUri
        sha256Checksum: customizationScriptSha256
        runElevated: true
        runAsSystem: true
      }
      {
        type: 'WindowsRestart'
        name: 'RestartAfterBaseline'
        restartCommand: 'shutdown /r /f /t 0'
        restartCheckCommand: 'powershell -NoProfile -Command "if (-not (Test-Path C:\\ProgramData\\AvdImage\\baseline.complete)) { exit 1 }"'
        restartTimeout: '15m'
      }
      {
        type: 'WindowsUpdate'
        name: 'ApplyWindowsUpdates'
        searchCriteria: 'IsInstalled=0'
        filters: [
          'exclude:$_.Title -like \'*Preview*\''
          'include:$true'
        ]
        updateLimit: 60
      }
    ]
    optimize: {
      vmBoot: {
        state: 'Enabled'
      }
    }
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: imageDefinition.id
        runOutputName: 'win11-avd-${suffix}'
        replicationRegions: [
          location
        ]
        excludeFromLatest: false
        artifactTags: union(tags, {
          Source: 'AzureImageBuilder'
          BaseImage: 'MicrosoftWindowsDesktop/windows-11/win11-24h2-ent/latest'
        })
      }
    ]
  }
  dependsOn: [
    imageBuilderRoleAssignment
  ]
}

output imageTemplateName string = imageTemplate.name
output galleryName string = gallery.name
output imageDefinitionName string = imageDefinition.name
output imageDefinitionId string = imageDefinition.id
