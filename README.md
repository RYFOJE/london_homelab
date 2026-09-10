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
  secrets.tf          Authentik signing key + Grafana admin (kept in tfstate)
  bootstrap.tf        argo-cd + argocd-apps root Application -> cluster/lab/apps
cluster/lab/apps/     one ArgoCD Application per platform component (sync-waved)
cluster/lab/db/       plain manifests the apps reference (CNPG Cluster)
cluster/lab/observability/dashboards/  Grafana dashboards as code (kustomize -> ConfigMaps)
scripts/              preflight.ps1 (before apply), verify.ps1 (after)
```

## Run order

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
3. Cloudflare API token for DNS-01 (once the ClusterIssuer exists).
4. This repo, public, at `git_repo_url`.

## Back this up or you cannot rebuild

- `terraform.tfstate` — contains Talos machine secrets, the Authentik
  signing key and the Grafana admin password. Encrypt it. Never commit it.
- `kubeconfig` / `talosconfig` (regenerable from state via `terraform output`).
- Proxmox and Cloudflare API tokens.

## Known gaps

- No ClusterIssuer yet: ArgoCD and Authentik are served over plain HTTP.
- External Secrets is deployed without a `ClusterSecretStore`.
- No CoreDNS forward for the lab domain: in-cluster clients cannot resolve
  `*.lab.<domain>` (needed before ArgoCD -> Authentik OIDC).
- Grafana SSO is wired but commented out in `kube-prometheus-stack.yaml`
  until an Authentik provider blueprint and the `grafana-oidc` Secret exist.
- etcd metrics are off: they need client certs from `/system/secrets/etcd`
  in a Secret plus `listen-metrics-urls` in the Talos patch. Enable together.

## Observability

kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Tempo and
Grafana Alloy, all in the `observability` namespace, waves 15-30.

- Grafana: `http://grafana.lab.ryfoje.com` — local admin password:
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

## Hard-coded in more than one place

`locals.tf` is the source of truth for Terraform, but the GitOps side cannot
read it. If you change any of these, grep for the old value:

- node IP `192.168.18.80` — `locals.tf`, `cluster/lab/apps/traefik.yaml`,
  `cluster/lab/apps/kube-prometheus-stack.yaml` (control-plane endpoints)
- domain `lab.ryfoje.com` — `locals.tf`, `cluster/lab/apps/authentik.yaml`,
  `cluster/lab/apps/kube-prometheus-stack.yaml` (three ingress hosts + root_url)
- repo URL — `terraform.tfvars`, `cluster/lab/apps/authentik-db.yaml`,
  `cluster/lab/apps/observability-dashboards.yaml`
