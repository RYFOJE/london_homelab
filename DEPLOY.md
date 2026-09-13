# Deploying from zero

Every step, click-ops and CLI, to go from an empty Proxmox host to the full
lab: Talos, ArgoCD, Authentik, observability, and the dev platform (Postgres,
pgAdmin, RabbitMQ, Elasticsearch, Kibana, Valkey, Mailpit, KEDA). Read top
to bottom the first time.
The **Rebuild**, **Migrating** and **Change** sections at the end cover the
day-two cases; **Secrets** is the catalog of every credential.

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
| An Azure subscription and the Azure CLI | every credential lives in one of two Key Vaults (`winget install Microsoft.AzureCLI`) |

---

## 1. Proxmox click-ops

1. **API token for Terraform.** Datacenter → Permissions → API Tokens → Add.
   User `root@pam`, Token ID `tf`, **untick Privilege Separation**, Add.
   Copy the secret from the dialog now; it is never shown again. Step 1d's
   script prompts for it as `root@pam!tf=<secret>` and stores it in Key
   Vault; it goes in no local file.
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
3. Continue to summary → Create Token. Copy it now; it is shown once. Step
   1d's script asks for it and stores it in the ESO vault; External Secrets
   copies it into the cluster, and cert-manager uses it to publish
   `_acme-challenge.lab.ryfoje.com` TXT records for a minute during each
   issuance. No A record is ever published; the lab IPs stay in dnsmasq.

---

## 1c. GitHub click-ops: Renovate

1. Install the Renovate GitHub App: <https://github.com/apps/renovate> →
   Install → select this repository only.
2. That is all; `renovate.json` in the repo is the configuration. Within an
   hour it opens a "Dependency Dashboard" issue listing every pinned chart,
   image and tag it found. From then on: minor/patch updates under
   `cluster/` are merged automatically once the release is **14 days old**
   and CI is green (ArgoCD applies them); majors and anything under
   `terraform/` stay as PRs for you, because those need a `terraform apply`.
3. Branch protection on `main` is optional. If you add it, require the CI
   checks and allow the Renovate app to bypass PR review, or automerge
   never fires.

## 1d. Azure Key Vault (scripted)

Two Key Vaults, deliberately separate:

- the **ESO vault** (`kv-ryfoje-eso`) -- the Cloudflare token, Authentik's
  signing key, the Grafana admin, every OIDC client secret, Valkey's
  password. Everything External Secrets Operator (ESO) copies into the
  cluster. Its service principal can read this vault and nothing else.
- the **Terraform vault** (`kv-ryfoje-tf`) -- ESO's own client id/secret,
  and the Proxmox API token. Only Terraform reads it (through your
  `az login`), and the ESO service principal has no role on it at all. If
  that SP were ever compromised, it still can't read the Proxmox token or
  hand itself a new login.

