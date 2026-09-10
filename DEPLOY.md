# Deploying from zero

Every step, click-ops and CLI, to go from an empty Proxmox host to the full
lab: Talos, ArgoCD, Authentik, observability, and the dev platform (Postgres,
pgAdmin, RabbitMQ, Elasticsearch, Kibana). Read top to bottom the first time.
The **Rebuild** and **Change** sections at the end cover the day-two cases.

Time budget: about 1 hour of hands-on work, then 30-45 minutes of waiting.

---

## 0. What you need before starting

| Thing | Where it comes from |
|---|---|
| Proxmox VE host (`boston`) with storages `local` and `local-lvm`, bridge `vmbr0` | your hardware |
| 12.5 GiB RAM free on that host with the lab stopped | Talos VM is 12 GiB (`terraform/locals.tf`) |
| Windows workstation with PowerShell 7 | `winget install Microsoft.PowerShell` |
| Terraform >= 1.9, kubectl, Helm, git | `winget install Hashicorp.Terraform Kubernetes.kubectl Helm.Helm Git.Git` |
| OpenSSH client with the agent service | Windows optional feature "OpenSSH Client" |
| An SSH keypair | `ssh-keygen -t ed25519` |
| This repo, public, on GitHub | ArgoCD clones it anonymously at bootstrap |
| A domain you control on Cloudflare (`ryfoje.com`) | cert-manager writes DNS-01 challenge records there for the `*.lab.ryfoje.com` wildcard |

---

## 1. Proxmox click-ops

1. **API token for Terraform.** Datacenter → Permissions → API Tokens → Add.
   User `root@pam`, Token ID `tf`, **untick Privilege Separation**, Add.
   Copy the secret from the dialog now; it is never shown again.
   The value for tfvars is `root@pam!tf=<secret>`.
2. **Root SSH to the host.** Terraform downloads the LXC template over SSH,
   not the API. Put your public key in `/root/.ssh/authorized_keys` on the
   Proxmox host (Datacenter → node → Shell, or `ssh-copy-id root@<pve-ip>`).
3. **LXC template filename.** In the node Shell run
   `pveam available --section system` and note the current
   `debian-13-standard_*.tar.zst` name. The URL is
   `http://download.proxmox.com/images/system/<that filename>`.
4. **Free RAM.** Node → Summary. Talos wants 12 GiB. If Home Assistant or
   anything else leaves less than that free, stop it for the build, or lower
   `talos.memory` in `terraform/locals.tf` and skip Kibana.
5. **Note the host IP.** You need it as `pve_endpoint`
   (`https://<ip>:8006/`). Use the IP, not a name: nothing resolves names
   until this repo builds the resolver.

## 1b. Cloudflare click-ops

1. Cloudflare dashboard → My Profile → API Tokens → Create Token → use the
   **Edit zone DNS** template.
2. Permissions: `Zone / DNS / Edit` and `Zone / Zone / Read`.
   Zone Resources: Include → Specific zone → `ryfoje.com`.
3. Continue to summary → Create Token. Copy it now; it is shown once. It goes
   in tfvars as `cloudflare_api_token` (step 2). Terraform writes it into the
   cluster; cert-manager uses it to publish `_acme-challenge.lab.ryfoje.com`
   TXT records for a minute during each issuance. No A record is ever
   published; the lab IPs stay in dnsmasq.

---

## 2. Workstation setup

```powershell
git clone https://github.com/RYFOJE/london_homelab.git
cd london_homelab
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Fill in `terraform/terraform.tfvars`:

| Variable | Value |
|---|---|
| `pve_endpoint` | `https://<pve-ip>:8006/` |
| `pve_api_token` | `root@pam!tf=<secret>` from step 1.1 |
| `ssh_public_key_path` | path to the `.pub` of the key you will load in the agent |
| `lxc_template_url` | from step 1.3 |
| `talos_schematic_id` | leave the placeholder; preflight generates it |
| `git_repo_url` | HTTPS URL of your public copy of this repo |
| `cloudflare_api_token` | from step 1b |

`terraform.tfvars` is gitignored. It holds the API token; never commit it.

Load your key into the SSH agent (the Proxmox provider and the dnsmasq
provisioner both authenticate through it):

```powershell
ssh-add ~/.ssh/id_ed25519
ssh-add -l
```

Two edits in the repo before the first push:

1. `cluster/lab/apps/pgadmin.yaml` → `env.email`: the email you will give your
   Authentik admin in step 6. They must match, or pgAdmin creates a second
   non-admin user for you.
