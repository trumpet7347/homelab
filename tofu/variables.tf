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

variable "proxmox_ssh_username" {
  description = "SSH username on the Proxmox host (used by the provider to upload cloud-init snippets)"
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  description = "SSH password for the Proxmox host (used to upload cloud-init snippets). Set via env var TF_VAR_proxmox_ssh_password to keep it out of tfvars files."
  type        = string
  sensitive   = true
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
  description = "Username to set on each VM and SCP as. Should match the user account baked into the template."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "SSH public key to install on each VM. Required because the bpg provider's initialization block clears the template's cloud-init SSH key settings on clone."
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
    vm_id        = number # Proxmox VMID; pick a contiguous block so nodes group in the UI
    ip           = string # bare IP, no CIDR
    cpu_cores    = number
    memory_mb    = number
    root_disk_gb = number
  })
}

variable "agents" {
  description = "k3s worker node specs"
  type = list(object({
    hostname     = string
    vm_id        = number
    ip           = string
    cpu_cores    = number
    memory_mb    = number
    root_disk_gb = number
    data_disk_gb = number # 0 to skip the second disk
  }))
}
