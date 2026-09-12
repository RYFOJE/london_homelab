#Requires -Version 7.0
<#
.SYNOPSIS
    Preflight checks for the london_homelab Terraform config.

.DESCRIPTION
    Verifies every external dependency before you burn an apply: SSH agent,
    Proxmox token and permissions, node name, template and image URLs,
    IP/VMID collisions, and the Azure Key Vault every credential comes from.
    Each of these otherwise fails midway through an apply with an error that
    points somewhere unhelpful.

.PARAMETER FixAgent
    Start the OpenSSH Authentication Agent service and add your key.
    Requires an elevated session.

.EXAMPLE
    ./scripts/preflight.ps1
    ./scripts/preflight.ps1 -FixAgent
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..' 'terraform'),
    [string]$SshKey = (Join-Path $HOME '.ssh' 'id_ed25519'),
    [switch]$FixAgent
)

$ErrorActionPreference = 'Stop'
$script:Fail = 0
$script:Warn = 0

function Report {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')][string]$Status,
        [string]$Detail
    )
    $color = switch ($Status) {
        'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' }
    }
    Write-Host ('[{0}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host "  -- $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
    if ($Status -eq 'FAIL') { $script:Fail++ }
    if ($Status -eq 'WARN') { $script:Warn++ }
}

function Get-HclValue {
    <#  Pulls `key = "value"` or `key = value` out of an HCL file.
        Regex, not a parser -- good enough for flat scalars. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $text = Get-Content $Path -Raw
    $m = [regex]::Match($text, "(?m)^\s*$([regex]::Escape($Key))\s*=\s*`"?([^`"\r\n#]+?)`"?\s*(?:#.*)?$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

$TerraformDir = [System.IO.Path]::GetFullPath($TerraformDir)
$localsPath = Join-Path $TerraformDir 'locals.tf'
$tfvarsPath = Join-Path $TerraformDir 'terraform.tfvars'

Write-Host ''
Write-Host "Preflight: $TerraformDir" -ForegroundColor White
Write-Host ('-' * 60) -ForegroundColor DarkGray

# ---------------------------------------------------------------- tooling
$tf = Get-Command tofu, terraform -ErrorAction SilentlyContinue | Select-Object -First 1
if ($tf) {
    Report 'Terraform/OpenTofu on PATH' 'PASS' $tf.Source
}
else {
    Report 'Terraform/OpenTofu on PATH' 'FAIL' 'install terraform or tofu'
}

# ------------------------------------------------------------- ssh agent
if ($IsWindows) {
    $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not $svc) {
        Report 'OpenSSH Authentication Agent' 'FAIL' 'service not present -- install the OpenSSH Client optional feature'
    }
    elseif ($svc.Status -ne 'Running') {
        if ($FixAgent) {
            Set-Service ssh-agent -StartupType Automatic
            Start-Service ssh-agent
            Report 'OpenSSH Authentication Agent' 'PASS' 'started'
        }
        else {
            Report 'OpenSSH Authentication Agent' 'FAIL' 'not running -- re-run elevated with -FixAgent'
        }
    }
    else {
        Report 'OpenSSH Authentication Agent' 'PASS' 'running'
    }
}
else {
    Report 'SSH agent service check' 'INFO' 'skipped (not Windows)'
}

if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
    Report 'SSH key loaded in agent' 'FAIL' 'ssh-add not found -- install the OpenSSH Client optional feature'
}
else {
    $agentKeys = & ssh-add -l 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $agentKeys -notmatch 'no identities') {
        Report 'SSH key loaded in agent' 'PASS' (($agentKeys -split "`n")[0].Trim())
    }
    elseif ($FixAgent -and (Test-Path $SshKey)) {
        & ssh-add $SshKey
        Report 'SSH key loaded in agent' (($LASTEXITCODE -eq 0) ? 'PASS' : 'FAIL') $SshKey
    }
    elseif (Test-Path $SshKey) {
        Report 'SSH key loaded in agent' 'FAIL' "key exists but is not loaded -- run: ssh-add $SshKey"
    }
    else {
        Report 'SSH key loaded in agent' 'FAIL' "no key at $SshKey -- run: ssh-keygen -t ed25519"
    }
}

# ---------------------------------------------------------------- tfvars
if (-not (Test-Path $tfvarsPath)) {
    Report 'terraform.tfvars' 'FAIL' 'missing -- copy terraform.tfvars.example'
    Write-Host ''
    Write-Host "$script:Fail failed, $script:Warn warnings" -ForegroundColor Red
    exit 1
}
Report 'terraform.tfvars' 'PASS'

$backendPath = Join-Path $TerraformDir 'backend.hcl'
if (-not (Test-Path $backendPath)) {
    Report 'terraform/backend.hcl' 'FAIL' 'missing -- copy backend.hcl.example, fill in what ./scripts/keyvault.ps1 printed'
}
else {
    Report 'terraform/backend.hcl' 'PASS'
    $stateAccount = Get-HclValue $backendPath 'storage_account_name'
    if ($stateAccount -and (Get-Command az -ErrorAction SilentlyContinue)) {
        & az storage account show -n $stateAccount --only-show-errors *> $null
        if ($LASTEXITCODE -eq 0) {
            Report "storage account $stateAccount reachable" 'PASS'
        }
        else {
            Report "storage account $stateAccount reachable" 'FAIL' 'not found, or you lack Storage Blob Data Contributor on it -- ./scripts/keyvault.ps1'
        }
    }
}

$endpoint = Get-HclValue $tfvarsPath 'pve_endpoint'
$templateUrl = Get-HclValue $tfvarsPath 'lxc_template_url'
$schematic = Get-HclValue $tfvarsPath 'talos_schematic_id'
$talosVersion = (Get-HclValue $tfvarsPath 'talos_version') ?? '1.14.0'

$pveNode = Get-HclValue $localsPath 'pve_node'
$vaultName = Get-HclValue $tfvarsPath 'azure_key_vault_name'
$subscription = Get-HclValue $tfvarsPath 'azure_subscription_id'

if (Get-HclValue $tfvarsPath 'pve_api_token') {
    Report 'no pve_api_token in tfvars' 'WARN' 'no longer a variable; it lives in Key Vault now -- delete the line'
}

# -------------------------------------------------- ssh_public_key_path
# The agent check above proves SOME key is loaded; this proves the file
# dns.tf actually reads exists. They are different things: a tfvars pointing
# at ~/.ssh/id_rsa.pub on a machine that only has an ed25519 key fails in
# `file(pathexpand(...))` several minutes into the apply, after the state
# lock is taken.
$pubKeyPath = Get-HclValue $tfvarsPath 'ssh_public_key_path'
if (-not $pubKeyPath) {
    Report 'ssh_public_key_path in tfvars' 'FAIL' 'not set'
}
else {
    # pathexpand() handles ~ the same way Terraform does.
    $expanded = $pubKeyPath -replace '^~', $HOME
    if (Test-Path $expanded) {
        Report 'ssh_public_key_path exists' 'PASS' $pubKeyPath
    }
    else {
        $found = Get-ChildItem (Join-Path $HOME '.ssh') -Filter '*.pub' -ErrorAction SilentlyContinue |
            ForEach-Object { "~/.ssh/$($_.Name)" }
        $hint = if ($found) { "no file at $expanded -- you have: $($found -join ', ')" } else { "no file at $expanded, and no *.pub in ~/.ssh -- run: ssh-keygen -t ed25519" }
        Report 'ssh_public_key_path exists' 'FAIL' $hint
    }
}

# --------------------------------------------------------- proxmox token
# Same place Terraform reads it from: the vault, through your az session.
# The Azure login itself is checked further down; a failure here is the
# first symptom of that too.
$token = $null
if ($vaultName -and (Get-Command az -ErrorAction SilentlyContinue)) {
    $token = & az keyvault secret show --vault-name $vaultName --name pve-api-token --query value -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $token = $null }
}
if ($token -match '^[^@]+@[^!]+![^=]+=[0-9a-fA-F-]{36}$') {
    Report 'pve-api-token in Key Vault' 'PASS' ($token -replace '=.*', '=<secret>')
}
elseif ($token) {
    Report 'pve-api-token in Key Vault' 'FAIL' 'expected user@realm!tokenid=<uuid> -- ./scripts/keyvault.ps1 -Rotate -Only pve-api-token'
}
else {
    Report 'pve-api-token in Key Vault' 'FAIL' 'not readable: az login, then ./scripts/keyvault.ps1 (prompts for it)'
}

