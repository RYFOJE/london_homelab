#Requires -Version 7.0
<#
.SYNOPSIS
    Post-apply health check for the london_homelab cluster.

.DESCRIPTION
    Walks the whole chain bottom-up -- Proxmox guests, DNS, node, storage,
    workloads, GitOps, ingress -- and reports the first thing that is wrong.
    Run it after any change; it is the counterpart to preflight.ps1.

.EXAMPLE
    ./scripts/verify.ps1
    ./scripts/verify.ps1 -SkipProxmox
#>
[CmdletBinding()]
param(
    [string]$TerraformDir = (Join-Path $PSScriptRoot '..' 'terraform'),
    [switch]$SkipProxmox
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
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
    Write-Host ('[{0}] ' -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host "  -- $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
    if ($Status -eq 'FAIL') { $script:Fail++ }
    if ($Status -eq 'WARN') { $script:Warn++ }
}

function Section { param([string]$T) Write-Host ''; Write-Host $T -ForegroundColor White }

function Get-HclValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $m = [regex]::Match((Get-Content $Path -Raw),
        "(?m)^\s*$([regex]::Escape($Key))\s*=\s*`"?([^`"\r\n#]+?)`"?\s*(?:#.*)?$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-KubeJson {
    # Takes an explicit array and splats it. A ValueFromRemainingArguments
    # parameter does NOT work here: PowerShell binds "-o" to the common
    # -OutVariable/-OutBuffer parameters before the remaining-args parameter
    # ever sees it, and fails with "parameter name 'o' is ambiguous".
    #
    # Converts here rather than returning raw: piping a $null result into
    # ConvertFrom-Json at the call site throws before any null check runs.
    param([string[]]$KArgs)
    $out = & kubectl @KArgs 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return ($out | Out-String | ConvertFrom-Json) } catch { return $null }
}

$TerraformDir = [System.IO.Path]::GetFullPath($TerraformDir)
$locals = Join-Path $TerraformDir 'locals.tf'
$tfvars = Join-Path $TerraformDir 'terraform.tfvars'

$domain = Get-HclValue $locals 'domain'
$ips = [regex]::Matches((Get-Content $locals -Raw), '(?m)ip\s*=\s*"([0-9.]+)"') |
ForEach-Object { $_.Groups[1].Value }
$dnsIp = $ips | Select-Object -First 1
$nodeIp = $ips | Select-Object -Last 1

Write-Host ''
Write-Host "Verifying cluster '$domain'  (dns $dnsIp, node $nodeIp)" -ForegroundColor White
Write-Host ('=' * 62) -ForegroundColor DarkGray

# ============================================================ 1. proxmox
if (-not $SkipProxmox) {
    Section '1. Proxmox guests'
    $endpoint = Get-HclValue $tfvars 'pve_endpoint'
    $token = $env:TF_VAR_pve_api_token
    if (-not $token) { $token = Get-HclValue $tfvars 'pve_api_token' }
    if ($endpoint -and $token) {
        try {
            $r = Invoke-RestMethod -Uri (($endpoint.TrimEnd('/')) + '/api2/json/cluster/resources?type=vm') `
                -Headers @{ Authorization = "PVEAPIToken=$token" } `
                -SkipCertificateCheck -SkipHeaderValidation -TimeoutSec 15
            foreach ($id in 110, 120) {
                $g = $r.data | Where-Object { [int]$_.vmid -eq $id }
                if (-not $g) { Report "guest $id exists" 'FAIL' 'not found' }
                elseif ($g.status -eq 'running') { Report "guest $id ($($g.name))" 'PASS' 'running' }
                else { Report "guest $id ($($g.name))" 'FAIL' $g.status }
            }
        }
        catch { Report 'Proxmox API' 'WARN' $_.Exception.Message }
    }
    else { Report 'Proxmox API' 'INFO' 'no credentials in tfvars; skipped' }
}

# ================================================================ 2. dns
Section '2. DNS'
foreach ($n in @("argocd.$domain", "anything.$domain")) {
    try {
        $a = Resolve-DnsName $n -Server $dnsIp -Type A -ErrorAction Stop |
        Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($a.IPAddress -eq $nodeIp) { Report "resolve $n" 'PASS' $a.IPAddress }
        else { Report "resolve $n" 'FAIL' "got $($a.IPAddress), expected $nodeIp" }
    }
    catch { Report "resolve $n" 'FAIL' "no answer from $dnsIp" }
}
# is the resolver actually in use by THIS machine?
if (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
    $inUse = (Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses -contains $dnsIp
    Report 'this machine uses the lab resolver' ($inUse ? 'PASS' : 'WARN') `
        ($inUse ? '' : "not in your DNS list -- names resolve only with -Server $dnsIp")
}

# =============================================================== 3. node
Section '3. Node and control plane'
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Report 'kubectl' 'FAIL' 'not on PATH'
    Write-Host ''; Write-Host "$script:Fail failed" -ForegroundColor Red; exit 1
}
$nodes = Get-KubeJson @('get','nodes','-o','json')
if (-not $nodes) {
    $hint = if (-not $env:KUBECONFIG) {
        'KUBECONFIG is not set in this session'
    }
    elseif (-not (Test-Path $env:KUBECONFIG)) {
        "KUBECONFIG points at $env:KUBECONFIG which does not exist"
    }
    else {
        "using $env:KUBECONFIG -- if you rebuilt the cluster this file is stale, regenerate it with: terraform output -raw kubeconfig"
    }
    Report 'cluster reachable' 'FAIL' $hint
    Write-Host ''; Write-Host "$script:Fail failed" -ForegroundColor Red; exit 1
}
foreach ($n in $nodes.items) {
    $ready = ($n.status.conditions | Where-Object type -eq 'Ready').status -eq 'True'
    Report "node $($n.metadata.name)" ($ready ? 'PASS' : 'FAIL') $n.status.nodeInfo.kubeletVersion
}

# ============================================================ 4. storage
Section '4. Storage'
$sc = Get-KubeJson @('get','storageclass','-o','json')
$def = $sc.items | Where-Object {
    $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true'
}
Report 'default StorageClass' ($def ? 'PASS' : 'FAIL') ($def ? $def.metadata.name : 'none is marked default')

$pvcs = Get-KubeJson @('get','pvc','-A','-o','json')
$pending = $pvcs.items | Where-Object { $_.status.phase -ne 'Bound' }
if ($pending) {
    foreach ($p in $pending) {
        Report "pvc $($p.metadata.namespace)/$($p.metadata.name)" 'FAIL' $p.status.phase
    }
}
else { Report 'all PVCs bound' 'PASS' "$($pvcs.items.Count) total" }

# =============================================================== 5. pods
Section '5. Workloads'
$pods = Get-KubeJson @('get','pods','-A','-o','json')
$bad = $pods.items | Where-Object {
    $_.status.phase -notin @('Running', 'Succeeded') -or
    ($_.status.containerStatuses | Where-Object { -not $_.ready -and -not $_.state.terminated })
}
if ($bad) {
    foreach ($p in $bad) {
        $why = $p.status.containerStatuses.state.waiting.reason | Select-Object -First 1
        Report "$($p.metadata.namespace)/$($p.metadata.name)" 'FAIL' ($why ?? $p.status.phase)
    }
}
else { Report 'all pods healthy' 'PASS' "$($pods.items.Count) running" }

# ============================================================= 6. gitops
Section '6. GitOps'
$apps = Get-KubeJson @('get','applications','-n','argocd','-o','json')
if (-not $apps -or $apps.items.Count -eq 0) {
    Report 'ArgoCD Applications' 'FAIL' 'none found -- did the root app sync?'
}
else {
    foreach ($a in $apps.items) {
        $s = $a.status.sync.status; $h = $a.status.health.status
        $ok = ($s -eq 'Synced' -and $h -eq 'Healthy')
        Report "app $($a.metadata.name)" ($ok ? 'PASS' : 'FAIL') "$s / $h"
    }
    # only the root app tracks git; chart-sourced apps report a chart version
    $root = $apps.items | Where-Object { $_.metadata.name -eq 'root' }
    if ($root) {
        $remote = $root.status.sync.revision
        $local = (& git -C (Split-Path $TerraformDir -Parent) rev-parse HEAD 2>$null)
        if ($local -and $remote) {
            $match = $remote.StartsWith($local.Substring(0, 7))
            Report 'root app is on your latest commit' ($match ? 'PASS' : 'WARN') `
                ($match ? $remote.Substring(0, 7) : "cluster $($remote.Substring(0,7)) vs local $($local.Substring(0,7)) -- unpushed or not refreshed")
        }
    }
}

# ============================================================ 7. ingress
Section '7. Ingress'
$tp = $pods.items | Where-Object { $_.metadata.namespace -eq 'traefik' }
$tReady = $tp | Where-Object { $_.status.phase -eq 'Running' }
Report 'traefik running' ($tReady ? 'PASS' : 'FAIL') "$($tReady.Count)/$($tp.Count) pods"

foreach ($port in 80, 443) {
    $ok = $false
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $ok = $c.ConnectAsync($nodeIp, $port).Wait(5000) -and $c.Connected
        $c.Close()
    }
    catch { $ok = $false }
    Report "node listening on :$port" ($ok ? 'PASS' : 'FAIL')
}