2. Anything under "Hard-coded in more than one place" in `README.md` if your
   node IP, domain or repo URL differ from the defaults.

Commit and push. ArgoCD deploys whatever `HEAD` is when it first syncs.

```powershell
git add -A
git commit -m "Lab config"
git push
```

---

## 3. Preflight

```powershell
./scripts/preflight.ps1
```

It checks, in order: Terraform on PATH, the SSH agent service (re-run
elevated with `-FixAgent` if it is stopped), your key loaded, tfvars present,
token format, Proxmox API auth and node name, root SSH to the host, the LXC
template URL, the Talos schematic (generated and written into tfvars if the
placeholder is still there, then the image URL is HEAD-checked), and VMID/IP
collisions with existing guests. Fix every FAIL before continuing; each one
otherwise dies mid-apply with a misleading error.

---

## 4. Build the cluster

```powershell
cd terraform
terraform init
terraform apply
```

Read the plan. On a fresh host it creates: the dnsmasq LXC (110), the Talos
image download, the Talos VM (120), machine config + bootstrap, an apiserver
wait gate, four namespaces and six Secrets, ArgoCD, and the root
Application. Type `yes`. Expect 10-15 minutes.

Known slowness: with the guest agent enabled the Proxmox provider used to sit
on `Refreshing state...` for up to 15 minutes. `talos.tf` now disables the
IP wait (`agent.wait_for_ip.disabled`). If a run still stalls there, Ctrl+C
is safe before the `yes` prompt, and `terraform apply -refresh=false` skips
the refresh.

Two errors you may see on an apply against an *existing* cluster, and what
they mean:

- `dial tcp ...:6443: i/o timeout` / `connection refused` while creating
  Secrets or namespaces: the node was still rebooting. `wait.tf` re-arms the
  apiserver gate after memory, cores or machine-config changes, so this
  should not recur; if it does, wait for `kubectl get nodes` to show Ready
  and run `terraform apply -refresh=false` again.
- `namespaces "<name>" already exists`: ArgoCD created it first (it has
  `CreateNamespace=true`), or the namespace predates Terraform managing it
  (`cert-manager` on clusters built before the TLS change). Adopt it, then
  apply again. The resource name uses an underscore, the namespace a dash:

  ```powershell
  terraform import kubernetes_namespace_v1.cert_manager cert-manager
  ```

When it finishes:

```powershell
terraform output -raw kubeconfig  > ~/.kube/config
terraform output -raw talosconfig > ~/.talos/config
terraform output dns_server_ip
cd ..
```

---

## 5. DNS (router click-ops)

Set your router's DHCP **option 6 / DNS server** to the `dns_server_ip`
output (`192.168.18.70` by default). Renew your workstation's lease:

```powershell
ipconfig /renew
Resolve-DnsName argocd.lab.ryfoje.com
```

If you cannot change the router, set that DNS server on your adapter by hand.
Without this step, nothing under `*.lab.ryfoje.com` resolves from your
machine. The lab resolver forwards everything else to 1.1.1.1 / 8.8.8.8.

---

## 6. Let ArgoCD finish, then Authentik first login

ArgoCD works through the sync waves by itself. Watch:

```powershell
kubectl get applications -n argocd -w
```

First sync takes 20-30 minutes: Elasticsearch, Kibana and the RabbitMQ
operator are large images. `elastic`, `rabbitmq`, `pgadmin` and `authentik`
retry a few times until their dependencies land; the `retry` block on each
Application is doing that on purpose.

When `authentik` is Healthy:

1. Open `https://auth.lab.ryfoje.com/if/flow/initial-setup/`.
2. Set the `akadmin` password. Use the **same email** you put in
   `pgadmin.yaml`.
3. Admin interface → Applications → confirm **Lab services** (proxy provider,
   forward domain) and **Grafana** (OAuth2) exist. Admin interface → Outposts
   → the embedded outpost lists `lab-forward-auth`. These come from the
   blueprints in `cluster/lab/authentik/blueprints/`; if missing:
   `kubectl -n authentik logs deploy/authentik-worker | Select-String blueprint`.

Then:

```powershell
./scripts/verify.ps1
```

Everything should be PASS. `WARN` on "this machine uses the lab resolver"
means step 5 is not done. Section 9 (TLS) says whether Traefik is serving
the Let's Encrypt wildcard yet; issuance takes about two minutes after the
`tls` app syncs, and until then every https page shows a certificate warning
for Traefik's self-signed placeholder. If it stays FAIL:

```powershell
kubectl -n traefik describe certificate lab-wildcard
kubectl get challenges -A
```