# ------------------------------------------------------------- pve reach
$nodeNames = @()
if ($endpoint -and $token) {
    $uri = ($endpoint.TrimEnd('/')) + '/api2/json/nodes'
    try {
        # -SkipHeaderValidation is required: .NET expects "scheme parameter"
        # with a space, and Proxmox's header has none. Without it the call
        # fails locally with "the format of value ... is invalid" and never
        # reaches the network.
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "PVEAPIToken=$token" } `
            -SkipCertificateCheck -SkipHeaderValidation -TimeoutSec 15
        $nodeNames = @($resp.data | ForEach-Object { $_.node })
        Report 'Proxmox API auth' 'PASS' ("nodes: " + ($nodeNames -join ', '))
    }
    catch {
        # A connection failure has no Response at all -- guard, or the message
        # comes out as a bare "HTTP  --" with nothing useful in it.
        # Capture the message BEFORE the switch: inside a switch block $_ is
        # rebound to the switch input, so $_.Exception there is $null.
        $msg = $_.Exception.Message
        $code = $null
        if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
        $hint = switch ($code) {
            401 { 'token id or secret is wrong' }
            403 { 'token is valid but has no permissions -- Privilege Separation is still enabled' }
            default { $msg }
        }
        Report 'Proxmox API auth' 'FAIL' ($code ? "HTTP $code -- $hint" : $hint)
    }
}

if ($nodeNames.Count -gt 0) {
    if ($nodeNames -contains $pveNode) {
        Report "pve_node '$pveNode' exists" 'PASS'
    }
    else {
        Report "pve_node '$pveNode' exists" 'FAIL' ("Proxmox reports: " + ($nodeNames -join ', '))
    }
}

# -------------------------------------------------------------- pve ssh
if ($endpoint -and (Get-Command ssh -ErrorAction SilentlyContinue)) {
    $host_ = ([uri]$endpoint).Host
    & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$host_" 'true' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Report 'SSH to Proxmox host' 'PASS' "root@$host_"
    }
    else {
        Report 'SSH to Proxmox host' 'FAIL' 'template downloads go over SSH, not the API'
    }
}

# ------------------------------------------------------------ image urls
function Test-Url {
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 20 -SkipHttpErrorCheck
        return [int]$r.StatusCode
    }
    catch { return -1 }
}

if ($templateUrl) {
    $code = Test-Url $templateUrl
    if ($code -eq 200) {
        Report 'LXC template URL' 'PASS'
    }
    else {
        Report 'LXC template URL' 'FAIL' "HTTP $code -- run 'pveam available --section system' for the current filename"
    }
}

if (-not $schematic -or $schematic -match 'REPLACE') {
    Report 'Talos schematic ID' 'WARN' 'not set -- generating one now'
    $body = Get-Content (Join-Path $TerraformDir 'files' 'schematic.yaml') -Raw
    try {
        $r = Invoke-RestMethod -Uri 'https://factory.talos.dev/schematics' -Method Post `
            -ContentType 'application/yaml' -Body $body -TimeoutSec 20
        Write-Host ''
        Write-Host "    talos_schematic_id = `"$($r.id)`"" -ForegroundColor Cyan
        Write-Host '    ^ paste into terraform.tfvars' -ForegroundColor DarkGray
        Write-Host ''
    }
    catch {
        Report 'Schematic generation' 'FAIL' $_.Exception.Message
    }
}
else {
    $imgUrl = "https://factory.talos.dev/image/$schematic/v$talosVersion/nocloud-amd64.raw.xz"
    $code = Test-Url $imgUrl
    if ($code -eq 200) {
        Report 'Talos image URL' 'PASS' "v$talosVersion"
    }
    else {
        Report 'Talos image URL' 'FAIL' "HTTP $code -- bad schematic id, or talos_version does not exist"
    }
}

# ------------------------------------------------------- address conflicts
$ips = [regex]::Matches((Get-Content $localsPath -Raw), '(?m)ip\s*=\s*"([0-9.]+)"') |
ForEach-Object { $_.Groups[1].Value }
foreach ($ip in $ips) {
    if (Test-Connection -TargetName $ip -Count 1 -Quiet -TimeoutSeconds 2) {
        Report "IP $ip is free" 'FAIL' 'something already answers here'
    }
    else {
        Report "IP $ip is free" 'PASS'
    }
}

# -------------------------------------------------------------- key vaults
# Two vaults (scripts/keyvault.ps1 creates both): Terraform reads the ESO
# service principal's own login and the Proxmox token out of the Terraform
# vault (tfvars azure_key_vault_name) with your az session; ESO then reads
# every other credential out of the ESO vault, whose name is only in
# clustersecretstore.yaml. A missing entry fails the apply (Terraform vault)
# or parks the secrets app at Degraded (ESO vault), so check both.
$esDir = Join-Path $TerraformDir '..' 'cluster' 'lab' 'secrets'
$cssPath = Join-Path $esDir 'clustersecretstore.yaml'
# YAML, not HCL -- `key: value`, not `key = value` -- so Get-HclValue doesn't fit.
$esoVaultUrl = if (Test-Path $cssPath) {
    $m = [regex]::Match((Get-Content $cssPath -Raw), '(?m)^\s*vaultUrl:\s*(\S+)\s*$')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
} else { $null }
$esoVaultName = if ($esoVaultUrl) { ([uri]$esoVaultUrl).Host -replace '\.vault\.azure\.net$', '' } else { $null }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Report 'Azure CLI on PATH' 'FAIL' 'winget install Microsoft.AzureCLI, then az login'
}
elseif (-not $vaultName) {
    Report 'azure_key_vault_name in tfvars' 'FAIL' 'run ./scripts/keyvault.ps1 and paste its output'
}
elseif (-not $esoVaultName) {
    Report 'vaultUrl in clustersecretstore.yaml' 'FAIL' 'missing or unparsable -- run ./scripts/keyvault.ps1 and paste its output'
}
else {
    $acct = & az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) {
        Report 'Azure login' 'FAIL' 'run: az login'
    }
    else {
        Report 'Azure login' 'PASS' "$($acct.user.name) / $($acct.name)"
        if ($subscription -and $acct.id -ne $subscription) {
            Report 'azure_subscription_id matches az session' 'WARN' "tfvars $subscription, az $($acct.id) -- az account set -s $subscription"
        }

        # ---- Terraform vault: eso-client-id, eso-client-secret, pve-api-token
        $tfNames = & az keyvault secret list --vault-name $vaultName --query '[].name' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            Report "Terraform vault $vaultName readable" 'FAIL' 'not found, or you lack Key Vault Secrets Officer on it -- ./scripts/keyvault.ps1'
        }
        else {
            Report "Terraform vault $vaultName readable" 'PASS' "$(@($tfNames).Count) entries"
            $tfExpected = @('eso-client-id', 'eso-client-secret', 'pve-api-token')
            $tfMissing = $tfExpected | Where-Object { $tfNames -notcontains $_ }
            if ($tfMissing) {
                Report 'every expected Terraform-vault entry exists' 'FAIL' ("missing: " + ($tfMissing -join ', ') + " -- ./scripts/keyvault.ps1")
            }
            else {
                Report 'every expected Terraform-vault entry exists' 'PASS' "$($tfExpected.Count) names"
            }
        }

        # ---- ESO vault: everything the ExternalSecrets in cluster/lab/secrets ask for
        $esoNames = & az keyvault secret list --vault-name $esoVaultName --query '[].name' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            Report "ESO vault $esoVaultName readable" 'FAIL' 'not found, or you lack Key Vault Secrets Officer on it -- ./scripts/keyvault.ps1'
        }
        else {
            Report "ESO vault $esoVaultName readable" 'PASS' "$(@($esoNames).Count) entries"
            $esoExpected = Get-ChildItem $esDir -Filter '*.yaml' | ForEach-Object {
                [regex]::Matches((Get-Content $_.FullName -Raw), 'remoteRef:\s*\{\s*key:\s*([A-Za-z0-9-]+)') |
                ForEach-Object { $_.Groups[1].Value }
            } | Sort-Object -Unique
            $esoMissing = $esoExpected | Where-Object { $esoNames -notcontains $_ }
            if ($esoMissing) {
                Report 'every expected ESO-vault entry exists' 'FAIL' ("missing: " + ($esoMissing -join ', ') + " -- ./scripts/keyvault.ps1")
            }
            else {
                Report 'every expected ESO-vault entry exists' 'PASS' "$(@($esoExpected).Count) names"
            }
        }
    }
}

# -------------------------------------------------------------- vmid clash
if ($nodeNames.Count -gt 0) {
    $vmids = [regex]::Matches((Get-Content $localsPath -Raw), '(?m)vmid\s*=\s*(\d+)') |
    ForEach-Object { [int]$_.Groups[1].Value }
    try {
        $res = Invoke-RestMethod -Uri (($endpoint.TrimEnd('/')) + '/api2/json/cluster/resources?type=vm') `
            -Headers @{ Authorization = "PVEAPIToken=$token" } `
            -SkipCertificateCheck -SkipHeaderValidation -TimeoutSec 15
        $used = @($res.data | ForEach-Object { [int]$_.vmid })
        foreach ($id in $vmids) {
            if ($used -contains $id) {
                Report "VMID $id is free" 'FAIL' 'already in use'
            }
            else {
                Report "VMID $id is free" 'PASS'
            }
        }
    }
    catch {
        Report 'VMID check' 'WARN' 'could not list cluster resources'
    }
}

Write-Host ('-' * 60) -ForegroundColor DarkGray
if ($script:Fail -eq 0) {
    Write-Host "All checks passed ($script:Warn warnings). Safe to apply." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$script:Fail failed, $script:Warn warnings. Fix these before applying." -ForegroundColor Red
    exit 1
}