# Hit the node IP directly with a Host header. Using the name would test
# THIS machine's resolver too, which fails until DHCP points at the lab
# resolver -- and that would mask a genuine ingress problem.
try {
    $r = Invoke-WebRequest "http://$nodeIp/" -Headers @{ Host = "argocd.$domain" } `
        -SkipHeaderValidation -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 10
    $code = [int]$r.StatusCode
    Report "ingress routes argocd.$domain" (($code -lt 400) ? 'PASS' : 'FAIL') "HTTP $code"
}
catch { Report "ingress routes argocd.$domain" 'FAIL' $_.Exception.Message }

# And separately: does the name work end-to-end from here?
try {
    $r = Invoke-WebRequest "http://argocd.$domain" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 10
    Report "http://argocd.$domain from this machine" 'PASS' "HTTP $([int]$r.StatusCode)"
}
catch {
    Report "http://argocd.$domain from this machine" 'WARN' 'name does not resolve here -- expected until DHCP points at the lab resolver'
}

# ============================================================== summary
Write-Host ''
Write-Host ('=' * 62) -ForegroundColor DarkGray
if ($script:Fail -eq 0) {
    Write-Host "Everything healthy ($script:Warn warnings)." -ForegroundColor Green
    exit 0
}
Write-Host "$script:Fail failed, $script:Warn warnings." -ForegroundColor Red
exit 1
