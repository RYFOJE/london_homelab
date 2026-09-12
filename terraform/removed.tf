# ONE-SHOT MIGRATION FILE. Delete it after the first successful apply on a
# cluster built before the Key Vault change (DEPLOY.md "Migrating an existing
# cluster to Key Vault"). On a from-zero build it is a no-op and can be
# deleted straight away.
#
# These resources used to be created by secrets.tf. They are now owned by
# ArgoCD (cluster/lab/namespaces, cluster/lab/secrets). Plain removal from the
# config would make Terraform DELETE them -- and deleting the namespaces takes
# the Authentik database, Elasticsearch, everything in them. `destroy = false`
# drops them from state and leaves the objects alone.

removed {
  from = kubernetes_namespace_v1.authentik
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.observability
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.elastic
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.database
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.cert_manager
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_namespace_v1.dev
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.authentik_secret_key
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.grafana_admin
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.grafana_oidc
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.authentik_blueprint_env
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.kibana_anonymous
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.pgadmin_admin
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.cloudflare_api_token
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.argocd_oidc
  lifecycle { destroy = false }
}

removed {
  from = kubernetes_secret_v1.valkey_auth
  lifecycle { destroy = false }
}
