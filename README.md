# london_homelab

Single-node Kubernetes lab on Proxmox: Talos Linux provisioned by Terraform,
everything above the cluster owned by ArgoCD from `cluster/lab/`.

Disposable by design — `terraform destroy && terraform apply` is the
recovery plan. Configuration lives in git; data does not survive a rebuild.

## Layout

```
terraform/            VM, LXC resolver, Talos bootstrap, ArgoCD install. Nothing else.
  dns.tf              dnsmasq LXC  (*.lab.<domain> -> node IP)
  talos.tf            Talos image, VM, machine config, bootstrap
  wait.tf             blocks until kube-apiserver answers
  secrets.tf          generated credentials + the Cloudflare token (kept in tfstate)
  bootstrap.tf        argo-cd + argocd-apps root Application -> cluster/lab/apps
cluster/lab/apps/     one ArgoCD Application per platform component (sync-waved)
cluster/lab/db/       plain manifests the apps reference (Authentik's CNPG Cluster)
cluster/lab/tls/        ClusterIssuers (Let's Encrypt, DNS-01) + the lab wildcard Certificate
cluster/lab/authentik/  forward-auth Middleware + Authentik blueprints (config as code)
cluster/lab/database/   dev Postgres (CNPG Cluster) + TCP route
cluster/lab/messaging/  RabbitMQ cluster, management Ingress, AMQP route, PodMonitor
cluster/lab/elastic/    Elasticsearch, Kibana, their Ingresses
cluster/lab/observability/dashboards/  Grafana dashboards as code (kustomize -> ConfigMaps)
cluster/lab/observability/monitors/    Pod/ServiceMonitors for Traefik, ArgoCD, cert-manager
scripts/              preflight.ps1 (before apply), verify.ps1 (after), credentials.ps1 (every password)
```

## Run order

Full from-zero runbook, click-ops included: [DEPLOY.md](DEPLOY.md).
The short version:

```powershell
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
./scripts/preflight.ps1            # SSH agent, PVE token, URLs, IP/VMID clashes
cd terraform
terraform init
terraform apply
terraform output -raw kubeconfig  > ~/.kube/config
terraform output -raw talosconfig > ~/.talos/config
cd ..
./scripts/verify.ps1               # guests, DNS, node, PVCs, pods, apps, ingress
```

Requires PowerShell 7, Terraform >= 1.9, kubectl, and an SSH agent holding
the key named in `ssh_public_key_path`.

## Manual steps (the only ones)

1. Proxmox API token for Terraform — uncheck Privilege Separation.
2. Router DHCP option 6 -> the resolver LXC IP (`terraform output dns_server_ip`).
3. Cloudflare API token (Zone/DNS/Edit + Zone/Zone/Read on `ryfoje.com`)
   in `terraform.tfvars` -> `cloudflare_api_token`. cert-manager issues one
   `*.lab.ryfoje.com` wildcard by DNS-01 (`cluster/lab/tls/`); Traefik serves
   it as the default cert on :443 and 301s :80 there. New Ingresses need no
   `tls:` block.
4. This repo, public, at `git_repo_url`.

## Back this up or you cannot rebuild

- `terraform.tfstate` — contains Talos machine secrets, the Authentik
  signing key, the Grafana admin password, the Grafana OIDC client secret,
  Kibana's anonymous-user password and pgAdmin's bootstrap password.
  Encrypt it. Never commit it.
- `kubeconfig` / `talosconfig` (regenerable from state via `terraform output`).
- Proxmox and Cloudflare API tokens.

## Known gaps

- External Secrets is deployed without a `ClusterSecretStore`.
- No CoreDNS forward for the lab domain: in-cluster clients cannot resolve
  `*.lab.<domain>`. Grafana works around it by calling Authentik's token and
  userinfo endpoints on the in-cluster Service name; ArgoCD -> Authentik
  OIDC would need the same trick or a real fix.
- Elasticsearch has no Prometheus exporter; only the ECK operator's own
  metrics are scraped from the `elastic` namespaces.
- etcd metrics are off: they need client certs from `/system/secrets/etcd`
  in a Secret plus `listen-metrics-urls` in the Talos patch. Enable together.

## Observability

kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Tempo and
Grafana Alloy, all in the `observability` namespace, waves 15-30.

- Grafana: `https://grafana.lab.ryfoje.com` — local admin password:
  `terraform output -raw grafana_admin_password`