The same script also creates the storage account tfstate lives in. The full
credential list is in [Secrets](#secrets) below.

```powershell
az login
./scripts/keyvault.ps1
```

The script creates resource group `london-homelab`, both vaults (RBAC mode,
`canadacentral`), a service principal with read-only access to the ESO vault
only, storage account `stryfojelab` with blob container `tfstate`
(versioning and 30-day soft delete on), and every catalog entry: generated
where it can be, and prompts for the Proxmox token from step 1.1 and the
Cloudflare token from step 1b. It is idempotent -- existing entries are kept
-- and prints three tfvars lines, the `tenantId`/`vaultUrl` it ended up with,
and three backend.hcl lines. All three names (both vaults, the storage
account) are global: if a default is taken, pass `-VaultName <other>` /
`-EsoVaultName <other>` / `-StateStorageAccount <other>` and use the printed
values everywhere they're asked for below.

"InteractionRequired" from the script means the Azure CLI session has a
stale Graph token: `az login` again.

## 2. Workstation setup

```powershell
git clone https://github.com/RYFOJE/london_homelab.git
cd london_homelab
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
cp terraform/backend.hcl.example terraform/backend.hcl
```

Fill in `terraform/terraform.tfvars`:

| Variable | Value |
|---|---|
| `pve_endpoint` | `https://<pve-ip>:8006/` |
| `ssh_public_key_path` | path to the `.pub` of the key you will load in the agent |
| `lxc_template_url` | from step 1.3 |
| `talos_schematic_id` | leave the placeholder; preflight generates it |
| `git_repo_url` | HTTPS URL of your public copy of this repo |
| `azure_subscription_id` | printed by `keyvault.ps1` (`az account show --query id -o tsv`) |
| `azure_key_vault_name` | printed by `keyvault.ps1`; the **Terraform vault**, `kv-ryfoje-tf` unless you changed it -- NOT the ESO vault |
| `azure_key_vault_resource_group` | printed by `keyvault.ps1`; `london-homelab` unless you changed it |

Nothing in `terraform.tfvars` is secret (it is gitignored anyway). The
Proxmox token and the operator's login are read from the Terraform vault
through your `az login` session at plan time. A leftover `pve_api_token` line from an
older checkout only produces an "undeclared variable" warning; delete it.

Fill in `terraform/backend.hcl` (also gitignored, also nothing secret in it --
see the comment in `backend.hcl.example`) with the three lines
`./scripts/keyvault.ps1` printed under "Paste into terraform/backend.hcl":
`resource_group_name`, `storage_account_name`, `container_name`. State lives
in that blob container instead of a local `.tfstate` file, so it survives a
wiped workstation and two people can `apply` from the same state.

Load your key into the SSH agent (the Proxmox provider and the dnsmasq
provisioner both authenticate through it):

```powershell
ssh-add ~/.ssh/id_ed25519
ssh-add -l
```

Three edits in the repo before the first push:

1. `cluster/lab/apps/pgadmin.yaml` → `env.email` and
   `cluster/lab/authentik/blueprints/akadmin.yaml` → `email`: same address in
   both, or pgAdmin creates a second non-admin user for you.
2. `cluster/lab/secrets/clustersecretstore.yaml` → `tenantId` and `vaultUrl`
   must be what `keyvault.ps1` printed (`vaultUrl` is the **ESO vault**, not
   the Terraform one).
3. Anything under "Hard-coded in more than one place" in `README.md` if your
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
elevated with `-FixAgent` if it is stopped), your key loaded, tfvars and
backend.hcl present, the public key at `ssh_public_key_path` actually
existing (the agent holding *a* key does not mean tfvars names the right
one), the storage account reachable, the Proxmox token
readable from the Terraform vault and well-formed, Proxmox API auth and node
name, root SSH to the host, the LXC template URL, the Talos schematic
(generated and written into tfvars if the placeholder is still there, then
the image URL is HEAD-checked), the Azure login, that the Terraform vault
holds ESO's login and the Proxmox token, that the ESO vault (read from
`clustersecretstore.yaml`'s `vaultUrl`) holds every entry the ExternalSecrets
in `cluster/lab/secrets/` ask for, and VMID/IP collisions with existing
guests. Fix every FAIL before continuing; each one otherwise dies mid-apply
with a misleading error.

---

## 4. Build the cluster

```powershell
cd terraform
terraform init -backend-config="backend.hcl"
terraform apply
```

Read the plan. On a fresh host it creates: the dnsmasq LXC (110), the Talos
image download, the Talos VM (120), machine config + bootstrap, an apiserver
wait gate, ArgoCD, one Secret (`argocd/azure-keyvault-creds`, ESO's login,
read from the Terraform vault at plan time), and the root Application.
Nothing else in the cluster is Terraform's. Type `yes`. Expect 10-15 minutes.

Known slowness: with the guest agent enabled the Proxmox provider used to sit
on `Refreshing state...` for up to 15 minutes. That wait is now gated off by
`var.proxmox_agent_wait` (default `false`); opt in with
`terraform apply -var proxmox_agent_wait=true` if you ever want the provider
to poll the agent. If a run still stalls, Ctrl+C is safe before the `yes`
prompt, and `terraform apply -refresh=false` skips the refresh entirely.

Two errors you may see on an apply against an *existing* cluster, and what
they mean:

- `dial tcp ...:6443: i/o timeout` / `connection refused` while creating
  Secrets or namespaces: the node was still rebooting. `wait.tf` re-arms the
  apiserver gate after memory, cores or machine-config changes, so this
  should not recur; if it does, wait for `kubectl get nodes` to show Ready
  and run `terraform apply -refresh=false` again.
