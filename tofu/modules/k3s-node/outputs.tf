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
