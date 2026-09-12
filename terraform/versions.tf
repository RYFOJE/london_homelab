terraform {
  required_version = ">= 1.9"

  # Partial config on purpose: the storage account name is chosen at
  # `scripts/keyvault.ps1` run time (global uniqueness), so it can't be a
  # literal here. Fill in terraform/backend.hcl (gitignored, not secret --
  # same reasoning as terraform.tfvars) and run
  # `terraform init -backend-config=backend.hcl`. use_azuread_auth means
  # Terraform authenticates with your `az login` session, the same one
  # secrets.tf reads the Key Vault with; no storage account key anywhere.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "london-homelab.tfstate"
  }

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    talos = {
      source = "siderolabs/talos"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
      # Pinned deliberately: helm 3.x replaced the `kubernetes { }` block
      # in providers.tf with `kubernetes = { }` attribute syntax.
      version = "~> 2.17"
    }
    azurerm = {
      source = "hashicorp/azurerm"
      # Read-only here (two Key Vault data sources, secrets.tf). 5.x moved
      # provider registration to opt-in, which suits a config that creates
      # nothing in Azure.
      version = "~> 5.0"
    }
  }
}

# Versions for everything else are pinned by .terraform.lock.hcl after the
# first `terraform init`. Commit that file.
