# Terraform's last act. After this it owns the VM, the LXC, an ArgoCD install
# and one seed Secret (secrets.tf) -- nothing else. Everything downstream
# lives in git.
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
    global = {
      # ArgoCD fetches Authentik's OIDC discovery document itself, and
      # in-cluster DNS cannot resolve *.lab.<domain> (README "Known gaps").
      # Pin the name to the node: Traefik answers there with the real cert.
      hostAliases = [{
        ip        = local.talos.ip
        hostnames = ["auth.${local.domain}"]
      }]
    }
    configs = {
      params = {
        # Traefik terminates TLS; stop ArgoCD doing it too and redirect-looping.
        "server.insecure" = true
      }
      # Authentik group -> ArgoCD role. Everyone else who can log in is
      # read-only. The local admin login stays enabled as break-glass.
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv"     = "g, argocd-admins, role:admin"
        "scopes"         = "[groups, email]"
      }
      cm = {
        url = "https://argocd.${local.domain}"
        # Provider/application: cluster/lab/authentik/blueprints/argocd.yaml.
        # Secret argocd-oidc is pulled from Key Vault by cluster/lab/secrets.
        "oidc.config" = <<-YAML
          name: Authentik
          issuer: https://auth.${local.domain}/application/o/argocd/
          clientID: argocd
          clientSecret: $argocd-oidc:oidc.clientSecret
          requestedScopes: ["openid", "profile", "email"]
        YAML
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
        # No tls: block needed -- Traefik's default store (cluster/lab/apps/
        # traefik.yaml) serves the lab wildcard on :443 and redirects :80.
        tls = false
      }
    }
  })]
}

resource "helm_release" "root_app" {
  # The seed Secret must exist before the root app starts working through
  # the waves: the secrets app (wave -6) reads it, and a missing Secret there
  # is a Degraded ClusterSecretStore that blocks every later wave.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.azure_keyvault_creds,
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
