# k3s Cluster OpenTofu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap a 3-node k3s cluster (1 server + 2 agents) on a single Proxmox node using OpenTofu, with cloud-init handling k3s install.

**Architecture:** OpenTofu (bpg/proxmox provider) clones an Ubuntu 24.04 template three times. cloud-init user-data, rendered from templates, installs `qemu-guest-agent` and runs the role-appropriate k3s install command on first boot. Agents poll the server's `:6443` before joining. After `tofu apply`, the cluster is up and reachable; MetalLB/Longhorn/ingress come later via ArgoCD (out of scope here).

**Tech Stack:** OpenTofu, bpg/proxmox provider, cloud-init, k3s (embedded etcd, Traefik enabled, ServiceLB disabled).

**Spec:** [docs/superpowers/specs/2026-05-16-k3s-cluster-opentofu-design.md](../specs/2026-05-16-k3s-cluster-opentofu-design.md)

**Note on commits:** Per project convention, this plan does NOT include `git commit` steps. The operator commits at their own pace; checkpoints in the plan are natural commit boundaries if desired.

**Note on TDD:** OpenTofu is declarative IaC, not testable via unit tests. Verification gates are `tofu fmt -check`, `tofu validate`, `tofu plan` review, and final `tofu apply` followed by `kubectl get nodes`. Each task ends with a verification step.

---

## File Structure

```
d:\Homelab\
├── .gitignore                              # NEW
├── README.md                               # NEW
└── tofu/
    ├── versions.tf                         # NEW
    ├── variables.tf                        # NEW
    ├── terraform.tfvars.example            # NEW
    ├── main.tf                             # NEW
    ├── outputs.tf                          # NEW
    ├── cloud-init/
    │   ├── server.yaml.tftpl               # NEW
    │   └── agent.yaml.tftpl                # NEW
    └── modules/
        └── k3s-node/
            ├── variables.tf                # NEW
            ├── main.tf                     # NEW
            └── outputs.tf                  # NEW
```

**Responsibility split:**

- `versions.tf` — pin OpenTofu and provider versions
- `variables.tf` — declare every input the root module needs
- `terraform.tfvars.example` — committed; documents required values without secrets
- `main.tf` — Proxmox provider config + module calls (1 server, 2 agents)
- `outputs.tf` — node IPs and kubeconfig fetch instructions
- `cloud-init/*.yaml.tftpl` — role-specific cloud-init, rendered with templatefile()
- `modules/k3s-node/` — reusable Proxmox VM resource + cloud-init snippet upload

---

## Operator Prerequisites (one-time, before Task 1)

These are out-of-band setup steps the operator must complete. They are not part of the OpenTofu code but the plan can't succeed without them. The plan includes a verification task (Task 2) to confirm they are done.

1. Install OpenTofu on the workstation:
   - `winget install OpenTofu.Tofu` (PowerShell, may require admin) or `scoop install opentofu`
2. Note the Ubuntu 24.04 template's VMID (run `qm list` on the Proxmox host; record the ID).
3. Create a dedicated Proxmox user + API token for OpenTofu:
   - On Proxmox host:
     ```bash
     pveum role add TofuProvisioner -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use Sys.Audit"
     pveum user add tofu@pve
     pveum aclmod / -user tofu@pve -role TofuProvisioner
     pveum user token add tofu@pve provisioner --privsep=0
     ```
   - Save the printed token value (format: `tofu@pve!provisioner=xxxxxxxx-...`) — it's shown ONCE.
4. Confirm the `local` Proxmox storage has **Snippets** content type enabled (Proxmox UI: Datacenter → Storage → `local` → Edit → Content includes "Snippets"). If not, enable it. cloud-init user-data files are uploaded here.
5. Generate or pick an SSH keypair for cluster access (e.g., `ssh-keygen -t ed25519 -f ~/.ssh/homelab_k3s`). Note the path to the **public** key.
6. Generate a k3s cluster token: any random 64-character string. Example:
   - PowerShell: `-join ((48..57) + (97..122) | Get-Random -Count 64 | ForEach-Object {[char]$_})`
   - Save the value; you'll put it in `terraform.tfvars`.

---

## Task 1: Repo scaffolding

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `tofu/` (directory)
- Create: `tofu/cloud-init/` (directory)
- Create: `tofu/modules/k3s-node/` (directory)

