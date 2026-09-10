terraform {
  required_version = ">= 1.9"

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
  }
}

# Versions for everything else are pinned by .terraform.lock.hcl after the
# first `terraform init`. Commit that file.
