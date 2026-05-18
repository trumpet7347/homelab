provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = false
    username = var.proxmox_ssh_username
    password = var.proxmox_ssh_password
  }
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

  hostname       = var.server.hostname
  vm_id          = var.server.vm_id
  ip_address     = local.server_ip_cidr
  cpu_cores      = var.server.cpu_cores
  memory_mb      = var.server.memory_mb
  root_disk_gb   = var.server.root_disk_gb
  data_disk_gb   = 0
  ssh_user       = var.ssh_user
  ssh_public_key = var.ssh_public_key
  role           = "server"

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

  hostname       = each.value.hostname
  vm_id          = each.value.vm_id
  ip_address     = "${each.value.ip}${local.cidr_suffix}"
  cpu_cores      = each.value.cpu_cores
  memory_mb      = each.value.memory_mb
  root_disk_gb   = each.value.root_disk_gb
  data_disk_gb   = each.value.data_disk_gb
  ssh_user       = var.ssh_user
  ssh_public_key = var.ssh_public_key
  role           = "agent"

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
