provider "proxmox" {
  endpoint = var.pve_endpoint
  # From Key Vault (secrets.tf), through your `az login` session, so the
  # token is in no local file. A data source in a provider block is fine as
  # long as azurerm itself needs nothing from proxmox -- it does not.
  api_token = data.azurerm_key_vault_secret.pve_api_token.value
  insecure  = true # self-signed PVE cert

  # Required. Template downloads and several datastore operations go over
  # SSH as root, not the API. Token alone yields a misleading RBAC error.
  ssh {
    username = "root"
    # NOT agent = true. On Windows the provider cannot reach the OpenSSH
    # agent (it looks for SSH_AUTH_SOCK, which Windows does not set) and
    # never offers a public key: "attempted methods [none password]".
    # Setting agent_socket to the named pipe does not help either. Read the
    # key file directly -- see var.ssh_private_key_path.
    private_key = file(pathexpand(var.ssh_private_key_path))
  }
}

provider "talos" {}

# Authenticates as you, through the Azure CLI (`az login`) -- the provider's
# default when no client credentials are set. Only reads: the three Key Vault
# data sources in secrets.tf. Nothing in Azure is created or changed here;
# scripts/keyvault.ps1 does that, once, by hand.
provider "azurerm" {
  subscription_id = var.azure_subscription_id
  features {}
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
  # Isolate from the user's own Helm state. By default the provider reads
  # ~/AppData/Roaming/helm/repositories.yaml and tries to load a cached index
  # for EVERY repo listed there -- one stale entry you added years ago for an
  # unrelated chart fails the whole apply with "no cached repo found". Keeping
  # the config inside the repo makes the build depend on nothing outside it.
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm/cache"

  kubernetes {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}
