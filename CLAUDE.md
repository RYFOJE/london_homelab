# london_homelab — working notes for Claude

Single-node Talos-on-Proxmox lab. Terraform builds the VM, LXC resolver and
ArgoCD; ArgoCD owns everything else from `cluster/lab/`. Read `README.md`
for the layout and `DEPLOY.md` for the from-zero runbook.

## Keep DEPLOY.md current (non-negotiable)

`DEPLOY.md` is the complete, ordered list of steps to build the lab from an
empty Proxmox host. Whenever a change alters any of these, update it in the
same commit:

- a new manual/click-ops step (Proxmox, router, Cloudflare, Azure, GitHub, Authentik)
- a new or renamed Terraform variable, output, Key Vault entry or namespace
- a new service with a URL, credential location or client endpoint
- a change to the sync-wave order that affects what to wait for
- anything in `scripts/preflight.ps1`, `scripts/verify.ps1` or
  `scripts/keyvault.ps1` that changes what they check or how they are invoked
- a workaround for a hang, timeout or known bug in the apply path

If you touch `README.md` sections "Run order", "Manual steps", "Dev platform"
or "Hard-coded in more than one place", check whether `DEPLOY.md` says the
same thing. When in doubt, DEPLOY.md is the one the user follows.

## Conventions

- One ArgoCD `Application` per component in `cluster/lab/apps/`, sync-waved.
  Plain manifests live in a sibling directory and get their own Application
  (see `authentik-config`, `database`, `rabbitmq`, `elastic`).
- Credentials never go in git and never in Terraform. Operator-generated
  Secrets (CNPG, RabbitMQ, ECK) or Azure Key Vault via External Secrets: an
  entry in `scripts/keyvault.ps1`'s catalog, an ExternalSecret in
  `cluster/lab/secrets/`, and a row in DEPLOY.md "Secrets" -- all three.
- Pin every chart, git tag and image. Comment *why* a value is set.
- New web UI behind Authentik: the forward-auth annotation, not a new
  provider, unless the app speaks OIDC natively (then a blueprint in
  `cluster/lab/authentik/blueprints/`).
- Files are LF. On this Windows machine, edit with the Edit/Write tools;
  Python or heredoc edits through the shell write CRLF and break yamllint.

## Before saying a change is done

```powershell
cd terraform; terraform fmt -check -recursive; terraform validate; cd ..
python -m yamllint -c .yamllint cluster/ terraform/files/schematic.yaml
```

plus the kubeconform command from `.github/workflows/ci.yml` when manifests
changed, and `helm template` against the pinned chart version when chart
values changed (unknown keys are silently dropped by Helm).
