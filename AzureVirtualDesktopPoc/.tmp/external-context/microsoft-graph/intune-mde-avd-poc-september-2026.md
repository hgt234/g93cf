---
source: Context7 API and Microsoft Learn
library: Microsoft Graph beta / Microsoft Intune / Microsoft Defender for Endpoint
package: microsoft-graph
topic: Automating Intune compliance, MDE EDR onboarding, and Microsoft 365 Apps for Windows for an Entra-joined Windows 11 24H2 AVD POC
tech_stack: Microsoft Graph beta, Intune, MDE, Entra ID, Azure Virtual Desktop
fetched: 2026-09-16T00:00:00Z
official_docs: https://learn.microsoft.com/en-us/graph/api/overview?view=graph-rest-beta
---

# Research result (current 2026-09-16)

Research only; no tenant calls or modifications were made. All requests below use `https://graph.microsoft.com/beta` and `Content-Type: application/json`.

## Important conclusions

1. The Intune objects can be created and assigned through Microsoft Graph beta.
2. Graph cannot bootstrap the Defender-for-Endpoint-to-Intune service-to-service trust. An administrator must first enable **Intune connection** in Microsoft Defender portal (`security.microsoft.com` > System > Settings > Endpoints > General > Advanced features). Connection status can take up to 15 minutes. Only after that does Intune receive the tenant-specific automatic onboarding package and expose **Auto from connector**.
3. `mobileThreatDefenseConnectors` can inspect the connector and update Intune-side Windows compliance/security-management toggles after the connector exists. Creating or patching that object is not a substitute for portal activation/consent in Defender.
4. A compliance policy marks devices noncompliant; actual resource denial normally also requires an Entra Conditional Access policy requiring a compliant device. The Graph enum also exposes `block` (“Block the device in AAD”), and each policy must have exactly one block scheduled action.
5. AVD Windows Enterprise multi-session supports only a subset of compliance checks. The safe POC payload below uses supported checks and avoids BitLocker, Secure Boot, TPM, code integrity, and storage encryption, which otherwise report Not applicable on multi-session. For single-session AVD, those checks can be evaluated separately.

## Permissions and prerequisites

| Area | Least Graph permission for writes | Read-only permission | Other prerequisites |
|---|---|---|---|
| Compliance policy/actions/assignment | `DeviceManagementConfiguration.ReadWrite.All` | `DeviceManagementConfiguration.Read.All` | Active Intune license; Intune RBAC rights for compliance policies |
| MDE connector | `DeviceManagementServiceConfig.ReadWrite.All` | `DeviceManagementServiceConfig.Read.All` | MDE and Intune licenses; existing portal-created service connection; Security Administrator/appropriate Defender rights for initial connection |
| EDR configuration policy | `DeviceManagementEndpointSecurity.ReadWrite.All` or `DeviceManagementConfiguration.ReadWrite.All` | `DeviceManagementEndpointSecurity.Read.All` or `DeviceManagementConfiguration.Read.All` | Active Intune/MDE licenses; endpoint-security RBAC; connector enabled for automatic package |
| Microsoft 365 Apps | `DeviceManagementApps.ReadWrite.All` | `DeviceManagementApps.Read.All` | Active Intune license; app must reach `publishingState=published`; users need suitable Microsoft 365 Apps licenses |

All listed application permissions require admin consent. Delegated calls also require the signed-in administrator's Intune RBAC scope/role; Graph OAuth permission alone does not override Intune RBAC.

AVD prerequisites: session hosts in an ARM-deployed host pool, same tenant as Intune, AVD agent >= 1.0.2944.1400, Entra joined with **Enroll the VM with Intune** enabled (or supported hybrid-join/device-credential enrollment), and never clone an already enrolled image. For multi-session, target device groups; user-targeted compliance isn't supported. Disable FSLogix identity-token roaming.

# 1. Windows 10/11 compliance policy

Target group: `76963e91-26ce-42c4-a4a6-00e113a406a7`.

## Create

`POST /deviceManagement/deviceCompliancePolicies`

Practical Windows 11 24H2 AVD multi-session payload:

```json
{
  "@odata.type": "#microsoft.graph.windows10CompliancePolicy",
  "displayName": "POC - AVD Windows 11 24H2 Compliance",
  "description": "Device-targeted compliance for Entra-joined Windows 11 24H2 AVD session hosts",
  "roleScopeTagIds": ["0"],
  "osMinimumVersion": "10.0.26100.0",
  "passwordRequired": true,
  "passwordBlockSimple": true,
  "passwordMinimumLength": 8,
  "passwordRequiredType": "alphanumeric",
  "activeFirewallRequired": true,
  "defenderEnabled": true,
  "signatureOutOfDate": true,
  "rtpEnabled": true,
  "antivirusRequired": true,
  "antiSpywareRequired": true,
  "deviceThreatProtectionEnabled": true,
  "deviceThreatProtectionRequiredSecurityLevel": "low"
}
```

`10.0.26100.0` enforces the 24H2 feature baseline, not a current monthly patch level. For patch enforcement, replace it with an organization-approved current `major.minor.build.revision`, or use `validOperatingSystemBuildRanges` and update the range monthly. Do not invent a future cumulative-update revision. The MDE risk fields need a connected MDE tenant and onboarded/reporting devices; deploy EDR first or expect initial noncompliance.

## Assign

`POST /deviceManagement/deviceCompliancePolicies/{policyId}/assign`

```json
{
  "assignments": [
    {
      "@odata.type": "#microsoft.graph.deviceCompliancePolicyAssignment",
      "target": {
        "@odata.type": "#microsoft.graph.groupAssignmentTarget",
        "groupId": "76963e91-26ce-42c4-a4a6-00e113a406a7"
      }
    }
  ]
}
```

Treat the `assign` action as replacement-style: include every assignment that should remain if rerunning it.

## Immediate block action

First discover the server-created scheduled-rule ID:

`GET /deviceManagement/deviceCompliancePolicies/{policyId}/scheduledActionsForRule?$expand=scheduledActionConfigurations`

Every policy must have exactly one block action. A new Intune compliance policy normally already has the immediate default action. Do not blindly add a duplicate. If absent:

`POST /deviceManagement/deviceCompliancePolicies/{policyId}/scheduledActionsForRule/{scheduledRuleId}/scheduledActionConfigurations`

```json
{
  "@odata.type": "#microsoft.graph.deviceComplianceActionItem",
  "gracePeriodHours": 0,
  "actionType": "block",
  "notificationTemplateId": "",
  "notificationMessageCCList": []
}
```

The beta enum describes `block` as “Block the device in AAD.” Current Intune guidance describes the built-in zero-day action as immediately marking the device noncompliant, after which Conditional Access blocks access. Therefore validate behavior in the POC and deploy a separate Conditional Access policy requiring compliant devices; an Intune compliance policy alone isn't a complete access-control boundary.

# 2. MDE connector and EDR onboarding

## Inspect the Intune-side connector

`GET /deviceManagement/mobileThreatDefenseConnectors`

Identify the Microsoft Defender for Endpoint connector by its tenant-created entry and inspect:

- `partnerState` (`enabled` is healthy; also check `lastHeartbeatDateTime`)
- `windowsEnabled` (MDE data used for Windows compliance)
- `windowsDeviceBlockedOnMissingPartnerData`
- `microsoftDefenderForEndpointAttachEnabled` (MDE security settings management, not the same thing as EDR onboarding)

## Update Intune-side toggles (only after portal activation)

`PATCH /deviceManagement/mobileThreatDefenseConnectors/{connectorId}`

Minimal merge-patch example:

```json
{
  "@odata.type": "#microsoft.graph.mobileThreatDefenseConnector",
  "windowsEnabled": true,
  "windowsDeviceBlockedOnMissingPartnerData": true,
  "microsoftDefenderForEndpointAttachEnabled": true
}
```

Use `windowsDeviceBlockedOnMissingPartnerData=true` only if fail-closed behavior is intended; newly onboarded or temporarily nonreporting hosts can become noncompliant. `microsoftDefenderForEndpointAttachEnabled` enables MDE security-settings-management/profile-management scenarios; it isn't required merely to manage already Intune-enrolled AVD hosts and MDE security settings management itself does not support AVD/nonpersistent desktops. Do not POST a synthetic connector to try to establish service trust.

## Portal-only prerequisite

No documented Microsoft Graph API enables the Defender portal's tenant-wide **Intune connection** advanced feature or performs the cross-service consent/bootstrap. Perform once in Defender portal. Then verify Intune's connection status is Enabled. Until this is done:

- Intune can't retrieve the tenant-specific MDE onboarding blob.
- **Auto from connector** isn't offered/accepted.
- An EDR policy using that choice can't successfully onboard devices.
- `deviceThreatProtection*` compliance settings have no MDE risk signal.

## Create a modern EDR endpoint-security policy

Microsoft's current endpoint-security API is the Graph beta settings-catalog model:

- Discover templates: `GET /deviceManagement/configurationPolicyTemplates?$filter=templateFamily eq 'endpointSecurityEndpointDetectionAndResponse'`
- Discover template settings: `GET /deviceManagement/configurationPolicyTemplates/{templateId}/settingTemplates?$expand=settingDefinitions`
- Catalog definitions if needed: `GET /deviceManagement/configurationSettings`
- Create: `POST /deviceManagement/configurationPolicies`
- Assign: `POST /deviceManagement/configurationPolicies/{policyId}/assignments`

