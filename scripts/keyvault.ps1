#Requires -Version 7.0
<#
.SYNOPSIS
    Create the Azure Key Vault the lab reads its credentials from, and fill it.

.DESCRIPTION
    Idempotent. Run it once before the first `terraform apply`, and again any
    time you add a credential to the catalog below. It:

      1. creates the resource group and the Key Vault (RBAC mode) if missing
      2. gives YOU "Key Vault Secrets Officer" on it, so you can write
      3. creates the app registration + service principal External Secrets
         Operator logs in as, and gives it "Key Vault Secrets User" (read)
      4. writes the SP's client id/secret into the vault (Terraform reads
         those two and nothing else -- terraform/secrets.tf)
      5. writes every lab credential in $Catalog: generated, prompted for
         (the Cloudflare token), or copied from the running cluster

    Entries that already exist are left alone unless -Rotate is given. The
    catalog here, the ExternalSecrets in cluster/lab/secrets/ and the table in
    DEPLOY.md "Secrets" are the same list three ways; change all three.

.PARAMETER FromCluster
    Copy current values from the running cluster (kubectl) instead of
    generating new ones. For migrating a cluster that was built before Key
    Vault, so nothing rotates. Entries not found in the cluster are generated.

.PARAMETER Rotate
    Overwrite entries that already exist. Combine with -Only to rotate one.
    Restart whatever reads it afterwards (DEPLOY.md "Rotating a credential").

.PARAMETER Only
    Restrict to these catalog names, e.g. -Only valkey-password.

.EXAMPLE
    az login
    ./scripts/keyvault.ps1
    ./scripts/keyvault.ps1 -FromCluster
    ./scripts/keyvault.ps1 -Rotate -Only grafana-admin-password
#>
[CmdletBinding()]
param(
    # Globally unique; also the host in vaultUrl in
    # cluster/lab/secrets/clustersecretstore.yaml.
    [string]$VaultName = 'kv-ryfoje-lab',
    [string]$ResourceGroup = 'london-homelab',
    [string]$Location = 'uksouth',
    # Display name of the app registration ESO authenticates as.
    [string]$AppName = 'london-homelab-external-secrets',
    [switch]$FromCluster,
    [switch]$Rotate,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- catalog
# Name        : the Key Vault secret name (also remoteRef.key in cluster/lab/secrets)
# Cluster     : ns/secret/key to copy from with -FromCluster
# Prompt      : ask for the value instead of generating (external credentials)
# Length      : generated length; alphanumeric only, so no quoting bugs in env vars
$Catalog = @(
    @{ Name = 'cloudflare-api-token';       Prompt = 'Cloudflare API token (Zone/DNS/Edit + Zone/Zone/Read on the lab zone)';
       Cluster = 'cert-manager/cloudflare-api-token/api-token' }
    @{ Name = 'authentik-secret-key';       Length = 64; Cluster = 'authentik/authentik-secret-key/secret-key' }
    @{ Name = 'grafana-admin-password';     Length = 32; Cluster = 'observability/grafana-admin/admin-password' }
    @{ Name = 'grafana-oidc-client-secret'; Length = 64; Cluster = 'observability/grafana-oidc/GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET' }
    @{ Name = 'argocd-oidc-client-secret';  Length = 64; Cluster = 'argocd/argocd-oidc/oidc.clientSecret' }
    @{ Name = 'kibana-anonymous-password';  Length = 32; Cluster = 'elastic/kibana-anonymous/password' }
    @{ Name = 'pgadmin-admin-password';     Length = 32; Cluster = 'database/pgadmin-admin/password' }
    @{ Name = 'valkey-password';            Length = 32; Cluster = 'dev/valkey-auth/password' }
)

function Step { param([string]$T) Write-Host ''; Write-Host $T -ForegroundColor White }
function Ok   { param([string]$T) Write-Host "  [ok]   $T" -ForegroundColor Green }
function Info { param([string]$T) Write-Host "  [..]   $T" -ForegroundColor DarkGray }
function Warn { param([string]$T) Write-Host "  [warn] $T" -ForegroundColor Yellow }

function Invoke-Az {
    <#  az with the exit code checked. Errors from az go to stderr, which
        PowerShell 7 turns into a terminating error under $ErrorActionPreference
        = Stop even for warnings; capture and decide on the exit code instead. #>
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Args -join ' ')`n$($out -join "`n")"
    }
    return ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
}

function Test-Az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    & az @Args *> $null
    return $LASTEXITCODE -eq 0
}

function New-RandomSecret {
    param([int]$Length)
    $alphabet = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Get-ClusterSecret {
    param([string]$Ref)   # ns/secret/key
    $ns, $name, $key = $Ref -split '/', 3
    # jsonpath needs dots escaped: oidc.clientSecret -> oidc\.clientSecret
    $jp = '{.data.' + ($key -replace '\.', '\.') + '}'
    $b64 = & kubectl -n $ns get secret $name -o jsonpath=$jp 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $b64) { return $null }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function Set-VaultSecret {
    <#  RBAC assignments take a minute or two to propagate; the first write
        after granting yourself Secrets Officer often 403s. Retry, do not fail. #>
    param([string]$Name, [string]$Value)
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        & az keyvault secret set --vault-name $VaultName --name $Name --value $Value --only-show-errors *> $null
        if ($LASTEXITCODE -eq 0) { return }
        if ((Get-Date) -gt $deadline) { throw "could not write $Name to $VaultName after 5 minutes (RBAC not propagated, or wrong vault?)" }
        Info "write of $Name refused (RBAC still propagating?) -- retrying in 15s"
        Start-Sleep -Seconds 15
    }
}