- [ ] **Step 1: Create `.gitignore` at repo root**

```gitignore
# OpenTofu / Terraform
**/.terraform/
**/.terraform.lock.hcl
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# kubeconfig fetched from the cluster
kubeconfig
kubeconfig.*

# Editor
.vscode/
.idea/

# OS
Thumbs.db
.DS_Store
```

- [ ] **Step 2: Create `README.md` at repo root**

```markdown
# Homelab

Infrastructure-as-code for my homelab.

## Layout

- `tofu/` — OpenTofu configuration that provisions the k3s cluster on Proxmox.
- `docs/superpowers/specs/` — design documents.
- `docs/superpowers/plans/` — implementation plans.

Future siblings will include `ansible/` and `argocd/` directories.

## k3s cluster bootstrap

See `tofu/README.md` (created during cluster setup) or the design at
`docs/superpowers/specs/2026-05-16-k3s-cluster-opentofu-design.md`.
```

- [ ] **Step 3: Create the empty directories**

Run (PowerShell):
```powershell
New-Item -ItemType Directory -Force -Path tofu/cloud-init, tofu/modules/k3s-node | Out-Null
```

- [ ] **Step 4: Verify the layout**

Run: `Get-ChildItem -Recurse -Directory tofu`
Expected: lists `tofu`, `tofu\cloud-init`, `tofu\modules`, `tofu\modules\k3s-node`.

**Checkpoint:** Repo skeleton in place.

---

## Task 2: Verify operator prerequisites

This task is a manual checklist — confirm the operator-side prep above is complete before writing OpenTofu code that depends on it.

- [ ] **Step 1: Verify OpenTofu is installed**

Run: `tofu version`
Expected: prints a version (e.g., `OpenTofu v1.8.x`). If "command not found," install per the prereqs section.

- [ ] **Step 2: Verify Proxmox API token works**

On the workstation, run (replace placeholders with your values):
```powershell
$env:PROXMOX_VE_ENDPOINT = "https://<proxmox-host>:8006/"
$env:PROXMOX_VE_API_TOKEN = "tofu@pve!provisioner=<uuid>"
curl.exe -k -H "Authorization: PVEAPIToken=$env:PROXMOX_VE_API_TOKEN" "$env:PROXMOX_VE_ENDPOINT/api2/json/version"
```
Expected: JSON response with `"data":{"version":"8.x.x",...}`. Anything else (401, connection refused) means the token or endpoint is wrong — fix before proceeding.

- [ ] **Step 3: Verify template VMID and that Snippets are enabled**

SSH to the Proxmox host and run:
```bash
qm list | grep -i ubuntu          # confirm the template VMID
pvesm status -content snippets     # confirm at least one storage shows up (typically 'local')
```
Expected: `qm list` shows your template (note the VMID). `pvesm status -content snippets` lists `local` (or whichever storage has Snippets enabled).

**Checkpoint:** prerequisites verified; safe to start writing OpenTofu code.

---

## Task 3: Pin OpenTofu and provider versions

**Files:**
- Create: `tofu/versions.tf`

- [ ] **Step 1: Write `tofu/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
```

- [ ] **Step 2: Initialize and verify provider download**

Run (from `d:\Homelab\tofu`):
```powershell
tofu init
```
Expected: `OpenTofu has been successfully initialized!`. A `.terraform/` directory and `.terraform.lock.hcl` appear (both gitignored).

**Checkpoint:** providers pinned and downloaded.

---

## Task 4: Declare root-module input variables

**Files:**
- Create: `tofu/variables.tf`

- [ ] **Step 1: Write `tofu/variables.tf`**

