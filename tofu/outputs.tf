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
