#Requires -Version 7.0
<#
.SYNOPSIS
    Preflight checks for the london_homelab Terraform config.

.DESCRIPTION
    Verifies every external dependency before you burn an apply: SSH agent,
    Proxmox token and permissions, node name, template and image URLs, and
    IP/VMID collisions. Each of these otherwise fails midway through an
    apply with an error that points somewhere unhelpful.

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

$endpoint = Get-HclValue $tfvarsPath 'pve_endpoint'
$token = $env:TF_VAR_pve_api_token
if (-not $token) { $token = Get-HclValue $tfvarsPath 'pve_api_token' }
$templateUrl = Get-HclValue $tfvarsPath 'lxc_template_url'
$schematic = Get-HclValue $tfvarsPath 'talos_schematic_id'
$talosVersion = (Get-HclValue $tfvarsPath 'talos_version') ?? '1.14.0'

$pveNode = Get-HclValue $localsPath 'pve_node'

# --------------------------------------------------------- token format
if ($token -match '^[^@]+@[^!]+![^=]+=[0-9a-fA-F-]{36}$') {
    Report 'API token format' 'PASS' ($token -replace '=.*', '=<secret>')
}
else {
    Report 'API token format' 'FAIL' 'expected user@realm!tokenid=<uuid>'
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