```hcl
# ------------ Proxmox connection ------------

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://pve.lan:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form 'user@realm!tokenid=secret'"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification of the Proxmox endpoint (true for self-signed certs)"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node (host) name where VMs will be created, e.g. 'pve'"
  type        = string
}

# ------------ Template + storage ------------

variable "template_vmid" {
  description = "VMID of the Ubuntu 24.04 cloud-init template to clone from"
  type        = number
}

variable "vm_storage_pool" {
  description = "Proxmox storage pool where VM disks live"
  type        = string
  default     = "storage"
}

variable "snippet_storage_pool" {
  description = "Proxmox storage pool where cloud-init snippet files are uploaded (must have 'Snippets' content type enabled)"
  type        = string
  default     = "local"
}

# ------------ Networking ------------

variable "network_bridge" {
  description = "Proxmox network bridge for the VM NIC"
  type        = string
  default     = "vmbr0"
}

variable "network_cidr_bits" {
  description = "Subnet mask bits for static IPs (e.g. 24 for /24)"
  type        = number
  default     = 24
}

variable "network_gateway" {
  description = "Default gateway IP for the VMs"
  type        = string
  default     = "192.168.50.1"
}

# ------------ Cluster auth ------------

variable "ssh_user" {
  description = "Default user account created in each VM (cloud-init)"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Contents of the public SSH key to authorize on every VM"
  type        = string
}

variable "k3s_token" {
  description = "Shared k3s cluster token. Random 64-char string."
  type        = string
  sensitive   = true
}

# ------------ Topology ------------

variable "server" {
  description = "k3s control-plane node spec"
  type = object({
    hostname     = string
    ip           = string  # bare IP, no CIDR
    cpu_cores    = number
    memory_mb    = number
    root_disk_gb = number
  })
}

variable "agents" {
  description = "k3s worker node specs"
  type = list(object({
    hostname      = string
    ip            = string
    cpu_cores     = number
    memory_mb     = number
    root_disk_gb  = number
    data_disk_gb  = number  # 0 to skip the second disk
  }))
}
```

- [ ] **Step 2: Validate syntax**

Run (from `tofu/`): `tofu validate`
Expected: `Error: Reference to undeclared resource` or similar referencing `main.tf` — that's fine, `main.tf` doesn't exist yet. The validate failure should NOT mention `variables.tf`. If `variables.tf` itself has a syntax error, fix it.

Run: `tofu fmt -check`
Expected: no output (exit 0). If it reformats, run `tofu fmt` and re-check.

**Checkpoint:** root variables declared.

---

## Task 5: Create the example tfvars file

**Files:**
- Create: `tofu/terraform.tfvars.example`

- [ ] **Step 1: Write `tofu/terraform.tfvars.example`**

```hcl
# Copy this file to terraform.tfvars and fill in your values.
# terraform.tfvars is gitignored — never commit secrets.

# --- Proxmox connection ---
proxmox_endpoint  = "https://pve.lan:8006/"
proxmox_api_token = "tofu@pve!provisioner=00000000-0000-0000-0000-000000000000"
proxmox_insecure  = true
proxmox_node      = "pve"

# --- Template + storage ---
template_vmid        = 9000          # change to your Ubuntu 24.04 template's VMID
vm_storage_pool      = "storage"
snippet_storage_pool = "local"

# --- Networking ---
network_bridge    = "vmbr0"
network_cidr_bits = 24
network_gateway   = "192.168.50.1"

# --- Cluster auth ---
ssh_user       = "ubuntu"
ssh_public_key = "ssh-ed25519 AAAA... user@host"
k3s_token      = "REPLACE_WITH_64_CHAR_RANDOM_STRING"

# --- Topology ---
server = {
  hostname     = "k3s-server-01"
  ip           = "192.168.50.150"
  cpu_cores    = 4
  memory_mb    = 8192
  root_disk_gb = 40
}

agents = [
  {
    hostname     = "k3s-agent-01"
    ip           = "192.168.50.151"
    cpu_cores    = 6
    memory_mb    = 16384
    root_disk_gb = 40
    data_disk_gb = 100
  },
  {
    hostname     = "k3s-agent-02"
    ip           = "192.168.50.152"
    cpu_cores    = 6
    memory_mb    = 16384
    root_disk_gb = 40
    data_disk_gb = 100
  }
]
```

- [ ] **Step 2: Copy to `terraform.tfvars` and fill in real values**

Run (from `tofu/`):
```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```
Edit `terraform.tfvars` with the operator's actual Proxmox endpoint, API token, template VMID, SSH pubkey, and k3s token.

- [ ] **Step 3: Verify tfvars is gitignored**

Run: `git check-ignore tofu/terraform.tfvars`
Expected: prints `tofu/terraform.tfvars`. If nothing prints, the file is NOT being ignored — re-check `.gitignore` from Task 1.

**Checkpoint:** real config values in `terraform.tfvars` (gitignored), example committed.

