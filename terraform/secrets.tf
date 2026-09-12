# The one Secret Terraform writes into the cluster.
#
# There are two Key Vaults (scripts/keyvault.ps1 creates both): the ESO
# vault holds every lab credential and External Secrets Operator pulls them
# into the cluster from cluster/lab/secrets/; the Terraform vault, read here,
# holds only what Terraform itself needs -- ESO's own login and the Proxmox
# token -- and the ESO service principal has no role on it at all. ESO needs
# a credential to reach ITS vault, and that is the chicken-and-egg this file
# resolves: Terraform reads the SP's client id and secret out of the
# Terraform vault, using YOUR `az login` identity, and writes them to one
# Secret that the ClusterSecretStore points at. The Proxmox API token comes
# from the same vault the same way and feeds the proxmox provider
# (providers.tf). Nothing secret is in tfvars.
#
# It lands in the argocd namespace on purpose: that namespace is the only one
# Terraform is guaranteed to have (the ArgoCD chart creates it), so Terraform
# never has to create a namespace that ArgoCD also manages.
#
# tfstate still has to be protected: data-source results (the SP secret, the
# Proxmox token) are stored in it in plain text, alongside the Talos machine
# secrets.

data "azurerm_key_vault" "terraform" {
  name                = var.azure_key_vault_name
  resource_group_name = var.azure_key_vault_resource_group
}

data "azurerm_key_vault_secret" "eso_client_id" {
  name         = "eso-client-id"
  key_vault_id = data.azurerm_key_vault.terraform.id
}

data "azurerm_key_vault_secret" "eso_client_secret" {
  name         = "eso-client-secret"
  key_vault_id = data.azurerm_key_vault.terraform.id
}

# Proxmox API token, `root@pam!tf=<secret>`, prompted for by keyvault.ps1.
# Used only by the proxmox provider block; it never enters the cluster.
data "azurerm_key_vault_secret" "pve_api_token" {
  name         = "pve-api-token"
  key_vault_id = data.azurerm_key_vault.terraform.id
}

resource "kubernetes_secret_v1" "azure_keyvault_creds" {
  # The argocd namespace is created by the chart (create_namespace = true).
  depends_on = [helm_release.argocd]

  metadata {
    name      = "azure-keyvault-creds"
    namespace = "argocd"
  }

  # Key names are what cluster/lab/secrets/clustersecretstore.yaml reads.
  data = {
    "client-id"     = data.azurerm_key_vault_secret.eso_client_id.value
    "client-secret" = data.azurerm_key_vault_secret.eso_client_secret.value
  }
}