- `building account: ... AzureCLI` / `InteractionRequired` from the azurerm
  provider during plan: the `az login` session expired. Log in again and
  re-run; nothing was changed.
- `A resource with the ID ... KeyVault ... was not found` / `Forbidden` on
  `data.azurerm_key_vault_secret`: wrong Terraform-vault name in tfvars, or
  your account lost its role on it. `./scripts/keyvault.ps1` fixes both.
- `Error: Failed to get existing workspaces` / `Forbidden` during
  `terraform init -backend-config="backend.hcl"`: wrong storage account name in
  backend.hcl, or you lack Storage Blob Data Contributor on it.
  `./scripts/keyvault.ps1` fixes both. RBAC just granted can take a couple of
  minutes to propagate -- retry once before assuming it's wrong.

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

**IPv6 silently beats all of this.** If your router advertises itself as a DNS
server over IPv6 (router advertisement / RDNSS), Windows prefers it and never
asks the IPv4 resolver, so `*.lab.ryfoje.com` fails even though the adapter
lists `192.168.18.70` and `Resolve-DnsName -Server 192.168.18.70 <name>`
answers correctly. `nslookup <name>` naming an `fe80::` server is the tell:

```powershell
nslookup argocd.lab.ryfoje.com     # "Server: UnKnown / Address: fe80::..." = the router, over IPv6
```

The fix that costs nothing else: an NRPT (Name Resolution Policy Table) rule
sending just this namespace to the lab resolver. NRPT is consulted before
adapter DNS, so it beats the IPv6 server without turning IPv6 off, and the
leading dot makes it match every subdomain. Elevated, once, persists across
reboots:

```powershell
Add-DnsClientNrptRule -Namespace ".lab.ryfoje.com" -NameServers "192.168.18.70"
```

Check it, and undo it, with:

```powershell
Get-DnsClientNrptRule
Get-DnsClientNrptRule | Where-Object Namespace -eq ".lab.ryfoje.com" | Remove-DnsClientNrptRule -Force
```

The blunter alternatives: turn off DNS advertisement over IPv6 on the router
(RDNSS), or disable IPv6 on the adapter entirely -- elevated, and it affects
all traffic on that adapter, not just DNS:

```powershell
Disable-NetAdapterBinding -Name "Wi-Fi" -ComponentID ms_tcpip6
```

`verify.ps1` checks this by resolving without `-Server` and comparing the
answer, so it catches the case where the resolver is configured but unused.

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

The first apps to watch are `namespaces`, `external-secrets` and `secrets`
(waves -20, -8, -6). If `secrets` sits at Degraded, nothing after it will
start; the reason is in the ExternalSecret's status:

```powershell
kubectl get externalsecrets -A
kubectl -n authentik describe externalsecret authentik-secret-key
```

"SecretSyncedError ... 403" is the service principal lacking access (re-run
`keyvault.ps1`); "not found" is a vault entry missing (same fix); an auth
error against `login.microsoftonline.com` is a wrong `tenantId` in
`clustersecretstore.yaml`.

When `authentik` is Healthy, log in at `https://auth.lab.ryfoje.com` as
`akadmin` (`./scripts/credentials.ps1 -Only akadmin`) -- no
`/if/flow/initial-setup/` step, the password comes from Key Vault via
`blueprints/akadmin.yaml`. Then Admin interface → Applications → confirm
**Lab services** (proxy provider, forward domain), **Grafana** and **ArgoCD**
(OAuth2) exist. Admin interface → Outposts → the embedded outpost lists
`lab-forward-auth`. These come from the blueprints in
`cluster/lab/authentik/blueprints/`; if missing:
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