---

## Task 6: Server cloud-init template

**Files:**
- Create: `tofu/cloud-init/server.yaml.tftpl`

- [ ] **Step 1: Write `tofu/cloud-init/server.yaml.tftpl`**

```yaml
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: true

users:
  - name: ${ssh_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [users, admin, sudo]
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
  - netcat-openbsd

runcmd:
  - systemctl enable --now qemu-guest-agent
  - |
    curl -sfL https://get.k3s.io | \
      K3S_TOKEN='${k3s_token}' \
      INSTALL_K3S_EXEC='server --cluster-init --node-ip=${node_ip} --tls-san=${node_ip} --disable=servicelb --write-kubeconfig-mode=644' \
      sh -
  - touch /var/log/k3s-bootstrap.done
```

- [ ] **Step 2: Verify the template renders cleanly with a dry run**

Run (from `tofu/`):
```powershell
tofu console
```
At the prompt, paste:
```hcl
templatefile("${path.cwd}/cloud-init/server.yaml.tftpl", {
  hostname       = "k3s-server-01"
  ssh_user       = "ubuntu"
  ssh_public_key = "ssh-ed25519 AAAA test"
  k3s_token      = "testtoken"
  node_ip        = "192.168.50.150"
})
```
Expected: returns the rendered YAML with values substituted. Exit with Ctrl+D / `exit`.

**Checkpoint:** server cloud-init renders correctly.

---

## Task 7: Agent cloud-init template

**Files:**
- Create: `tofu/cloud-init/agent.yaml.tftpl`

- [ ] **Step 1: Write `tofu/cloud-init/agent.yaml.tftpl`**

```yaml
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: true

users:
  - name: ${ssh_user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [users, admin, sudo]
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
  - netcat-openbsd

runcmd:
  - systemctl enable --now qemu-guest-agent
  - |
    until nc -z ${server_ip} 6443; do
      echo "[k3s-agent] waiting for server ${server_ip}:6443..."
      sleep 5
    done
  - |
    curl -sfL https://get.k3s.io | \
      K3S_URL=https://${server_ip}:6443 \
      K3S_TOKEN='${k3s_token}' \
      INSTALL_K3S_EXEC='agent --node-ip=${node_ip}' \
      sh -
  - touch /var/log/k3s-bootstrap.done
```

- [ ] **Step 2: Verify the template renders cleanly**

Run (from `tofu/`): `tofu console`
At the prompt:
```hcl
templatefile("${path.cwd}/cloud-init/agent.yaml.tftpl", {
  hostname       = "k3s-agent-01"
  ssh_user       = "ubuntu"
  ssh_public_key = "ssh-ed25519 AAAA test"
  k3s_token      = "testtoken"
  server_ip      = "192.168.50.150"
  node_ip        = "192.168.50.151"
})
```
Expected: rendered YAML with values substituted.

**Checkpoint:** agent cloud-init renders correctly.

---

## Task 8: k3s-node module — variables

**Files:**
- Create: `tofu/modules/k3s-node/variables.tf`

- [ ] **Step 1: Write `tofu/modules/k3s-node/variables.tf`**

```hcl
variable "proxmox_node" {
  description = "Proxmox node name where the VM is created"
  type        = string
}

variable "template_vmid" {
  description = "VMID of the template to clone from"
  type        = number
}

variable "vm_storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
}

variable "snippet_storage_pool" {
  description = "Storage pool for cloud-init user-data snippets (must support Snippets content)"
  type        = string
}

variable "network_bridge" {
  description = "Proxmox bridge for the NIC"
  type        = string
}

variable "hostname" {
  description = "VM hostname (also used as the resource name and snippet filename)"
  type        = string
}

variable "ip_address" {
  description = "Static IP in CIDR notation, e.g. 192.168.50.150/24"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
}

variable "cpu_cores" {
  description = "vCPU cores"
  type        = number
}

variable "memory_mb" {
  description = "RAM in MB"
  type        = number
}

variable "root_disk_gb" {
  description = "Root disk size in GB"
  type        = number
}

variable "data_disk_gb" {
  description = "Optional second disk size in GB. 0 to skip."
  type        = number
  default     = 0
}

variable "user_data" {
  description = "Rendered cloud-init user-data YAML"
  type        = string
}

variable "role" {
  description = "Tag value, e.g. 'server' or 'agent'"
  type        = string
}
```

