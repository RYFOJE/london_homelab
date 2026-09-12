#Requires -Version 7.0
<#
.SYNOPSIS
    Create the two Azure Key Vaults the lab reads its credentials from, and fill them.

.DESCRIPTION
    Idempotent. Run it once before the first `terraform apply`, and again any
    time you add a credential to the catalog below. Two vaults, deliberately
    separate so the ESO service principal can never read what Terraform reads:

      - the Terraform vault ($VaultName): eso-client-id, eso-client-secret,
        pve-api-token. Only your `az login` identity can read it. This is the
        chicken-and-egg fix -- ESO needs a credential to reach ITS vault, and
        Terraform hands that credential to the cluster by reading it here.
      - the ESO vault ($EsoVaultName): every other lab credential. Both you
        and the ESO service principal can read it; only you can write.

    It:

      1. creates the resource group and both Key Vaults (RBAC mode) if missing
      2. gives YOU "Key Vault Secrets Officer" on both, so you can write
      3. creates the app registration + service principal External Secrets
         Operator logs in as, and gives it "Key Vault Secrets User" (read) on
         the ESO vault ONLY -- it never gets a role on the Terraform vault
      4. writes the SP's client id/secret and the Proxmox token into the
         Terraform vault (Terraform reads exactly those three --
         terraform/secrets.tf)
      5. writes every lab credential in $Catalog into the ESO vault:
         generated, prompted for (the Cloudflare token), or copied from the
         running cluster
      6. creates the storage account + blob container tfstate lives in, and
         gives YOU "Storage Blob Data Contributor" on it (RBAC; the azurerm
         backend authenticates with the same `az login` session, no key)

    Entries that already exist are left alone unless -Rotate is given. The
    catalog here, the ExternalSecrets in cluster/lab/secrets/ and the table in
    DEPLOY.md "Secrets" are the same list three ways; change all three.

.PARAMETER FromCluster
    Copy current values from the running cluster (kubectl) instead of
    generating new ones. For migrating a cluster that was built before Key
    Vault, so nothing rotates. Entries not found in the cluster are generated.
    Only applies to the ESO-vault catalog -- pve-api-token has no cluster copy.

.PARAMETER Rotate
    Overwrite entries that already exist. Combine with -Only to rotate one.
    Restart whatever reads it afterwards (DEPLOY.md "Rotating a credential").

.PARAMETER Only
    Restrict the ESO-vault credential catalog to these names, e.g.
    -Only valkey-password. Does not skip the Terraform-vault entries or the
    storage-account/container step -- those always run.

.EXAMPLE
    az login
    ./scripts/keyvault.ps1
    ./scripts/keyvault.ps1 -FromCluster
    ./scripts/keyvault.ps1 -Rotate -Only grafana-admin-password
#>
[CmdletBinding()]
param(
    # Globally unique. Read-only to you; Terraform reads it through your
    # `az login` session (terraform.tfvars: azure_key_vault_name).
    [string]$VaultName = 'kv-ryfoje-tf',
    # Globally unique; also the host in vaultUrl in
    # cluster/lab/secrets/clustersecretstore.yaml. Read-write to you,
    # read-only to the ESO service principal.
    [string]$EsoVaultName = 'kv-ryfoje-eso',
    [string]$ResourceGroup = 'london-homelab',
    [string]$Location = 'canadacentral',
    # Display name of the app registration ESO authenticates as.
    [string]$AppName = 'london-homelab-external-secrets',
    # Globally unique, lowercase letters/digits only, 3-24 chars. Also
    # backend.hcl's storage_account_name (terraform/backend.hcl.example).
    [string]$StateStorageAccount = 'stryfojelab',
    [string]$StateContainer = 'tfstate',
    [switch]$FromCluster,
    [switch]$Rotate,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- catalog
# Everything here goes in the ESO vault. pve-api-token and the ESO service
# principal's own login go in the Terraform vault instead -- see below.
#
# Name        : the Key Vault secret name (also remoteRef.key in cluster/lab/secrets)
# Cluster     : ns/secret/key to copy from with -FromCluster
# Prompt      : ask for the value instead of generating (external credentials)
# Length      : generated length; alphanumeric only, so no quoting bugs in env vars
# Pattern     : regex a prompted value must match (catches a pasted bare uuid)
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

# Read by Terraform (proxmox provider), preflight.ps1 and verify.ps1; never
# enters the cluster. Lives in the Terraform vault, not the ESO one.
$PveApiToken = @{ Name = 'pve-api-token'; Prompt = 'Proxmox API token as root@pam!tf=<secret> (DEPLOY.md step 1.1)';
    Pattern = '^[^@]+@[^!]+![^=]+=[0-9a-fA-F-]{36}$' }

function Step { param([string]$T) Write-Host ''; Write-Host $T -ForegroundColor White }
function Ok   { param([string]$T) Write-Host "  [ok]   $T" -ForegroundColor Green }
function Info { param([string]$T) Write-Host "  [..]   $T" -ForegroundColor DarkGray }
function Warn { param([string]$T) Write-Host "  [warn] $T" -ForegroundColor Yellow }

#  NO param() block in either of these two, on purpose. A param block with
#  [Parameter(...)] makes the function an ADVANCED function, and PowerShell
#  then binds anything that looks like a parameter -- so `Invoke-Az account
#  show -o json` dies with "the parameter name 'o' is ambiguous" (-OutVariable
#  vs -OutBuffer) and az never runs at all. The automatic $args of a simple
#  function takes everything verbatim, which is what passing az flags needs.

function Invoke-Az {
    #  az with the exit code checked. Errors from az go to stderr, which
    #  PowerShell 7 turns into a terminating error under $ErrorActionPreference
    #  = Stop even for warnings; capture and decide on the exit code instead.
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($args -join ' ')`n$($out -join "`n")"
    }
    return ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
}

