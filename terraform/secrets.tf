# Authentik's signing key.
#
# Generated here rather than pulled from an external store: tfstate already
# holds the Talos machine secrets, so it is already the file that must be
# protected and backed up. Adding a secrets manager for one value would mean
# another component, another account, and another thing that has to be up
# for the cluster to rebuild.
#
# It survives rebuilds as long as state does. If state is lost, this key is
# regenerated -- which invalidates existing Authentik sessions and user IDs,
# but by then you are rebuilding from scratch anyway.

resource "random_password" "authentik_secret_key" {
  length = 64
  # No special characters: the value is passed as an env var, and quoting
  # bugs in that path are miserable to diagnose.
  special = false
}

resource "kubernetes_namespace_v1" "authentik" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "authentik"
  }

  # ArgoCD also manages this namespace via CreateNamespace=true. Ignore drift
  # so the two do not fight over labels and annotations.
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "authentik_secret_key" {
  metadata {
    name      = "authentik-secret-key"
    namespace = kubernetes_namespace_v1.authentik.metadata[0].name
  }

  data = {
    "secret-key" = random_password.authentik_secret_key.result
  }
}

# Grafana's break-glass admin. Same reasoning as above: one more value in
# the file that already has to be protected, and no extra component in the
# rebuild path. SSO (Authentik) is layered on later; this login stays
# enabled forever so a broken Authentik cannot lock you out of the metrics
# that explain why it broke.

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "observability" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "observability"

    # Talos enforces PodSecurity "baseline" on namespaces it does not own.
    # node-exporter and Alloy both need hostPath/hostNetwork, which baseline
    # rejects -- silently, with no pod ever created. ArgoCD sets the same
    # labels via managedNamespaceMetadata; having them here too means it
    # does not matter which side creates the namespace first.
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }

  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }
}

# ---------------------------------------------------------------------------
# Dev platform secrets. Same rule as above: generated here, kept in tfstate,
# never in git. Each one exists because a component refuses to start without
# a credential and the credential has to reach two places at once.
# ---------------------------------------------------------------------------

# Grafana <-> Authentik OIDC client secret. Authentik's blueprint reads it
# through an env var (!Env GRAFANA_OIDC_CLIENT_SECRET) and Grafana reads it
# through envFromSecret, so the same value lands in two namespaces.

resource "random_password" "grafana_oidc_client_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "grafana_oidc" {
  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }

  data = {
    "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"     = "grafana"
    "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET" = random_password.grafana_oidc_client_secret.result
  }
}

resource "kubernetes_secret_v1" "authentik_blueprint_env" {
  metadata {
    name      = "authentik-blueprint-env"
    namespace = kubernetes_namespace_v1.authentik.metadata[0].name
  }

  data = {
    "grafana-oidc-client-secret" = random_password.grafana_oidc_client_secret.result
    "argocd-oidc-client-secret"  = random_password.argocd_oidc_client_secret.result
  }
}

# Kibana's anonymous provider signs every visitor in as this Elasticsearch
# file-realm user, so the Authentik forward-auth page is the only login.
# ECK reads the basic-auth Secret to create the user; Kibana reads the
# password back via env. superuser because Authentik already gates who can
# reach Kibana at all, and a dev lab needs index management from the UI.

resource "random_password" "kibana_anonymous" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "elastic" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "elastic"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "kibana_anonymous" {
  metadata {
    name      = "kibana-anonymous"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  type = "kubernetes.io/basic-auth"

  data = {
    "username" = "kibana-anon"
    "password" = random_password.kibana_anonymous.result
    "roles"    = "superuser"
  }
}

# pgAdmin insists on a bootstrap admin account even though every real login
# arrives as an Authentik header. Nobody types this password; it only has to
# exist so the container starts.

resource "random_password" "pgadmin_admin" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "database" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "database"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "pgadmin_admin" {
  metadata {
    name      = "pgadmin-admin"
    namespace = kubernetes_namespace_v1.database.metadata[0].name
  }

  data = {
    "password" = random_password.pgadmin_admin.result
  }
}

# Cloudflare token for cert-manager's DNS-01 solver. The only credential in
# this file that Terraform did not generate: it comes from terraform.tfvars
# and is copied into the cluster once. The ClusterIssuer in cluster/lab/tls
# points at this Secret by name.

resource "kubernetes_namespace_v1" "cert_manager" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "cert-manager"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }
}

# ArgoCD <-> Authentik OIDC client secret. ArgoCD reads it from a Secret
# labelled app.kubernetes.io/part-of=argocd (the $argocd-oidc:oidc.clientSecret
# reference in bootstrap.tf); Authentik's blueprint reads the same value via
# !Env ARGOCD_OIDC_CLIENT_SECRET from authentik-blueprint-env.

resource "random_password" "argocd_oidc_client_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "argocd_oidc" {
  # The argocd namespace is created by the chart (create_namespace = true).
  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-oidc"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    "oidc.clientSecret" = random_password.argocd_oidc_client_secret.result
  }
}

# Valkey password. The cache is reachable from the LAN (Traefik :6379), so
# it needs one even in a lab.

resource "random_password" "valkey" {
  length  = 32
  special = false
}

resource "kubernetes_namespace_v1" "dev" {
  depends_on = [terraform_data.wait_for_apiserver]

  metadata {
    name = "dev"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "valkey_auth" {
  metadata {
    name      = "valkey-auth"
    namespace = kubernetes_namespace_v1.dev.metadata[0].name
  }

  data = {
    "password" = random_password.valkey.result
  }
}
