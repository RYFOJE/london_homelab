variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint. Use an IP, not a hostname -- you have no resolver until this config runs. e.g. https://192.168.1.5:8006/"
}

variable "pve_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token, ID and secret joined by '=': root@pam!tf=<uuid>. Uncheck Privilege Separation on the token, or grant it its own ACL, or every call 403s."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Public key injected into the LXC. The matching private key must be loaded in your SSH agent -- both the proxmox provider and the dnsmasq provisioner authenticate through the agent."
}

variable "lxc_template_url" {
  type        = string
  description = "Debian LXC template URL. Run `pveam available --section system` on the PVE host and paste the current filename -- a stale patch version 404s mid-apply."
}

variable "talos_version" {
  type    = string
  default = "1.14.0"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36.3"
}

variable "talos_schematic_id" {
  type        = string
  description = <<-EOT
    Image Factory schematic ID (64 hex chars). Generated from files/schematic.yaml:

      cd terraform
      $body = Get-Content files/schematic.yaml -Raw
      Invoke-RestMethod -Uri https://factory.talos.dev/schematics `
        -Method Post -ContentType application/yaml -Body $body

    Then confirm the image exists before applying:

      Invoke-WebRequest "https://factory.talos.dev/image/<id>/v1.14.0/nocloud-amd64.raw.xz" -Method Head
  EOT
}

variable "git_repo_url" {
  type        = string
  description = "HTTPS URL of this repo. ArgoCD reads cluster/lab/apps from it. Keep it public, or you need a repo credential in the bootstrap path."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token for cert-manager's DNS-01 solver. Permissions: Zone/DNS/Edit + Zone/Zone/Read, scoped to the zone the lab domain sits under. Lands in Secret cert-manager/cloudflare-api-token."
}
