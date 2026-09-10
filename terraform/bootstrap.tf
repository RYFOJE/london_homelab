# Terraform's last act. After this it owns the VM, the LXC and an ArgoCD
# install -- nothing else. Everything downstream lives in git.
#
# Deliberately NOT using kubernetes_manifest for the root Application:
# it runs a server-side dry-run at plan time and fails when the Application
# CRD does not exist yet, which is always true on a first apply.

resource "helm_release" "argocd" {
  depends_on = [data.talos_cluster_health.this]

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  # Pin after your first successful install:
  #   helm repo add argo https://argoproj.github.io/argo-helm
  #   helm search repo argo/argo-cd --versions
  # version = "x.y.z"

  values = [yamlencode({
    configs = {
      params = {
        # Traefik terminates TLS; stop ArgoCD doing it too and redirect-looping.
        "server.insecure" = true
      }
    }
  })]
}

resource "helm_release" "root_app" {
  depends_on = [helm_release.argocd]

  name       = "root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  # version = "x.y.z"

  values = [yamlencode({
    # Map keyed by name. Older chart versions took a list here.
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.git_repo_url
          targetRevision = "HEAD"
          path           = "cluster/lab/apps"
          directory      = { recurse = true }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]
}
