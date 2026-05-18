# k3s Homelab Cluster — OpenTofu Design

**Date:** 2026-05-16
**Status:** Approved, ready for implementation planning
**Author:** psmith@riskexec.com

## Goals

Provision a 3-node k3s cluster on a Proxmox homelab using OpenTofu, suitable
for both tinkering and gradually migrating an existing Docker-based media
stack onto Kubernetes.

OpenTofu's responsibility ends at "k3s cluster up, all nodes joined."
Cluster-level add-ons (MetalLB, Longhorn, SMB CSI, ingress configuration)
will be installed later via ArgoCD and are out of scope for this design.

## Non-goals

- HA control plane (single Proxmox host today; no resilience benefit)
- Multi-environment (prod/staging) layout — single homelab, YAGNI
- Cluster app deployment (ArgoCD will own that)
- Backup/snapshot automation (Proxmox-level snapshots are sufficient today)
- Secrets management (Vault/SOPS) — single-user homelab, env-local tfvars
  are sufficient
- Remote OpenTofu state backend — local state file is fine for one operator

## Environment

| Item | Value |
|---|---|
| Proxmox host | Dell R430, 2× 12-core Xeon (24c/48t), 190 GB RAM |
| Proxmox storage pool for VM disks | `storage` |
| Network bridge | `vmbr0` |
| LAN subnet | `192.168.50.0/24` |
| Gateway / DNS | `192.168.50.1` |
| VM template | Ubuntu 24.04, cloud-init configured with default user + SSH key, qemu-guest-agent baked in |
| Reserved IP block | `192.168.50.150–.159` |
| Bulk storage | SMB share (referenced later, not by OpenTofu) |
| Future expansion | Second Proxmox host with GPU access (not yet clustered) |

## Architecture

```
┌────────────────────────── Proxmox node (R430) ──────────────────────────┐
│                                                                          │
│   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐    │
│   │  k3s-server-01   │   │  k3s-agent-01    │   │  k3s-agent-02    │    │
│   │  192.168.50.150  │   │  192.168.50.151  │   │  192.168.50.152  │    │
│   │  4 vCPU / 8 GB   │   │  6 vCPU / 16 GB  │   │  6 vCPU / 16 GB  │    │
│   │  40 GB root      │   │  40 GB root      │   │  40 GB root      │    │
│   │                  │   │  + 100 GB data   │   │  + 100 GB data   │    │
│   │  control-plane   │   │   worker         │   │   worker         │    │
│   │  + embedded etcd │   │                  │   │                  │    │
│   └────────┬─────────┘   └────────┬─────────┘   └────────┬─────────┘    │
│            └──────────────────────┴──────────────────────┘              │
│                                   │                                      │
└───────────────────────────────────┼──────────────────────────────────────┘
                                    │ vmbr0 → 192.168.50.0/24
                                    │
                            192.168.50.1 — gateway / DNS
```

### IP allocation (`192.168.50.150–.159`)

| IP | Purpose |
|---|---|
| `.150` | `k3s-server-01` (control plane) |
| `.151` | `k3s-agent-01` (worker) |
| `.152` | `k3s-agent-02` (worker) |
| `.153` | Reserved for future GPU node (joins as worker w/ `gpu=true` label+taint) |
| `.154–.159` | MetalLB LoadBalancer pool (installed later via ArgoCD) |

### VM sizing rationale

The server is small because k3s control plane is lightweight. Workers are
generous (6 vCPU / 16 GB) so a media stack fits comfortably while leaving
~110 GB host RAM for other workloads. Sizes can be bumped later in
`terraform.tfvars`; a `tofu apply` will stop/resize/start the affected VMs.

## k3s configuration

- **Datastore:** embedded etcd (not sqlite). Keeps the door open for adding
  HA control plane members later with no data migration.
- **Ingress:** Traefik (k3s default) — enabled.
- **LoadBalancer controller:** ServiceLB / Klipper — **disabled**
  (`--disable=servicelb`) so MetalLB has clean ownership of `LoadBalancer`
  services after ArgoCD installs it.
- **Cluster token:** shared random secret in `terraform.tfvars` (gitignored),
  used as `K3S_TOKEN` on server and agents.

### Server install (k3s-server-01)

```bash
curl -sfL https://get.k3s.io | \
  K3S_TOKEN="<from tfvars>" \
  INSTALL_K3S_EXEC="server --cluster-init \
      --node-ip=192.168.50.150 \
      --tls-san=192.168.50.150 \
      --disable=servicelb \
      --write-kubeconfig-mode=644" \
  sh -
```

### Agent install (k3s-agent-NN)

```bash
# cloud-init polls for the server's :6443 before running this
curl -sfL https://get.k3s.io | \
  K3S_URL=https://192.168.50.150:6443 \
  K3S_TOKEN="<same as above>" \
  INSTALL_K3S_EXEC="agent --node-ip=<agent's IP>" \
  sh -
```

## Per-VM provisioning flow

1. **Clone from template** — full clone (independent VMs) into the `storage`
   pool, using the template's VMID from `terraform.tfvars`.
2. **Set CPU/RAM/disk** — per-role sizing. The template's small (~8 GB)
   virtio0 OS disk is grown to `root_disk_gb` via OpenTofu;
   `cloud-initramfs-growroot` in the template auto-extends the partition
   and filesystem on first boot. Workers also get a 100 GB blank scsi1
   disk for Longhorn (which ArgoCD will install later).
