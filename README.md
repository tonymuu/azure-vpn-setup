# Azure VPN VM infrastructure

An interactive Bash script that creates a low-cost Debian 12 Azure VM and its network for a VPN you install yourself. It does **not** install WireGuard or OpenVPN, configure guest routing/NAT/DNS, or generate client profiles.

## Run

Open the project directory in Linux, WSL, or Azure Cloud Shell and run:

```bash
bash create-vpn-vm.sh
```

Use Bash 4 or newer, a current Azure CLI, `jq` 1.6 or newer, `curl`, and standard Linux utilities. The script checks prerequisites; it does not install software. Azure Cloud Shell normally supplies Azure CLI and the JSON/network tools. A Windows PowerShell session or a WSL installation without a Linux distribution is not a Linux execution environment.

If necessary, sign in with `az login`; the script also offers the normal Azure CLI login flow when no enabled subscriptions are found. Your account needs permission to create/delete resource groups and the compute, network, disk, tagging, and VM shutdown-schedule resources in the selected subscription. Regional policy, quota, and capacity restrictions still apply.

There are **no command-line parameters**, saved previous answers, unattended mode, or confirmation bypass. Every deployment requires interactive confirmation after the full configuration summary. Declining or ending input before confirmation creates no Azure resources.

## Prompts and defaults

| Choice | Behavior/default |
|---|---|
| Subscription | Lists enabled subscriptions; select one |
| Resource group | Your name; must not already exist |
| VM name | Your name; companion resource names are derived |
| Region | `westus2` (West US 2, Washington), overridable |
| VPN network preset | Exactly one of WireGuard or OpenVPN |
| WireGuard port | UDP `51820`, overridable |
| OpenVPN port/transport | UDP `1194`, port and UDP/TCP overridable |
| SSH username | `sjp`, overridable |
| Network | Dedicated IPv4 VNet/subnet, suggested `10.80.0.0/16` and `10.80.0.0/24`; overridable private ranges |
| VM size | Choose from up to six low-cost compatible sizes, or enter a validated size manually |
| OS disk | Standard SSD LRS, image minimum capacity; larger sizes allowed |

Choose guest VPN settings matching the selected port and transport when you install your server. TCP 22 is reserved for SSH.

## Fixed settings

- Official **Debian 12** only. Image availability is discovered in the selected region, and a concrete version is pinned before deployment. There is no fallback to another release.
- Both **x86-64 and ARM64** are considered when image architecture, VM generation/controller capabilities, subscription restrictions, and reported CPU quota match. Install software compatible with the selected architecture.
- Regular on-demand priority only, never Spot.
- One persistent **Standard SSD LRS** OS disk; no extra data disks.
- Static Standard public IPv4 attached directly to the NIC. The subnet disables default outbound access; its explicit public IP provides connectivity without a NAT Gateway.
- Inbound SSH TCP 22 and the selected VPN port are allowed from **all IPv4 addresses** (`0.0.0.0/0`), as requested. The other VPN preset is not opened.
- Password SSH authentication is disabled. This exact key is configured for the selected administrator:

  ```text
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4l1+Vz1OgxgiyVcdxGXYdqMPIeY2BY9TaafOuMx2rj
  ```

  No key pair is generated, and the script never asks for or reads your private key. You need the corresponding private key to connect yourself.
- VM auto-shutdown is explicitly disabled, and any shutdown schedules targeting the VM are read back. An absent schedule also means no configured shutdown schedule.
- No backup vaults, snapshots, extra data disks, load balancers, NAT Gateways, Bastion, paid log workspaces, availability sets, replica VMs, or optional availability zones are requested.

Unmanaged disks have been retired. LRS retains local storage replication; it is not zero redundancy. Public IPs can also have platform-assigned zone redundancy; the script reports returned zones instead of claiming redundancy is disabled everywhere.

Disabling auto-shutdown cannot prevent policy enforcement, external automation, manual shutdown, platform maintenance, or outages. Policy conflicts and unexpected backup/HA/monitoring resources are reported, not bypassed or silently removed.

## Pricing and sizing

The shortlist uses Azure's public Retail Prices API, follows pagination, and matches regular Linux on-demand USD meters to eligible VM SKUs. It excludes Windows, paid-distribution, Spot, low-priority, and commitment prices. The shortlist focuses on small VMs (up to 4 vCPU / 8 GiB) and sorts by compute price; it is not a claim of the cheapest possible deployment across Azure.

Each entry shows architecture, vCPU, RAM, hourly compute price and a **730-hour monthly illustration**. Prices are not a subscription-specific quote. If prices cannot be fetched, the script warns and allows an explicit compatible VM size without claiming an estimate.

**Compute prices exclude OS disk capacity, disk operations, public IPv4, outbound bandwidth, and tax.** Smaller requested disks still use Azure capacity billing tiers. Public IPv4 and disk resources can continue to cost money when a VM is stopped/deallocated.

The target is one user doing light browsing or video calls. Burstable VMs can exhaust CPU credits and throttle; OpenVPN may require more CPU than WireGuard. Specifications and retail prices do not guarantee VPN throughput. Reported quota and SKU eligibility do not guarantee allocation capacity.

## Completion and failures

The script reports the public IPv4, an SSH command, the selected VPN network preset, and the opened port. It reads back the Azure VM image/key configuration, disk, network rules, IP association, and shutdown schedules. It does not use VM extensions to test the guest, read a private key, or claim that SSH/VPN connectivity has been tested.

Existing resource groups are rejected. Do not run concurrent deployments using the same resource group/name: Azure resource creates are not a transactional lock. Preflight and before-create checks reduce collision risk; allocation failures never silently switch region, architecture, or size.

Created resources receive a unique `vpnProvisionRun` ownership tag. A failed deployment prints the resource inventory and offers cleanup:

- Cleanup requires an additional interactive confirmation and checks current ownership.
- VM disk/NIC deletion settings are `Detach`; cleanup handles verified resources explicitly rather than cascading deletes.
- Unknown/unowned resources, unexpected child resources, and resources whose ownership cannot be verified are retained.
- The group is deleted only when verified run-owned and empty. Otherwise its remaining resource IDs are reported.
- A disk left behind by a failed/ambiguous VM creation may be untagged and will be retained rather than guessed to be safe to delete.
- If input is interrupted, cleanup cannot be confirmed, or Azure is unavailable, resources may remain billable. Inspect the reported resource group and inventory.

The script does not adopt or repair previous deployments on a rerun. Choose a new resource group or inspect/clean up the previous run yourself.

## Local checks

```bash
bash -n create-vpn-vm.sh
bash tests/run.sh
```

The test harness uses in-process fake Azure CLI and price-feed functions. It exercises the real prompt/confirmation/provisioning workflow without Azure access or charges, including cancellation, incompatible images, manual sizing, pricing failures, exact key injection, shutdown state, and ownership-aware cleanup.

An end-to-end live deployment and an authorized guest SSH smoke test require your Azure account and incur charges. They are not performed by the local checks.
