---
source: Microsoft Learn (official Azure documentation)
library: Azure Virtual Machines
package: azure-vm-sizes
topic: D4s v6/v5 and E4bds/E4bs v5 disk-controller, Gen2, and Trusted Launch compatibility
tech_stack: Azure Compute Gallery; Windows 11 24H2
fetched: 2026-09-17T00:00:00Z
official_docs: https://learn.microsoft.com/en-us/azure/virtual-machines/ebdsv5-ebsv5-series
---

# Verified compatibility facts

| VM size | Remote disk controller support | Generation support | Relevant specifications |
|---|---|---|---|
| `Standard_D4s_v6` | **NVMe** (D/E v6 is NVMe, not SCSI) | **Gen2 only** | 4 vCPU, 16 GiB; Dsv6 feature table says Gen2 supported and Gen1 not supported. |
| `Standard_D4s_v5` | **SCSI** | **Gen1 and Gen2** | 4 vCPU, 16 GiB; Dsv5 feature table supports both generations. |
| `Standard_E4bds_v5` | **SCSI and NVMe**; SCSI is explicitly supported on Gen1 and Gen2 | **Gen1 and Gen2** | 4 vCPU, 32 GiB, 150-GiB local temporary SSD, 8 data disks. |
| `Standard_E4bs_v5` | **SCSI and NVMe**; SCSI is explicitly supported on Gen1 and Gen2 | **Gen1 and Gen2** | 4 vCPU, 32 GiB, no local temporary SSD, 8 data disks. |

Microsoft's migration guide states directly: **D/E v5 disk controller type: SCSI; D/E v6 and v7 disk controller type: NVMe**. It also warns that v6 VMs require NVMe enablement, a supported OS, and Gen2.

# Trusted Launch and Windows 11

- Trusted Launch is for Gen2 VMs.
- Microsoft's current support table includes both the **E-family** and **Eb-family** among Trusted Launch-supported memory-optimized size families.
- Windows 11 Enterprise is listed as a supported Trusted Launch OS, and Windows 11 is also listed among supported NVMe OS images.
- Therefore `Standard_E4bds_v5` and `Standard_E4bs_v5` meet the documented size-family, Gen2, and OS requirements for Trusted Launch.

# Conclusion for the gallery image

`Standard_E4bds_v5` is a compatible SCSI replacement for a Gen2/Trusted Launch Windows 11 gallery image whose image definition is SCSI-only. It does not force an NVMe boot path, unlike `Standard_D4s_v6`. Deployment still depends on regional SKU capacity and subscription quota.

The likely better 4-vCPU choice is **`Standard_E4bs_v5`** unless the workload needs ephemeral local SSD: it has the same 4 vCPU, 32 GiB RAM, disk count, remote-storage limits, SCSI/NVMe support, Gen2 support, and Trusted Launch family eligibility as `E4bds_v5`, but omits the 150-GiB temporary disk. Azure documents Ebdsv5 and Ebsv5 together as one Eb v5 offering; confirm in the Central US size picker/quota blade that the subscription's displayed EBDSv5 quota covers the exact `E4bs_v5` SKU.

# Image-controller metadata

Azure says an NVMe VM can be created only from an image tagged for NVMe. For Azure Compute Gallery, the documented image-definition feature is `DiskControllerTypes=SCSI,NVMe`. A SCSI-only image definition can therefore be rejected for `D4s_v6`, even though Windows 11 itself has NVMe OS-image support. Rebuilding/validating an NVMe-capable gallery definition is the alternative if Dsv6 is required.

# Official sources

- Ebdsv5/Ebsv5 specifications and explicit SCSI/NVMe/Gen1/Gen2 support: https://learn.microsoft.com/en-us/azure/virtual-machines/ebdsv5-ebsv5-series
- Dsv6 size and Gen2-only feature table: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv6-series
- Dsv5 size and Gen1/Gen2 feature table: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv5-series
- Official migration table identifying D/E v5 as SCSI and D/E v6 as NVMe: https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/d-ds-dv2-dsv2-ls-series-migration-guide
- Trusted Launch supported families and Windows 11 support: https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch
- Gen2 architecture and controller facts: https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2
- NVMe image tagging and gallery `DiskControllerTypes=SCSI,NVMe`: https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-remote-faqs
- Current Windows NVMe OS support list: https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface
