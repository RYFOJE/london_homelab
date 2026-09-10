# Terraform's last act. After this it owns the VM, the LXC and an ArgoCD
# install -- nothing else. Everything downstream lives in git.
#
# Deliberately NOT using kubernetes_manifest for the root Application:
# it runs a server-side dry-run at plan time and fails when the Application
# CRD does not exist yet, which is always true on a first apply.

resource "helm_release" "argocd" {
  depends_on = [terraform_data.wait_for_apiserver]

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  # Pinned to what the first successful install resolved (see .helm/cache).
  # Bump deliberately: helm search repo argo/argo-cd --versions
  version = "10.8.4"

  values = [yamlencode({
    configs = {
      params = {
        # Traefik terminates TLS; stop ArgoCD doing it too and redirect-looping.
        "server.insecure" = true
      }
      cm = {
        # ArgoCD >= 1.8 ships NO health check for Application resources, so
        # in an app-of-apps the root app considers every child "Healthy" the
        # instant it exists and sync waves in cluster/lab/apps order nothing.
        # This restores the check so wave N+1 waits for wave N to be Healthy.
        # https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
          return hs
        LUA
      }
    }
    server = {
      ingress = {
        enabled          = true
        controller       = "generic"
        ingressClassName = "traefik"
        hostname         = "argocd.${local.domain}"
        path             = "/"
        pathType         = "Prefix"
        # tls stays false until a ClusterIssuer exists. HTTP only for now.
        tls = false
      }
    }
  })]
}

resource "helm_release" "root_app" {
  # The namespaces below are ALSO created by ArgoCD (CreateNamespace=true on
  # the apps that land in them). Whoever gets there second fails: Terraform
  # with "namespaces X already exists", which then needs a `terraform import`.
  # Ordering the root app after them means Terraform always wins on a fresh
  # build. On an existing cluster where ArgoCD already created one, import it:
  #   terraform import kubernetes_namespace_v1.<name> <name>
  depends_on = [
    helm_release.argocd,
    kubernetes_namespace_v1.authentik,
    kubernetes_namespace_v1.observability,
    kubernetes_namespace_v1.elastic,
    kubernetes_namespace_v1.database,
    kubernetes_namespace_v1.cert_manager,
  ]

  name       = "root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.5"

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