- Prometheus / Alertmanager: `http://prometheus.` / `http://alertmanager.`
  — deliberately never behind SSO.
- Apps send OTLP to `http://alloy.observability.svc.cluster.local:4318`
  and never learn the backends exist. Alloy fans out: traces -> Tempo,
  logs -> Loki, metrics -> Prometheus remote write. Infra metrics are
  scraped by the Prometheus Operator from ServiceMonitors (every namespace).
- Dashboards: drop JSON in `cluster/lab/observability/dashboards/`, add
  one entry to its `kustomization.yaml`. Sidecar loads it in seconds.
- Storage on local-path: Prometheus 20Gi / Loki 30Gi / Tempo 10Gi /
  Grafana 5Gi / Alertmanager 2Gi. The "Telemetry Pipeline Health"
  dashboard watches the PVCs.

## Dev platform

Everything a personal dev project needs, one namespace each, waves 5-22.
The Talos VM is sized at 12 GiB for this; `locals.tf` is where that lives.

| Service | In-cluster | From the LAN | Credentials |
|---|---|---|---|
| Postgres (CNPG `dev-db`, db `dev`) | `dev-db-rw.database.svc.cluster.local:5432` | `192.168.18.80:5432` | Secret `database/dev-db-app` |
| pgAdmin | — | `https://pgadmin.lab.ryfoje.com` | Authentik login only |
| RabbitMQ (AMQP) | `rabbitmq.messaging.svc.cluster.local:5672` | `192.168.18.80:5672` | Secret `messaging/rabbitmq-default-user` |
| RabbitMQ management | — | `https://rabbitmq.lab.ryfoje.com` | Authentik, then the Secret above |
| Elasticsearch | `http://elasticsearch-es-http.elastic.svc.cluster.local:9200` | `https://elasticsearch.lab.ryfoje.com` | Secret `elastic/elasticsearch-es-elastic-user`, user `elastic` |
| Kibana | — | `https://kibana.lab.ryfoje.com` | Authentik login only |
| Grafana | — | `https://grafana.lab.ryfoje.com` | "Sign in with Authentik", or the break-glass admin |

Reading a password:

```powershell
kubectl -n database get secret dev-db-app -o jsonpath='{.data.password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

TCP ports 5432 and 5672 are Traefik entrypoints (`traefik.yaml`) routed by an
`IngressRouteTCP` beside each service. Traefik runs hostNetwork, so they are
the real ports on the node IP.

### Authentik in front of things

`cluster/lab/authentik/` holds one Traefik `Middleware` and the blueprints
that create Authentik's side of it: a domain-level proxy provider (one login
cookie for `*.lab.ryfoje.com`, no per-app callback route) bound to the
embedded outpost, plus an OAuth2 provider for Grafana. Blueprints apply
within a minute of the ConfigMap changing; the worker log says which.

Putting any new web UI behind Authentik is one annotation on its Ingress:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forward-auth@kubernetescrd
```

Apps that can trust a header (pgAdmin reads `X-Authentik-Email`) or that can
auto-login a service account (Kibana's anonymous provider) get real SSO from
this. Apps that cannot (RabbitMQ) show their own login after Authentik's.

Grafana roles: Authentik groups `grafana-admins` (akadmin is in it) and
`grafana-editors`; everyone else is a Viewer.

## Hard-coded in more than one place

`locals.tf` is the source of truth for Terraform, but the GitOps side cannot
read it. If you change any of these, grep for the old value:

- node IP `192.168.18.80` — `locals.tf`, `cluster/lab/apps/traefik.yaml`,
  `cluster/lab/apps/kube-prometheus-stack.yaml` (control-plane endpoints)
- domain `lab.ryfoje.com` — `locals.tf`, `cluster/lab/apps/authentik.yaml`,
  `cluster/lab/apps/kube-prometheus-stack.yaml` (ingress hosts, root_url,
  OIDC URLs), `cluster/lab/apps/pgadmin.yaml`, `cluster/lab/authentik/blueprints/*`,
  `cluster/lab/messaging/ingress.yaml`, `cluster/lab/elastic/*.yaml`
- repo URL — `terraform.tfvars`, and every Application whose source is this
  repo: `authentik-db`, `authentik-config`, `database`, `rabbitmq`, `elastic`,
  `observability-dashboards` (all in `cluster/lab/apps/`)
- your Authentik account email — `cluster/lab/apps/pgadmin.yaml` (`env.email`),
  so the header login lands on pgAdmin's admin account