A wrong token or zone shows up there as a Cloudflare API error. Fix the
token in tfvars, `terraform apply`, and cert-manager retries on its own. To
debug without touching Let's Encrypt's production rate limits, point
`issuerRef.name` in `cluster/lab/tls/certificate.yaml` at
`letsencrypt-staging` temporarily.

---

## 7. Prove each service

One helper for reading passwords:

```powershell
function Get-K8sSecret($ns, $name, $key) {
  kubectl -n $ns get secret $name -o jsonpath="{.data.$key}" |
    % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
}
```

| Check | Expect |
|---|---|
| `https://argocd.lab.ryfoje.com` | ArgoCD login. Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'` (base64) |
| `https://grafana.lab.ryfoje.com` → Sign in with Authentik | You land as Admin (group `grafana-admins`). Break-glass: user `admin`, `terraform output -raw grafana_admin_password` |
| `https://pgadmin.lab.ryfoje.com` | Authentik page once, then pgAdmin logged in. Expand `dev-db`, paste `Get-K8sSecret database dev-db-app password`, tick Save |
| `https://kibana.lab.ryfoje.com` | Authentik page once, then Kibana with no login form |
| `https://rabbitmq.lab.ryfoje.com` | Authentik page, then RabbitMQ's own login: `Get-K8sSecret messaging rabbitmq-default-user username` / `password` |
| `https://elasticsearch.lab.ryfoje.com/_cluster/health` | HTTP 401 unauthenticated; `curl.exe -u elastic:<pw>` gives `"status":"green"`. Password: `Get-K8sSecret elastic elasticsearch-es-elastic-user elastic` |
| `psql -h 192.168.18.80 -U dev dev` | connects with the dev-db-app password |
| AMQP `amqp://<user>:<pw>@192.168.18.80:5672/` | connects with the rabbitmq-default-user values |
| `https://prometheus.lab.ryfoje.com/targets` | `rabbitmq` PodMonitor up, everything green except etcd (off by design) |

In-cluster names for your own workloads are in the README "Dev platform"
table.

---

## 8. Back up what cannot be regenerated

- `terraform/terraform.tfstate` and `.backup`: Talos machine secrets,
  Authentik signing key, Grafana admin + OIDC secret, Kibana anonymous
  password, pgAdmin bootstrap password. Encrypt, store off this machine.
  Lose it and the next apply builds a *new* cluster with new identities.
- The Proxmox API token and Cloudflare token.
- `~/.kube/config` and `~/.talos/config` regenerate from state via
  `terraform output`, so they do not need separate backups.

---

## Rebuild (disposable by design)

Data does not survive this. Everything in git and tfstate does.

```powershell
cd terraform
terraform destroy
terraform apply
terraform output -raw kubeconfig  > ~/.kube/config
terraform output -raw talosconfig > ~/.talos/config
cd ..
./scripts/verify.ps1
```

Then step 6 (Authentik initial setup again: its database was on the VM).
Router DNS does not change; the LXC gets the same IP.

## Change (day two)

- **GitOps side** (`cluster/`): commit, push, ArgoCD applies within ~3
  minutes. `./scripts/verify.ps1` afterwards.
- **Terraform side**: `terraform apply` from `terraform/`. Changing
  `talos.memory` or `cores` reboots the VM once (the provider reports it done
  in ~5 minutes, then the apiserver gate waits for Kubernetes to be back);
  every pod shows Pending with "node(s) were unschedulable" for a minute or
  two while Talos drains and uncordons. ArgoCD reconnects by itself.
  Machine-config changes (sysctls, nameservers) apply live.
- **New web UI behind Authentik**: one Ingress annotation, see README
  "Authentik in front of things".
- **A pushed fix never arrives, root app stuck `OutOfSync / Progressing`**:
  root syncs children in wave order and a running sync waits for each wave
  to be Healthy before touching the next. If the thing that is unhealthy can
  only be fixed by a commit, that commit is never applied: the old sync
  blocks the new one. Check with
  `kubectl get application root -n argocd -o jsonpath='{.status.operationState.message}'`
  (it says "waiting for healthy state of ..."). Terminate the stuck
  operation; automated sync restarts on the current commit within seconds:

  ```powershell
  kubectl -n argocd patch application root --type=merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
  ```

  (No `--subresource=status`: the Application CRD has none, and kubectl
  answers "not found" instead of saying so.)

  Seen once with node-exporter Pending on a host-port clash with Traefik.
- **New Grafana dashboard**: JSON into `cluster/lab/observability/dashboards/`
  plus one entry in its `kustomization.yaml`.