3. **Inject cloud-init user-data** (rendered from `.tftpl`):
   - hostname (default user account + SSH key are already baked into the template)
   - static IP / gateway / DNS via netplan (set by bpg provider's `ip_config`)
   - k3s install command (role-specific, see above)
4. **Start VM, wait for guest agent** — OpenTofu blocks until
   qemu-guest-agent reports an IP via the Proxmox API.
5. **cloud-init runs k3s install** on first boot. Agents have a polling
   loop that waits until the server's `:6443` is reachable. OpenTofu also
   uses `depends_on` so agents are created after the server resource.

## Project structure

```
d:\Homelab\
├── .gitignore
├── README.md
├── docs/superpowers/specs/        # this design lives here
└── tofu/
    ├── main.tf                    # provider config, module wiring
    ├── variables.tf
    ├── terraform.tfvars.example   # committed; documents required values
    ├── terraform.tfvars           # gitignored; real values + secrets
    ├── outputs.tf                 # node IPs, kubeconfig fetch instructions
    ├── versions.tf                # required_providers + tofu version
    ├── cloud-init/
    │   ├── server.yaml.tftpl
    │   └── agent.yaml.tftpl
    └── modules/
        └── k3s-node/
            ├── main.tf            # proxmox_virtual_environment_vm
            ├── variables.tf
            └── outputs.tf
```

### Key choices

- **One reusable `k3s-node` module**, called once for the server and twice
  (initially) for agents. The module hides Proxmox VM resource details; the
  root config decides "1 server, N agents."
- **Cloud-init templates as `.tftpl`** rendered via `templatefile()`. Keeps
  cloud-init readable as YAML rather than escaped strings inside `.tf` files.
- **Provider:** `bpg/proxmox` — most actively maintained Proxmox provider
  for Terraform/OpenTofu; supports template clone, cloud-init injection,
  and guest-agent IP reporting.
- **State:** local `terraform.tfstate` file, gitignored. Migration to a
  remote backend later is straightforward if needed.
- **Secrets:** `terraform.tfvars` gitignored, `.example` committed without
  values. No vault for now (YAGNI for one operator).

## Prerequisites

Operator must complete these once before the first `tofu apply`:

1. Install OpenTofu on workstation (`winget install OpenTofu.Tofu` or scoop).
2. Create Proxmox API token for OpenTofu (dedicated `tofu@pve` user, role
   with `VM.Allocate`, `VM.Clone`, `VM.Config.*`, `VM.Audit`, `VM.PowerMgmt`,
   `Datastore.AllocateSpace`, `Datastore.Audit`, `SDN.Use`).
3. Note SSH credentials for the Proxmox host. The bpg/proxmox provider
   uploads cloud-init snippet files over SSH (the Proxmox API doesn't
   support snippet uploads). Username + password go into `terraform.tfvars`
   as `proxmox_ssh_username` / `proxmox_ssh_password`; for security,
   prefer setting the password via the `TF_VAR_proxmox_ssh_password`
   environment variable rather than committing it.
4. Generate a k3s cluster token (random 64-char string) for tfvars.
5. Note the VM template's VMID from `qm list` for tfvars.

## qemu-guest-agent, default user, SSH key

`qemu-guest-agent` is baked into the template (auto-starts on boot), so
the OpenTofu cloud-init user-data does NOT install it.

SSH user + key handling is more involved than it looks. The template
ships with a default user and authorized SSH key configured via
cloud-init. But because the OpenTofu module sets `user_data_file_id`
(needed to inject the k3s install command), Proxmox replaces the
auto-generated cloud-init user-data with our custom file. Proxmox's
`ciuser`/`sshkeys` parameters are then **ignored** — cloud-init only
reads what's in our user-data file.

Two consequences:
- The cloud-init YAML MUST contain a `users:` block that creates the
  user and installs `ssh_public_key`, or SSH login fails.
- `initialization.user_account` in the bpg provider is set as
  belt-and-suspenders (and so `qm config <vmid>` reports useful
  values), but functionally only the `users:` block in our user-data
  matters.

The values come from `ssh_user` and `ssh_public_key` in
`terraform.tfvars`.

## Day-2 operations the design supports

| Action | How |
|---|---|
| Add a worker | Append to `agents` list in tfvars; `tofu apply` |
| Resize a node | Edit CPU/RAM in tfvars; `tofu apply` (stops/resizes/starts the VM) |
| Add the GPU node as a worker | New `agents` entry with `target_node` set to the GPU host plus `labels=["gpu=true"]` and `taints=["gpu=true:NoSchedule"]`. Requires Proxmox cluster, or manage GPU node out-of-band with `k3s agent` and exclude from tofu. |
| Destroy & rebuild | `tofu destroy` then `tofu apply`. Cluster state is wiped — fine while iterating, but cluster-app data on Longhorn would be lost. |

## Out of scope (handled later, not by OpenTofu)

- MetalLB install/config (ArgoCD)
- Longhorn install/config (ArgoCD; will claim the 100 GB second disk on each worker)
- SMB CSI driver for media share (ArgoCD)
- Ingress route definitions (ArgoCD)
- Cluster backups beyond Proxmox VM snapshots