- [ ] **Step 2: Validate**

Run (from `tofu/`): `tofu validate`
Expected: still fails on missing `main.tf` references — that's fine. Module's own `variables.tf` should parse without error (no message about `modules/k3s-node/variables.tf`).

**Checkpoint:** module variables defined.

---

## Task 9: k3s-node module — main resource

**Files:**
- Create: `tofu/modules/k3s-node/main.tf`

- [ ] **Step 1: Write `tofu/modules/k3s-node/main.tf`**

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

# Upload the rendered cloud-init user-data as a Proxmox snippet so it can be
# referenced via user_data_file_id on the VM.
resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippet_storage_pool
  node_name    = var.proxmox_node

  source_raw {
    data      = var.user_data
    file_name = "${var.hostname}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  name        = var.hostname
  node_name   = var.proxmox_node
  description = "k3s ${var.role} node, managed by OpenTofu"
  tags        = ["k3s", var.role, "tofu"]

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  # Root disk — resize the cloned template disk.
  disk {
    datastore_id = var.vm_storage_pool
    interface    = "scsi0"
    size         = var.root_disk_gb
  }

  # Optional second disk for Longhorn on worker nodes.
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      datastore_id = var.vm_storage_pool
      interface    = "scsi1"
      size         = var.data_disk_gb
    }
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.vm_storage_pool

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data.id
  }

  lifecycle {
    ignore_changes = [
      # The template may be updated independently — don't force VM rebuilds.
      clone[0].vm_id,
    ]
  }
}
```

- [ ] **Step 2: Validate**

Run (from `tofu/`): `tofu validate`
Expected: still fails on the missing root `main.tf` — module file itself is valid.

Run: `tofu fmt -check -recursive`
Expected: exit 0. If it reformats, run `tofu fmt -recursive` and re-check.

**Checkpoint:** module resource defined.

---

## Task 10: k3s-node module — outputs

**Files:**
- Create: `tofu/modules/k3s-node/outputs.tf`

- [ ] **Step 1: Write `tofu/modules/k3s-node/outputs.tf`**

```hcl
output "hostname" {
  description = "VM hostname"
  value       = var.hostname
}

output "ip" {
  description = "Static IP assigned to the VM (bare, no CIDR)"
  value       = split("/", var.ip_address)[0]
}

output "vm_id" {
  description = "Proxmox VMID of the created VM"
  value       = proxmox_virtual_environment_vm.node.vm_id
}
```

- [ ] **Step 2: Validate**

Run (from `tofu/`): `tofu validate`
Expected: still fails on missing root `main.tf` — module is otherwise valid.

**Checkpoint:** module outputs in place; module is complete.

---

## Task 11: Root `main.tf` — provider config + module wiring

**Files:**
- Create: `tofu/main.tf`

- [ ] **Step 1: Write `tofu/main.tf`**

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
}

locals {
  cidr_suffix = "/${var.network_cidr_bits}"

  server_ip_cidr = "${var.server.ip}${local.cidr_suffix}"

  agents_by_hostname = { for a in var.agents : a.hostname => a }
}

module "k3s_server" {
  source = "./modules/k3s-node"

  proxmox_node         = var.proxmox_node
  template_vmid        = var.template_vmid
  vm_storage_pool      = var.vm_storage_pool
  snippet_storage_pool = var.snippet_storage_pool
  network_bridge       = var.network_bridge
  gateway              = var.network_gateway

  hostname     = var.server.hostname
  ip_address   = local.server_ip_cidr
  cpu_cores    = var.server.cpu_cores
  memory_mb    = var.server.memory_mb
  root_disk_gb = var.server.root_disk_gb
  data_disk_gb = 0
  role         = "server"

  user_data = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    hostname       = var.server.hostname
    ssh_user       = var.ssh_user
    ssh_public_key = var.ssh_public_key
    k3s_token      = var.k3s_token
    node_ip        = var.server.ip
  })
}

module "k3s_agents" {
  source   = "./modules/k3s-node"
  for_each = local.agents_by_hostname

  proxmox_node         = var.proxmox_node
  template_vmid        = var.template_vmid
  vm_storage_pool      = var.vm_storage_pool
  snippet_storage_pool = var.snippet_storage_pool
  network_bridge       = var.network_bridge
  gateway              = var.network_gateway

  hostname     = each.value.hostname
  ip_address   = "${each.value.ip}${local.cidr_suffix}"
  cpu_cores    = each.value.cpu_cores
  memory_mb    = each.value.memory_mb
  root_disk_gb = each.value.root_disk_gb
  data_disk_gb = each.value.data_disk_gb
  role         = "agent"

  user_data = templatefile("${path.module}/cloud-init/agent.yaml.tftpl", {
    hostname       = each.value.hostname
    ssh_user       = var.ssh_user
    ssh_public_key = var.ssh_public_key
    k3s_token      = var.k3s_token
    server_ip      = var.server.ip
    node_ip        = each.value.ip
  })

  depends_on = [module.k3s_server]
}
```

