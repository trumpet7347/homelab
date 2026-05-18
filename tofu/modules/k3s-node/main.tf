terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.106"
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
  vm_id       = var.vm_id
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

  # Root disk: resize the cloned template's virtio0 disk to var.root_disk_gb.
  # The template has cloud-initramfs-growroot, so the partition + filesystem
  # auto-extend on first boot.
  disk {
    datastore_id = var.vm_storage_pool
    interface    = "virtio0"
    size         = var.root_disk_gb
  }

  # Optional second disk for Longhorn on worker nodes.
  dynamic "disk" {
    for_each = var.data_disk_gb > 0 ? [1] : []
    content {
      datastore_id = var.vm_storage_pool
      interface    = "scsi1"
      size         = var.data_disk_gb
      file_format  = "raw"
    }
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.vm_storage_pool
    interface    = "ide2" # keep the cloud-init drive off scsi1 so it's free for our data disk

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    # Required: when the initialization block is set, the bpg provider clears
    # the template's cloud-init user/sshkey fields on clone. We have to set
    # them again here for SSH to work.
    user_account {
      username = var.ssh_user
      keys     = [var.ssh_public_key]
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
