# The one Secret Terraform writes into the cluster.
#
# Every credential the lab needs lives in Azure Key Vault (scripts/keyvault.ps1
# creates the vault and every entry). External Secrets Operator pulls them
# into the cluster from cluster/lab/secrets/. ESO itself needs a credential to
# reach the vault -- a service principal -- and that is the chicken-and-egg
# this file resolves: Terraform reads the SP's client id and secret out of the
# same vault, using YOUR `az login` identity, and writes them to one Secret
# that the ClusterSecretStore points at. Nothing secret is in tfvars.
#
# It lands in the argocd namespace on purpose: that namespace is the only one
# Terraform is guaranteed to have (the ArgoCD chart creates it), so Terraform
# never has to create a namespace that ArgoCD also manages.
#
# tfstate still has to be protected: data-source results (the SP secret) are
# stored in it in plain text, alongside the Talos machine secrets.

data "azurerm_key_vault" "lab" {
  name                = var.azure_key_vault_name
  resource_group_name = var.azure_key_vault_resource_group
}

data "azurerm_key_vault_secret" "eso_client_id" {
  name         = "eso-client-id"
  key_vault_id = data.azurerm_key_vault.lab.id
}

data "azurerm_key_vault_secret" "eso_client_secret" {
  name         = "eso-client-secret"
  key_vault_id = data.azurerm_key_vault.lab.id
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
