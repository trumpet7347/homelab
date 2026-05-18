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

variable "vm_id" {
  description = "Explicit Proxmox VMID. Must be unique; Proxmox errors if the ID is already in use."
  type        = number
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
  description = "Root disk size in GB. Must be >= the template's existing disk size (only growing is supported)."
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

variable "ssh_user" {
  description = "Cloud-init username to set on the VM"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key to authorize for ssh_user"
  type        = string
}

variable "role" {
  description = "Tag value, e.g. 'server' or 'agent'"
  type        = string
}
