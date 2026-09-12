variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint. Use an IP, not a hostname -- you have no resolver until this config runs. e.g. https://192.168.1.5:8006/"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Public key injected into the LXC. The matching private key must be loaded in your SSH agent -- both the proxmox provider and the dnsmasq provisioner authenticate through the agent."
}

variable "ssh_private_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa"
  description = <<-EOT
    Private key the proxmox provider authenticates to the PVE host with, for
    the template download and datastore operations that go over SSH rather
    than the API. Must be unencrypted (no passphrase) -- the provider cannot
    prompt for one.

    Why not the SSH agent: the provider is Go and finds the agent through the
    SSH_AUTH_SOCK environment variable, which Windows never sets. The `ssh`
    CLI knows the OpenSSH named pipe natively, so `ssh root@<pve>` succeeds
    while the provider fails with "attempted methods [none password]", having
    never offered a public key at all. Pointing the provider's `agent_socket`
    at the named pipe does not fix it either. Reading the key file directly
    sidesteps the agent completely.

    The matching .pub must be in root's authorized_keys on the PVE host
    (DEPLOY.md step 1.2). terraform_data.dnsmasq still uses the agent: that
    is Terraform's own SSH client, which does handle the Windows pipe.

    NOTE this is deliberately a DIFFERENT key from ssh_public_key_path. That
    one is injected into the LXC and authenticated against by the agent, so
    it has to be a key the agent holds; this one has to be whatever key the
    PVE host's root already trusts. `ssh -v root@<pve>` prints which key the
    host accepts ("Server accepts key: ...") if the two ever diverge.
  EOT
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

# scripts/keyvault.ps1 creates TWO Key Vaults. This block is the Terraform
# vault: exactly three entries (the External Secrets service principal's own
# login and the Proxmox API token), read using your `az login` session. The
# ESO vault -- every other lab credential -- is a separate vault Terraform
# never touches; its name lives only in
# cluster/lab/secrets/clustersecretstore.yaml (spec.provider.azurekv.vaultUrl).
# None of these three variables is secret; nothing in tfvars is.

variable "azure_subscription_id" {
  type        = string
  description = "Subscription the Key Vault lives in: `az account show --query id -o tsv`. Required by the azurerm provider for plan/apply."
}

variable "azure_key_vault_name" {
  type        = string
  description = "Terraform vault name (globally unique, the <name> in https://<name>.vault.azure.net) -- NOT the ESO vault clustersecretstore.yaml points at, a separate vault."
}

variable "azure_key_vault_resource_group" {
  type        = string
  description = "Resource group that contains both Key Vaults."
}

variable "proxmox_agent_wait" {
  type        = bool
  default     = false
  description = "Let the Proxmox provider wait on the Talos guest agent (IP lookup, up to 15m) during plan/apply/refresh. Off by default: nothing here reads what the agent reports and the wait is minutes of 'Refreshing state...'. Turn on with -var proxmox_agent_wait=true when you actually want it."
}