- [ ] **Step 2: Validate**

Run (from `tofu/`): `tofu init` (re-init because module sources changed)
Expected: re-initializes successfully, finds the local module.

Run: `tofu validate`
Expected: `Success! The configuration is valid.`

Run: `tofu fmt -check -recursive`
Expected: exit 0.

**Checkpoint:** root configuration validates.

---

## Task 12: Root `outputs.tf`

**Files:**
- Create: `tofu/outputs.tf`

- [ ] **Step 1: Write `tofu/outputs.tf`**

```hcl
output "server" {
  description = "k3s server node details"
  value = {
    hostname = module.k3s_server.hostname
    ip       = module.k3s_server.ip
    vm_id    = module.k3s_server.vm_id
  }
}

output "agents" {
  description = "k3s agent node details, keyed by hostname"
  value = {
    for name, mod in module.k3s_agents : name => {
      hostname = mod.hostname
      ip       = mod.ip
      vm_id    = mod.vm_id
    }
  }
}

output "kubeconfig_instructions" {
  description = "How to fetch a working kubeconfig after apply"
  value       = <<-EOT
    1. SSH to the server and copy the kubeconfig:
       scp ${var.ssh_user}@${module.k3s_server.ip}:/etc/rancher/k3s/k3s.yaml ./kubeconfig

    2. Rewrite the server address (k3s writes 127.0.0.1 by default):
       (Get-Content ./kubeconfig) -replace '127\.0\.0\.1', '${module.k3s_server.ip}' | Set-Content ./kubeconfig

    3. Use it:
       $env:KUBECONFIG = (Resolve-Path ./kubeconfig).Path
       kubectl get nodes
  EOT
}
```

- [ ] **Step 2: Validate end-to-end**

Run (from `tofu/`): `tofu validate`
Expected: `Success! The configuration is valid.`

Run: `tofu fmt -check -recursive`
Expected: exit 0.

**Checkpoint:** configuration is complete and valid; ready to plan.

---

## Task 13: Plan review (no apply yet)

**Files:** none — review-only step.

- [ ] **Step 1: Run `tofu plan`**

Run (from `tofu/`): `tofu plan -out=tfplan`
Expected: plan output shows:
- 3× `module.k3s_server.proxmox_virtual_environment_file.user_data` and `module.k3s_agents["..."].proxmox_virtual_environment_file.user_data` (one per node = 3 total)
- 3× `proxmox_virtual_environment_vm.node` (one per node)
- Total: 6 resources to add, 0 to change, 0 to destroy.

If the plan errors talking to Proxmox (auth/TLS), fix the endpoint or API token in `terraform.tfvars` and re-run.

- [ ] **Step 2: Spot-check the plan**

Inspect the plan output and confirm:
- The server resource has `name = "k3s-server-01"`, `cores = 4`, `dedicated = 8192`, no second disk.
- Each agent resource has `cores = 6`, `dedicated = 16384`, and TWO disks (`scsi0` 40 GB + `scsi1` 100 GB).
- The `ip_config.ipv4.address` values match the expected `.150/.151/.152`.
- The user-data files have the expected hostnames in their filenames.

If anything is off, fix the source files before applying.

**Checkpoint:** plan reviewed and matches expectations.

---

## Task 14: Apply — bootstrap the cluster

**Files:** none — execution step.

- [ ] **Step 1: Apply the plan**

Run (from `tofu/`): `tofu apply tfplan`