function Test-Az {
    & az @args *> $null
    return $LASTEXITCODE -eq 0
}

function Grant-Role {
    #  Idempotent role assignment, with the two first-run failures handled:
    #    - the role is already there. Depending on CLI version az either
    #      returns the existing assignment (exit 0) or fails with
    #      "RoleAssignmentExists"; treat both as success.
    #    - the principal was created seconds ago and Entra has not replicated
    #      it yet, so the assignment 400s with PrincipalNotFound. Retry.
    param([string]$ObjectId, [string]$PrincipalType, [string]$Role, [string]$Scope)
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $out = & az role assignment create --assignee-object-id $ObjectId `
            --assignee-principal-type $PrincipalType --role $Role --scope $Scope -o none 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        if ("$out" -match 'RoleAssignmentExists|already exists') { return }
        if ("$out" -notmatch 'PrincipalNotFound|does not exist in the directory') {
            throw "az role assignment create '$Role'`n$($out -join "`n")"
        }
        if ((Get-Date) -gt $deadline) { throw "'$Role' could not be assigned after 5 minutes: the principal is still not visible in the directory" }
        Info "'$Role' refused (directory still replicating the principal) -- retrying in 15s"
        Start-Sleep -Seconds 15
    }
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

function New-Vault {
    <#  Create the resource group's vault if missing, and make sure YOU have
        Key Vault Secrets Officer on it. Returns @{ Id = ...; Url = ... }. #>
    param([string]$Name)
    Step "Key Vault $Name in $ResourceGroup ($Location)"
    if (Test-Az keyvault show -n $Name --only-show-errors) { Ok "vault exists" }
    else {
        # A vault deleted less than 90 days ago is soft-deleted and its name
        # is still taken: `az keyvault purge -n <name>` frees it, or recover
        # it with `az keyvault recover -n <name>` to get the old values back.
        #
        # $null = ... because Invoke-Az returns a string even for `-o none`
        # (an empty one), and an uncaptured return value here would be
        # emitted alongside the hashtable this function is supposed to return.
        $null = Invoke-Az keyvault create -n $Name -g $ResourceGroup -l $Location `
            --enable-rbac-authorization true -o none
        Ok "vault created"
    }
    $id = Invoke-Az keyvault show -n $Name --query id -o tsv
    $url = (Invoke-Az keyvault show -n $Name --query properties.vaultUri -o tsv).TrimEnd('/')

    # Creating a vault grants no data-plane rights under RBAC; give yourself write.
    Grant-Role -ObjectId $me -PrincipalType User -Role 'Key Vault Secrets Officer' -Scope $id
    Ok "you have Key Vault Secrets Officer"
    return @{ Id = $id; Url = $url }
}

function Set-VaultSecret {
    <#  RBAC assignments take a minute or two to propagate; the first write
        after granting yourself Secrets Officer often 403s. Retry, do not fail. #>
    param([string]$VaultName, [string]$Name, [string]$Value)
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
    param([string]$VaultName, [string]$Name)
    return (Test-Az keyvault secret show --vault-name $VaultName --name $Name --only-show-errors)
}

function Set-PromptedSecret {
    <#  Shared logic for the two Prompt-driven entries (pve-api-token here,
        the whole $Catalog below): skip if it exists and -Rotate wasn't
        given, else prompt/generate/copy and write it. Returns nothing;
        writes its own Ok/Warn line. #>
    param([string]$VaultName, [hashtable]$Entry, [switch]$AllowCluster)
    $name = $Entry.Name
    if (-not $Rotate -and (Test-VaultSecret $VaultName $name)) { Ok "$name exists; kept"; return }

    $value = $null
    $how = $null
    if ($AllowCluster -and $FromCluster -and $Entry.Cluster) {
        $value = Get-ClusterSecret $Entry.Cluster
        if ($value) { $how = "copied from $($Entry.Cluster)" }
        else { Warn "$($Entry.Cluster) not found in the cluster; falling back" }
    }
    if (-not $value -and $Entry.Prompt) {
        $sec = Read-Host -Prompt "  $($Entry.Prompt)" -MaskInput
        if (-not $sec) { Warn "$name skipped (empty)"; return }
        if ($Entry.Pattern -and $sec -notmatch $Entry.Pattern) { Warn "$name skipped (does not match $($Entry.Pattern))"; return }
        $value = $sec
        $how = 'entered'
    }
    if (-not $value) {
        $value = New-RandomSecret -Length $Entry.Length
        $how = "generated ($($Entry.Length) chars)"
    }
    Set-VaultSecret $VaultName $name $value
    Ok "$name $how"
}

# ---------------------------------------------------------------- session
Step 'Azure session'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az not found -- winget install Microsoft.AzureCLI, then az login'
}
try { $account = Invoke-Az account show -o json | ConvertFrom-Json }
catch { throw "az account show failed -- run: az login`n$_" }
$subscriptionId = $account.id
$tenantId = $account.tenantId
Ok "subscription $($account.name) ($subscriptionId), tenant $tenantId"
# Every `az ad` call needs a Graph token; a stale session fails those with
# "InteractionRequired" even though `az account show` works.
if (-not (Test-Az ad signed-in-user show --only-show-errors)) {
    throw 'Graph token expired -- run: az login   (then re-run this script)'
}
$me = Invoke-Az ad signed-in-user show --query id -o tsv

# ------------------------------------------------------- resource providers
# A subscription that has never held a vault or a storage account has these
# unregistered, and `az keyvault create` then fails with
# MissingSubscriptionRegistration rather than anything self-explanatory.
# Registering is idempotent; --wait blocks until the namespace is usable.
Step 'Resource providers'
foreach ($ns in 'Microsoft.KeyVault', 'Microsoft.Storage') {
    $state = Invoke-Az provider show --namespace $ns --query registrationState -o tsv
    if ($state -eq 'Registered') { Ok "$ns registered" }
    else {
        Info "$ns is $state -- registering, can take a minute"
        $null = Invoke-Az provider register --namespace $ns --wait
        Ok "$ns registered"
    }
}

# ---------------------------------------------------------------- resource group
Step "Resource group $ResourceGroup ($Location)"
if (Test-Az group show -n $ResourceGroup --only-show-errors) { Ok "resource group exists" }
else {
    $null = Invoke-Az group create -n $ResourceGroup -l $Location -o none
    Ok "resource group created"
}

# ---------------------------------------------------------------- vaults
$tfVault = New-Vault $VaultName
$esoVault = New-Vault $EsoVaultName

# ---------------------------------------------------------------- ESO identity
Step "Service principal '$AppName' for External Secrets Operator"
$appId = Invoke-Az ad app list --display-name $AppName --query '[0].appId' -o tsv
if (-not $appId) {
    $appId = Invoke-Az ad app create --display-name $AppName --query appId -o tsv
    Ok "app registration created ($appId)"
}
else { Ok "app registration exists ($appId)" }

if (-not (Test-Az ad sp show --id $appId --only-show-errors)) {
    $null = Invoke-Az ad sp create --id $appId -o none
    Ok "service principal created"
}
$spObjectId = Invoke-Az ad sp show --id $appId --query id -o tsv

# Read-only, and only on the ESO vault -- it never gets a role on the
# Terraform vault, so a compromised SP cannot read pve-api-token.
Grant-Role -ObjectId $spObjectId -PrincipalType ServicePrincipal -Role 'Key Vault Secrets User' -Scope $esoVault.Id
Ok "SP has Key Vault Secrets User (read-only) on $EsoVaultName only"

# ---------------------------------------------------------------- Terraform vault contents
Step 'Terraform vault contents'
# The client secret lives ONLY in the vault. If the vault has one, keep it;
# a reset would invalidate what the cluster is using.
if ($Rotate -or -not (Test-VaultSecret $VaultName 'eso-client-secret')) {
    $spSecret = Invoke-Az ad app credential reset --id $appId --display-name eso --years 2 --query password -o tsv
    Set-VaultSecret $VaultName 'eso-client-id' $appId
    Set-VaultSecret $VaultName 'eso-client-secret' $spSecret
    Ok "eso-client-id / eso-client-secret written (new client secret, valid 2 years)"
}
else {
    Set-VaultSecret $VaultName 'eso-client-id' $appId
    Ok "eso-client-secret already in the vault; kept"
}
Set-PromptedSecret $VaultName $PveApiToken

# ---------------------------------------------------------------- ESO vault contents
Step 'ESO vault contents'
$selected = if ($Only) { $Catalog | Where-Object { $Only -contains $_.Name } } else { $Catalog }
foreach ($c in $selected) {
    Set-PromptedSecret $EsoVaultName $c -AllowCluster
}

# ---------------------------------------------------------------- tfstate
Step "Terraform state: $StateStorageAccount / $StateContainer"
if (Test-Az storage account show -n $StateStorageAccount -g $ResourceGroup --only-show-errors) {
    Ok "storage account exists"
}
else {
    # StorageV2/LRS is plenty for one state file. Public network access stays
    # on (no VNet here), but blob-level access is RBAC-only: no shared key,
    # no SAS, matching the azuread_auth the backend block uses below.
    $null = Invoke-Az storage account create -n $StateStorageAccount -g $ResourceGroup -l $Location `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
        --https-only true --allow-shared-key-access false -o none
    Ok "storage account created"
}
$saId = Invoke-Az storage account show -n $StateStorageAccount -g $ResourceGroup --query id -o tsv

# Blob versioning: a bad `apply` overwriting good state is one `az storage
# blob undelete` / version restore away from fixed, not a lost cluster.
$null = Invoke-Az storage account blob-service-properties update --account-name $StateStorageAccount `
    -g $ResourceGroup --enable-versioning true --enable-delete-retention true --delete-retention-days 30 -o none
Ok "blob versioning + 30-day soft delete on"

# Creating the account grants no data-plane rights under RBAC; give yourself write.
Grant-Role -ObjectId $me -PrincipalType User -Role 'Storage Blob Data Contributor' -Scope $saId
Ok "you have Storage Blob Data Contributor"

# `az storage container create` is itself idempotent (it reports created:false
# for one that is already there), so just run it. Do NOT gate this on
# `az storage container exists`: that command exits 0 either way and answers
# in its OUTPUT, so testing its exit code always says "yes, it exists".
# Same RBAC-propagation lag as the vaults: retry rather than fail outright.
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    & az storage container create --name $StateContainer --account-name $StateStorageAccount `
        --auth-mode login --only-show-errors *> $null
    if ($LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw "could not create container $StateContainer on $StateStorageAccount after 5 minutes (RBAC not propagated?)" }
    Info "container create refused (RBAC still propagating?) -- retrying in 15s"
    Start-Sleep -Seconds 15
}
Ok "container ready"

# ---------------------------------------------------------------- output
Step 'Paste into terraform/terraform.tfvars'
Write-Host "  azure_subscription_id          = `"$subscriptionId`"" -ForegroundColor Cyan
Write-Host "  azure_key_vault_name           = `"$VaultName`"" -ForegroundColor Cyan
Write-Host "  azure_key_vault_resource_group = `"$ResourceGroup`"" -ForegroundColor Cyan
Step 'Check cluster/lab/secrets/clustersecretstore.yaml says'
Write-Host "  tenantId: $tenantId" -ForegroundColor Cyan
Write-Host "  vaultUrl: $($esoVault.Url)" -ForegroundColor Cyan
Step 'Paste into terraform/backend.hcl (cp backend.hcl.example first)'
Write-Host "  resource_group_name  = `"$ResourceGroup`"" -ForegroundColor Cyan
Write-Host "  storage_account_name = `"$StateStorageAccount`"" -ForegroundColor Cyan
Write-Host "  container_name       = `"$StateContainer`"" -ForegroundColor Cyan
Write-Host ''
