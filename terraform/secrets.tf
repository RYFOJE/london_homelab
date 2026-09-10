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
