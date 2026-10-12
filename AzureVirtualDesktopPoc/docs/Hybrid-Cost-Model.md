# 30-day AVD cost comparison

Keep hybrid economics separate from the Azure-hosted desktop. Run `scripts/Get-AvdPocCostComparison.ps1` with one consistent currency and current tenant/region-specific figures.

For the Azure standard personal desktop include VM runtime, managed disk, its allocated share of NAT Gateway/public IP/data-processing cost, and shared per-user licensing. For the Proxmox Hybrid GPU desktop include the quoted AVD Hybrid per-user service fee, shared user licensing, optional Azure Monitor ingestion, measured electricity, and allocated hardware depreciation. The hybrid row intentionally has no Azure VM, managed disk, NAT Gateway, Bastion, public IP, or VPN Gateway charge.

Measure Proxmox wall power at idle and under the representative graphics workload. Enter the expected load percentage and allocate only the share attributable to this VM. Treat sunk hardware cost and replacement/depreciation cost as separate scenarios if that distinction matters to the decision.

The Azure GPU alternative is optional. When used, estimate the chosen regional GPU VM, disk, network, and expected monthly schedule with the Azure Pricing Calculator and enter the combined 30-day figure. Do not reuse a standard D-series estimate for that row.

AVD Hybrid service pricing is a procurement gate: Microsoft currently directs customers to their account team for the tenant-specific per-user offer. A zero service-fee input keeps that gate visible in the generated JSON rather than implying the service is free.