Template IDs and template versions are service data, not a documented immutable constant. Resolve the current active Windows template in the target tenant instead of hard-coding a copied GUID. Likewise use the returned definition `id`, allowed choice values, and `@odata.type` from the live template. The commonly exposed definition/value pair for the package setting is:

- definition: `device_vendor_msft_policy_config_defender_configurationpackagetype`
- choice: `device_vendor_msft_policy_config_defender_configurationpackagetype_autofromconnector`

Validate those strings against the discovery response before POST because this is beta.

Payload after substituting the live IDs/types:

```json
{
  "@odata.type": "#microsoft.graph.deviceManagementConfigurationPolicy",
  "name": "POC - MDE EDR Auto Onboarding - AVD",
  "description": "Windows EDR onboarding using the automatic MDE connector package",
  "platforms": "windows10",
  "technologies": "mdm",
  "roleScopeTagIds": ["0"],
  "templateReference": {
    "templateId": "{LIVE_WINDOWS_EDR_TEMPLATE_ID}"
  },
  "settings": [
    {
      "@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
      "settingInstance": {
        "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
        "settingDefinitionId": "device_vendor_msft_policy_config_defender_configurationpackagetype",
        "choiceSettingValue": {
          "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingValue",
          "value": "device_vendor_msft_policy_config_defender_configurationpackagetype_autofromconnector",
          "children": []
        }
      }
    }
  ]
}
```

If the live template marks sample sharing as required, include its discovered setting too (typically choose All for a POC unless data-handling policy requires None). Don't configure deprecated expedited telemetry reporting.

Assignment to the same AVD device group:

`POST /deviceManagement/configurationPolicies/{policyId}/assignments`

```json
{
  "@odata.type": "#microsoft.graph.deviceManagementConfigurationPolicyAssignment",
  "target": {
    "@odata.type": "#microsoft.graph.groupAssignmentTarget",
    "groupId": "76963e91-26ce-42c4-a4a6-00e113a406a7"
  }
}
```

Legacy alternative `POST /deviceManagement/deviceConfigurations` with `#microsoft.graph.windowsDefenderAdvancedThreatProtectionConfiguration` exists, but it represents the older device-configuration profile. Prefer `configurationPolicies` for the current Endpoint security > Endpoint detection and response profile requested here.

# 3. Microsoft 365 Apps for Windows

The requested app device group ID was not supplied; substitute `{DEVICE_GROUP_ID}`. If it should be the same AVD group, use `76963e91-26ce-42c4-a4a6-00e113a406a7`.

## Create app

`POST /deviceAppManagement/mobileApps`

Practical pooled/shared AVD payload:

```json
{
  "@odata.type": "#microsoft.graph.officeSuiteApp",
  "displayName": "POC - Microsoft 365 Apps for enterprise - AVD",
  "description": "64-bit Microsoft 365 Apps for shared Windows 11 24H2 AVD session hosts",
  "publisher": "Microsoft",
  "owner": "Microsoft",
  "developer": "Microsoft",
  "isFeatured": false,
  "roleScopeTagIds": ["0"],
  "autoAcceptEula": true,
  "productIds": ["o365ProPlusRetail"],
  "excludedApps": {
    "@odata.type": "#microsoft.graph.excludedApps",
    "access": true,
    "bing": true,
    "excel": false,
    "groove": true,
    "infoPath": true,
    "lync": true,
    "oneDrive": false,
    "oneNote": false,
    "outlook": false,
    "powerPoint": false,
    "publisher": true,
    "sharePointDesigner": true,
    "teams": true,
    "visio": true,
    "word": false
  },
  "useSharedComputerActivation": true,
  "updateChannel": "monthlyEnterprise",
  "officeSuiteAppDefaultFileFormat": "officeOpenXMLFormat",
  "officePlatformArchitecture": "x64",
  "localesToInstall": ["en-us"],
  "installProgressDisplayLevel": "none",
  "shouldUninstallOlderVersionsOfOffice": true
}
```

`excludedApps=true` means exclude. Teams is intentionally excluded because current Teams deployment/licensing is separate; deploy the current Teams client separately if required. Shared Computer Activation is appropriate for pooled/multi-user AVD and still requires eligible per-user Microsoft 365 Apps licensing.

Poll `GET /deviceAppManagement/mobileApps/{mobileAppId}` until `publishingState` is `published`; an app can't be assigned while processing/not published.

## Required device-group assignment

Either use the assignment action (replacement-style):

`POST /deviceAppManagement/mobileApps/{mobileAppId}/assign`

```json
{
  "mobileAppAssignments": [
    {
      "@odata.type": "#microsoft.graph.mobileAppAssignment",
      "intent": "required",
      "target": {
        "@odata.type": "#microsoft.graph.groupAssignmentTarget",
        "groupId": "{DEVICE_GROUP_ID}"
      }
    }
  ]
}
```

Or create one assignment without replacing the whole assignment set:

`POST /deviceAppManagement/mobileApps/{mobileAppId}/assignments`

```json
{
  "@odata.type": "#microsoft.graph.mobileAppAssignment",
  "intent": "required",
  "target": {
    "@odata.type": "#microsoft.graph.groupAssignmentTarget",
    "groupId": "{DEVICE_GROUP_ID}"
  }
}
```

For Windows Enterprise multi-session, apps must install in system/device context, target devices, and use Required or Uninstall. Available isn't supported. The native Microsoft 365 Apps type uses Office CSP/system deployment and Required is suitable. Only one Microsoft 365 Apps deployment is supported per device. Remove legacy MSI Office, ensure Office apps are closed, allow Office CDN endpoints, and avoid conflicting update-channel/version settings in Settings Catalog.

# Caveats

- Beta contracts can change; prefer v1.0 where feature-equivalent, but this research records beta endpoints as requested.
- Dynamic group membership is eventually consistent, so assignment doesn't guarantee immediate device receipt.
- A zero-hour action applies when Intune next evaluates/checks in; “immediate” isn't instantaneous wall-clock enforcement.
- Entra Conditional Access evaluates users/sign-ins, not merely Intune assignment. Stage CA in report-only and exclude emergency accounts.
- EDR onboarding only enables MDE telemetry. It doesn't configure Defender AV, firewall, ASR, or advanced MDE workflows.
- Don't deploy duplicate onboarding policy types (legacy device configuration plus endpoint-security EDR) to the same hosts; policy conflicts can result.
- MDE security settings management explicitly doesn't support AVD/nonpersistent desktops, but Intune-enrolled AVD session hosts can receive supported Intune endpoint-security policies.
- Native Microsoft 365 Apps deployment during Autopilot ESP can conflict with concurrent Win32 installs; AVD multi-session doesn't support ESP anyway.

# Authoritative sources

- Compliance create: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-windows10compliancepolicy-create?view=graph-rest-beta
- Compliance resource: https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-windows10compliancepolicy?view=graph-rest-beta
- Compliance assign: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicy-assign?view=graph-rest-beta
- Scheduled rules: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancescheduledactionforrule-list?view=graph-rest-beta
- Action item create: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecomplianceactionitem-create?view=graph-rest-beta
- Action enum: https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-devicecomplianceactiontype?view=graph-rest-beta
- Noncompliance behavior: https://learn.microsoft.com/en-us/intune/device-security/compliance/configure-noncompliance-actions
- Windows compliance settings: https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-windows-settings
- MDE/Intune connection and onboarding: https://learn.microsoft.com/en-us/intune/device-security/microsoft-defender/configure-integration
- EDR policy: https://learn.microsoft.com/en-us/intune/device-configuration/endpoint-security/deploy-edr
- Connector list: https://learn.microsoft.com/en-us/graph/api/intune-onboarding-mobilethreatdefenseconnector-list?view=graph-rest-beta
- Connector update: https://learn.microsoft.com/en-us/graph/api/intune-onboarding-mobilethreatdefenseconnector-update?view=graph-rest-beta
- Connector resource: https://learn.microsoft.com/en-us/graph/api/resources/intune-onboarding-mobilethreatdefenseconnector?view=graph-rest-beta
- Configuration policy create: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-create?view=graph-rest-beta
- Configuration templates: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicytemplate-list?view=graph-rest-beta
- Setting definitions: https://learn.microsoft.com/en-us/graph/api/intune-deviceconfigv2-devicemanagementconfigurationsettingdefinition-list?view=graph-rest-beta
- Office app create: https://learn.microsoft.com/en-us/graph/api/intune-apps-officesuiteapp-create?view=graph-rest-beta
- Office app resource: https://learn.microsoft.com/en-us/graph/api/resources/intune-apps-officesuiteapp?view=graph-rest-beta
- Mobile app assign: https://learn.microsoft.com/en-us/graph/api/intune-apps-mobileapp-assign?view=graph-rest-beta
- Assignment create: https://learn.microsoft.com/en-us/graph/api/intune-apps-mobileappassignment-create?view=graph-rest-beta
- Microsoft 365 Apps deployment: https://learn.microsoft.com/en-us/intune/app-management/deployment/add-microsoft-365-windows
- AVD multi-session and Intune: https://learn.microsoft.com/en-us/intune/solutions/azure-virtual-desktop-multi-session
