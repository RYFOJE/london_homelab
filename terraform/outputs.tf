output "talos_node_ip" {
  value = local.talos.ip
}

output "dns_server_ip" {
  value       = local.containers.dns.ip
  description = "Point your router's DHCP option 6 at this. The one unavoidable manual step."
}

output "ingress_target" {
  value       = "*.${local.domain} -> ${local.talos.ip}"
  description = "Resolved by dnsmasq in the LXC. Never published publicly."
}

# Write these to disk yourself; they are not files on purpose:
#   terraform output -raw kubeconfig  > ~/.kube/config
#   terraform output -raw talosconfig > ~/.talos/config
output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