function Test-VaultSecret {
    param([string]$Name)
    return (Test-Az keyvault secret show --vault-name $VaultName --name $Name --only-show-errors)
}

# ---------------------------------------------------------------- session
Step 'Azure session'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az not found -- winget install Microsoft.AzureCLI, then az login'
}
try { $account = Invoke-Az account show -o json | ConvertFrom-Json }
catch { throw 'not logged in -- run: az login' }
$subscriptionId = $account.id
$tenantId = $account.tenantId
Ok "subscription $($account.name) ($subscriptionId), tenant $tenantId"
# Every `az ad` call needs a Graph token; a stale session fails those with
# "InteractionRequired" even though `az account show` works.
if (-not (Test-Az ad signed-in-user show --only-show-errors)) {
    throw 'Graph token expired -- run: az login   (then re-run this script)'
}
$me = Invoke-Az ad signed-in-user show --query id -o tsv

# ---------------------------------------------------------------- vault
Step "Key Vault $VaultName in $ResourceGroup ($Location)"
if (Test-Az group show -n $ResourceGroup --only-show-errors) { Ok "resource group exists" }
else {
    Invoke-Az group create -n $ResourceGroup -l $Location -o none
    Ok "resource group created"
}

if (Test-Az keyvault show -n $VaultName --only-show-errors) { Ok "vault exists" }
else {
    # A vault deleted less than 90 days ago is soft-deleted and its name is
    # still taken: `az keyvault purge -n <name>` frees it, or recover it with
    # `az keyvault recover -n <name>` to get the old values back.
    Invoke-Az keyvault create -n $VaultName -g $ResourceGroup -l $Location `
        --enable-rbac-authorization true -o none
    Ok "vault created"
}
$vaultId = Invoke-Az keyvault show -n $VaultName --query id -o tsv
$vaultUrl = Invoke-Az keyvault show -n $VaultName --query properties.vaultUri -o tsv
$vaultUrl = $vaultUrl.TrimEnd('/')

# Creating a vault grants no data-plane rights under RBAC; give yourself write.
Invoke-Az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role 'Key Vault Secrets Officer' --scope $vaultId -o none
Ok "you have Key Vault Secrets Officer"

# ---------------------------------------------------------------- ESO identity
Step "Service principal '$AppName' for External Secrets Operator"
$appId = Invoke-Az ad app list --display-name $AppName --query '[0].appId' -o tsv
if (-not $appId) {
    $appId = Invoke-Az ad app create --display-name $AppName --query appId -o tsv
    Ok "app registration created ($appId)"
}
else { Ok "app registration exists ($appId)" }

if (-not (Test-Az ad sp show --id $appId --only-show-errors)) {
    Invoke-Az ad sp create --id $appId -o none
    Ok "service principal created"
}
$spObjectId = Invoke-Az ad sp show --id $appId --query id -o tsv

Invoke-Az role assignment create --assignee-object-id $spObjectId --assignee-principal-type ServicePrincipal `
    --role 'Key Vault Secrets User' --scope $vaultId -o none
Ok "SP has Key Vault Secrets User (read-only) on the vault"

# The client secret lives ONLY in the vault. If the vault has one, keep it;
# a reset would invalidate what the cluster is using.
if ($Rotate -or -not (Test-VaultSecret 'eso-client-secret')) {
    $spSecret = Invoke-Az ad app credential reset --id $appId --display-name eso --years 2 --query password -o tsv
    Set-VaultSecret 'eso-client-id' $appId
    Set-VaultSecret 'eso-client-secret' $spSecret
    Ok "eso-client-id / eso-client-secret written (new client secret, valid 2 years)"
}
else {
    Set-VaultSecret 'eso-client-id' $appId
    Ok "eso-client-secret already in the vault; kept"
}

# ---------------------------------------------------------------- catalog
Step 'Lab credentials'
$selected = if ($Only) { $Catalog | Where-Object { $Only -contains $_.Name } } else { $Catalog }
foreach ($c in $selected) {
    $name = $c.Name
    if (-not $Rotate -and (Test-VaultSecret $name)) { Ok "$name exists; kept"; continue }

    $value = $null
    $how = $null
    if ($FromCluster -and $c.Cluster) {
        $value = Get-ClusterSecret $c.Cluster
        if ($value) { $how = "copied from $($c.Cluster)" }
        else { Warn "$($c.Cluster) not found in the cluster; falling back" }
    }
    if (-not $value -and $c.Prompt) {
        $sec = Read-Host -Prompt "  $($c.Prompt)" -MaskInput
        if (-not $sec) { Warn "$name skipped (empty)"; continue }
        $value = $sec
        $how = 'entered'
    }
    if (-not $value) {
        $value = New-RandomSecret -Length $c.Length
        $how = "generated ($($c.Length) chars)"
    }
    Set-VaultSecret $name $value
    Ok "$name $how"
}

# ---------------------------------------------------------------- output
Step 'Paste into terraform/terraform.tfvars'
Write-Host "  azure_subscription_id          = `"$subscriptionId`"" -ForegroundColor Cyan
Write-Host "  azure_key_vault_name           = `"$VaultName`"" -ForegroundColor Cyan
Write-Host "  azure_key_vault_resource_group = `"$ResourceGroup`"" -ForegroundColor Cyan
Step 'Check cluster/lab/secrets/clustersecretstore.yaml says'
Write-Host "  tenantId: $tenantId" -ForegroundColor Cyan
Write-Host "  vaultUrl: $vaultUrl" -ForegroundColor Cyan
Write-Host ''