Expected behavior:
- Server VM is created first.
- Agents start being created in parallel after the server resource is created (note: `depends_on` waits for the server resource to be created, not for k3s to be running — agents handle the wait themselves via the `nc -z` poll in cloud-init).
- Each VM takes ~30-90 s to clone, boot, and let qemu-guest-agent come up. `apply` blocks per VM until the agent reports an IP.
- Total wall-clock time: typically 3–8 minutes.

If apply fails partway, run `tofu apply tfplan` again or `tofu plan` + `tofu apply` to re-attempt.

- [ ] **Step 2: Verify VMs are running**

After apply completes, run: `tofu output`
Expected: shows server and agents blocks with the assigned IPs.

SSH to the server: `ssh -i <your-key> ubuntu@192.168.50.150`
Run on the server: `sudo systemctl status k3s`
Expected: `active (running)`. If it's still `activating`, cloud-init may not have finished — check `cloud-init status` and `tail /var/log/cloud-init-output.log`.

SSH to one agent: `ssh -i <your-key> ubuntu@192.168.50.151`
Run: `sudo systemctl status k3s-agent`
Expected: `active (running)`. Again, if still activating, check cloud-init logs — most common cause is the server's `:6443` not yet open, so the agent's `nc -z` loop is still polling.

**Checkpoint:** all three VMs are up, k3s services are running.

---

## Task 15: Fetch kubeconfig and verify cluster

**Files:** none — execution step.

- [ ] **Step 1: Fetch the kubeconfig**

Run (from `tofu/`):
```powershell
scp ubuntu@192.168.50.150:/etc/rancher/k3s/k3s.yaml ../kubeconfig
(Get-Content ../kubeconfig) -replace '127\.0\.0\.1', '192.168.50.150' | Set-Content ../kubeconfig
$env:KUBECONFIG = (Resolve-Path ../kubeconfig).Path
```

The `kubeconfig` file is already gitignored via the entries added in Task 1.

- [ ] **Step 2: Verify all three nodes are Ready**

Run: `kubectl get nodes -o wide`
Expected:
```
NAME             STATUS   ROLES                       AGE     VERSION
k3s-server-01    Ready    control-plane,etcd,master   Xm      v1.30.x+k3s1
k3s-agent-01     Ready    <none>                      Xm      v1.30.x+k3s1
k3s-agent-02     Ready    <none>                      Xm      v1.30.x+k3s1
```

If any node is `NotReady`, give it a couple more minutes (kubelet may still be starting). If after ~5 minutes a node is still `NotReady`, SSH in and check `journalctl -u k3s` or `journalctl -u k3s-agent`.

- [ ] **Step 3: Verify Traefik is running and ServiceLB is NOT**

Run: `kubectl get pods -A`
Expected: pods in `kube-system` include `traefik-*`, `coredns-*`, `metrics-server-*`, `local-path-provisioner-*`. There should be NO `svclb-*` pods (ServiceLB was disabled).

- [ ] **Step 4: Sanity-check the second disk on agents**

SSH to an agent: `ssh ubuntu@192.168.50.151`
Run: `lsblk`
Expected: a `sda` (or `scsi0`) device for the root disk plus a `sdb` (or `scsi1`) raw device of ~100 GB with no partitions or filesystem. That's the disk Longhorn will claim later.

**Checkpoint:** k3s cluster is up, three Ready nodes, ready for ArgoCD/MetalLB/Longhorn in a future plan.

---

## Self-review notes

- Every spec requirement is covered: 3-node topology (Tasks 9-11), embedded etcd via `--cluster-init` (Task 6), Traefik enabled / ServiceLB disabled (Task 6 install command), qemu-guest-agent installed via cloud-init Option B (Tasks 6-7 `packages:`), Longhorn-ready 100 GB second disk on agents (Task 9 `dynamic "disk"` + Task 5 tfvars), MetalLB pool reservation (documented in tfvars Task 5 comments — no code needed since MetalLB is out of scope).
- No placeholders ("TBD", "TODO", "implement later") remain.
- Method/resource names are consistent: `proxmox_virtual_environment_vm`, `proxmox_virtual_environment_file`, module `k3s-node`, server module `k3s_server`, agents module `k3s_agents`.
- File paths in code blocks match the file structure section.
- Commits are deferred per project convention (memory: feedback-git-commits).
