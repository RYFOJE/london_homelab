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

# Azure Key Vault holds every lab credential (scripts/keyvault.ps1 fills it).
# Terraform only reads two entries from it -- the External Secrets service
# principal -- using your `az login` session. None of these three is secret.

variable "azure_subscription_id" {
  type        = string
  description = "Subscription the Key Vault lives in: `az account show --query id -o tsv`. Required by the azurerm provider for plan/apply."
}

variable "azure_key_vault_name" {
  type        = string
  description = "Key Vault name (globally unique, the <name> in https://<name>.vault.azure.net). Must match spec.provider.azurekv.vaultUrl in cluster/lab/secrets/clustersecretstore.yaml."
}

variable "azure_key_vault_resource_group" {
  type        = string
  description = "Resource group that contains the Key Vault."
}

variable "proxmox_agent_wait" {
  type        = bool
  default     = false
  description = "Let the Proxmox provider wait on the Talos guest agent (IP lookup, up to 15m) during plan/apply/refresh. Off by default: nothing here reads what the agent reports and the wait is minutes of 'Refreshing state...'. Turn on with -var proxmox_agent_wait=true when you actually want it."
}