A wrong token or zone shows up there as a Cloudflare API error. Fix it with
`./scripts/keyvault.ps1 -Rotate -Only cloudflare-api-token`, force-sync the
ExternalSecret (command under [Secrets](#secrets)), and cert-manager retries
on its own. To
debug without touching Let's Encrypt's production rate limits, point
`issuerRef.name` in `cluster/lab/tls/certificate.yaml` at
`letsencrypt-staging` temporarily.

---

## 7. Prove each service

Every credential in one table, plus ready-made connection strings:

```powershell
./scripts/credentials.ps1
./scripts/credentials.ps1 -Only postgres
```

The `Get-K8sSecret` calls in the table below are what it does per row.

```powershell
function Get-K8sSecret($ns, $name, $key) {
  kubectl -n $ns get secret $name -o jsonpath="{.data.$key}" |
    % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
}
```

| Check | Expect |
|---|---|
| `https://argocd.lab.ryfoje.com` → Log in via Authentik | You land as admin (group `argocd-admins`). Break-glass: user `admin`, `./scripts/credentials.ps1 -Only argocd` |
| `https://mailpit.lab.ryfoje.com` | Authentik page once, then the inbox. Send a test: `Send-MailMessage -SmtpServer 192.168.18.80 -Port 1025 -From a@b -To c@d -Subject hi -Body hi` |
| `redis-cli -h 192.168.18.80 -a <pw> ping` | `PONG`; password from `./scripts/credentials.ps1 -Only valkey` |
| `https://grafana.lab.ryfoje.com` → Sign in with Authentik | You land as Admin (group `grafana-admins`). Break-glass: user `admin`, `./scripts/credentials.ps1 -Only grafana` |
| `https://pgadmin.lab.ryfoje.com` | Authentik page once, then pgAdmin logged in. Expand `dev-db`, paste `Get-K8sSecret database dev-db-app password`, tick Save |
| `https://kibana.lab.ryfoje.com` | Authentik page once, then Kibana with no login form |
| `https://rabbitmq.lab.ryfoje.com` | Authentik page, then RabbitMQ's own login: `Get-K8sSecret messaging rabbitmq-default-user username` / `password` |
| `https://elasticsearch.lab.ryfoje.com/_cluster/health` | HTTP 401 unauthenticated; `curl.exe -u elastic:<pw>` gives `"status":"green"`. Password: `Get-K8sSecret elastic elasticsearch-es-elastic-user elastic` |
| `psql -h 192.168.18.80 -U dev dev` | connects with the dev-db-app password |
| AMQP `amqp://<user>:<pw>@192.168.18.80:5672/` | connects with the rabbitmq-default-user values |
| `https://prometheus.lab.ryfoje.com/targets` | `rabbitmq` PodMonitor and the three `keda-*` ServiceMonitors up, everything green except etcd (off by design) |
| `kubectl get apiservice v1beta1.external.metrics.k8s.io` | `AVAILABLE` is `True` (KEDA's metrics server; `verify.ps1` section 5 checks the same). No credentials: KEDA has no UI. The README "Autoscaling with KEDA" example is the end-to-end test |

In-cluster names for your own workloads are in the README "Dev platform"
table.

---

## 8. Back up what cannot be regenerated

- Both Key Vaults are the credential store, and Azure keeps them:
  soft-delete is on, so a deleted vault (or entry) is recoverable for 90
  days with `az keyvault recover`. Nothing to copy anywhere.
- tfstate lives in the `tfstate` blob container, not on this machine:
  Talos machine secrets, plus a plain-text copy of the operator's Key Vault
  login and the Proxmox token (the data source results). Blob versioning
  and 30-day soft delete are on (`./scripts/keyvault.ps1` sets both), so a
  bad `apply` or an accidental delete is a version restore or
  `az storage blob undelete` away, not a lost cluster. Still Azure's only
  copy -- nothing else to back it up, but nothing on this workstation to
  lose either.
- Nothing else: the Proxmox and Cloudflare tokens are both in the vault.
- `~/.kube/config` and `~/.talos/config` regenerate from state via
  `terraform output`, so they do not need separate backups.

---

## Secrets

Everything the lab authenticates with, and where each value comes from.
Three files are the same list: this table, the catalogs in
`scripts/keyvault.ps1` (writes both vaults), and `cluster/lab/secrets/*.yaml`
(one ExternalSecret per cluster Secret). Adding a credential means all three.

Two vaults: the **Terraform vault** (`kv-ryfoje-tf` by default) holds only
the first two rows below, read by Terraform through your `az login`; the
**ESO vault** (`kv-ryfoje-eso`) holds everything else, read by the ESO
service principal, which has no access to the Terraform vault at all.

| Vault | Vault entry | Cluster Secret (namespace/name → keys) | Read by | Origin |
|---|---|---|---|---|
| Terraform | `eso-client-id`, `eso-client-secret` | `argocd/azure-keyvault-creds` → `client-id`, `client-secret` | External Secrets Operator (`ClusterSecretStore azure-keyvault`) | service principal `london-homelab-external-secrets`; **written by Terraform**, the only Secret it owns |
| Terraform | `pve-api-token` | none -- never enters the cluster | Terraform's proxmox provider, `preflight.ps1`, `verify.ps1` (all through `az login`) | **prompted**: `root@pam!tf=<secret>` from step 1.1 |
| ESO | `cloudflare-api-token` | `cert-manager/cloudflare-api-token` → `api-token` | both ClusterIssuers (`cluster/lab/tls`) | **prompted**: Cloudflare token from step 1b |
| ESO | `authentik-secret-key` | `authentik/authentik-secret-key` → `secret-key` | Authentik (`AUTHENTIK_SECRET_KEY`); signs sessions and user IDs -- never rotate casually | generated, 64 |
| ESO | `akadmin-password` | `authentik/authentik-blueprint-env` → `akadmin-password` | Authentik blueprint (`akadmin.yaml`, `!Env`); sets the `akadmin` login | generated, 32 |
| ESO | `grafana-admin-password` | `observability/grafana-admin` → `admin-user`=`admin`, `admin-password` | Grafana break-glass login | generated, 32 |
| ESO | `grafana-oidc-client-secret` | `observability/grafana-oidc` → `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`=`grafana`, `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`; and `authentik/authentik-blueprint-env` → `grafana-oidc-client-secret` | Grafana (envFromSecret) and the Authentik blueprint (`!Env`) -- one value, both sides | generated, 64 |
| ESO | `argocd-oidc-client-secret` | `argocd/argocd-oidc` → `oidc.clientSecret` (labelled `part-of=argocd`); and `authentik/authentik-blueprint-env` → `argocd-oidc-client-secret` | ArgoCD `oidc.config` and the Authentik blueprint | generated, 64 |
| ESO | `kibana-anonymous-password` | `elastic/kibana-anonymous` (basic-auth) → `username`=`kibana-anon`, `password`, `roles`=`superuser` | ECK file realm + Kibana anonymous provider | generated, 32 |
| ESO | `pgadmin-admin-password` | `database/pgadmin-admin` → `password` | pgAdmin bootstrap admin (never typed) | generated, 32 |
| ESO | `valkey-password` | `dev/valkey-auth` → `password` | Valkey `--requirepass`; LAN-exposed on :6379 | generated, 32 |

Not in either vault, and not in git either -- generated in-cluster by their
operators, so they change on every rebuild: `authentik/authentik-db-app` and
`database/dev-db-app` (CNPG), `messaging/rabbitmq-default-user` (RabbitMQ),
`elastic/elasticsearch-es-elastic-user` (ECK), `argocd/argocd-initial-admin-secret`
(ArgoCD), `traefik/lab-wildcard-tls` and the ACME account keys (cert-manager).
`./scripts/credentials.ps1` prints all of them decoded.

ExternalSecrets refresh from the vault every hour. To pick up a change now:

```powershell
kubectl -n dev annotate externalsecret valkey-auth force-sync=$(Get-Date -UFormat %s) --overwrite
```

---

## Rebuild (disposable by design)

Data does not survive this. Everything in git, tfstate and the Key Vault
does -- so every password comes back unchanged.

```powershell
cd terraform
terraform destroy
terraform apply
terraform output -raw kubeconfig  > ~/.kube/config
terraform output -raw talosconfig > ~/.talos/config
cd ..
./scripts/verify.ps1
```

Then step 6 (ArgoCD sync again: Authentik's database was on the VM, but
`akadmin`'s password comes back from Key Vault with it). Router DNS does not
change; the LXC gets the same IP.

## Migrating an existing cluster to Key Vault

For a cluster built when Terraform still generated the passwords. The point
of the order below is that no password changes and nothing restarts.

1. `az login`, then copy the live values into two new vaults:

   ```powershell
   ./scripts/keyvault.ps1 -FromCluster
   ```

   (`-FromCluster` reads the existing Secrets through kubectl into the ESO
   vault; the Cloudflare token comes from the cluster too, so no prompt.
   `akadmin-password` has nothing to copy on a cluster built before this
   entry existed, so it generates a new one -- `akadmin`'s password changes.
   The Proxmox token was never in the cluster and goes in the Terraform
   vault instead: it prompts for that one, paste the `pve_api_token` value
   from your old tfvars.)
2. Put the three `azure_*` values it printed in `terraform.tfvars`, drop
   `cloudflare_api_token` and `pve_api_token` from it, and make sure
   `cluster/lab/secrets/clustersecretstore.yaml` has the printed
   `tenantId`/`vaultUrl`. Commit and push.
3. ArgoCD picks the push up within ~3 minutes: `external-secrets` upgrades
   (its old v1beta1 CRDs are empty, so the CRD update just goes through),
   `namespaces` adopts the namespaces Terraform created, `secrets` applies
   the ExternalSecrets -- which go **Degraded with "secret already exists,
   not owned"**. Expected: the old Terraform-written Secrets are in the way.
4. Hand them over. Terraform first, so it forgets them instead of deleting
   them (`terraform/removed.tf` does that), then delete the old copies so
   ESO can recreate them with the same values:

   ```powershell
   cd terraform; terraform init -backend-config="backend.hcl"; terraform apply; cd ..
   ```

   ```powershell
   kubectl -n authentik delete secret authentik-secret-key authentik-blueprint-env
   kubectl -n observability delete secret grafana-admin grafana-oidc
   kubectl -n elastic delete secret kibana-anonymous
   kubectl -n database delete secret pgadmin-admin
   kubectl -n cert-manager delete secret cloudflare-api-token
   kubectl -n argocd delete secret argocd-oidc
   kubectl -n dev delete secret valkey-auth
   ```

   ESO recreates each within a minute. Running pods never notice: they read
   env vars at start, and the values are identical. ArgoCD's OIDC login is
   the one live reader and is back as soon as `argocd/argocd-oidc` is.
5. `./scripts/verify.ps1` -- section 6 lists every ExternalSecret. Then
   delete `terraform/removed.tf` and commit; it was a one-shot.

## Change (day two)

- **GitOps side** (`cluster/`): commit, push, ArgoCD applies within ~3
  minutes. `./scripts/verify.ps1` afterwards. To skip the wait:

  ```powershell
  kubectl -n argocd annotate application root argocd.argoproj.io/refresh=normal --overwrite
  ```

  (`refresh=hard` also drops cached manifests.) If an app sits OutOfSync
  and automation does not act, force one sync:

  ```powershell
  kubectl -n argocd patch application <name> --type=merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD","prune":true}}}'
  ```
- **Terraform side**: `terraform apply` from `terraform/`. Changing
  `talos.memory` or `cores` reboots the VM once (the provider reports it done
  in ~5 minutes, then the apiserver gate waits for Kubernetes to be back);
  every pod shows Pending with "node(s) were unschedulable" for a minute or
  two while Talos drains and uncordons. ArgoCD reconnects by itself.
  Machine-config changes (sysctls, nameservers) apply live.
- **New web UI behind Authentik**: one Ingress annotation, see README
  "Authentik in front of things".
- **New credential**: add it to the catalog in `scripts/keyvault.ps1` and run
  the script (existing entries are untouched), add an ExternalSecret under
  `cluster/lab/secrets/`, add the row to "Secrets" above. Never a
  `random_password` in Terraform, never a value in git.
- **Rotating a credential**: `./scripts/keyvault.ps1 -Rotate -Only <name>`,
  force-sync the ExternalSecret (command under "Secrets") or wait an hour,
  then restart the consumer -- `kubectl -n <ns> rollout restart deploy/<x>`.
  Values used on two sides (the OIDC client secrets) update both Secrets
  from the one vault entry; restart both consumers. Never rotate
  `authentik-secret-key` on a cluster you want to keep logging in to.
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
