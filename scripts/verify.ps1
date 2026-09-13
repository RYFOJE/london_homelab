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

function Get-HttpStatus {
    <#  Invoke-WebRequest with -MaximumRedirection 0 THROWS "Operation is not
        valid due to the current state of the object" on any 3xx, even with
        -SkipHttpErrorCheck. Anything that redirects to a login flow trips it.
        HttpClient reports the real status instead. #>
    param([string]$Url, [string]$HostHeader)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    # NOT a scriptblock: HttpClient invokes the callback on a thread-pool
    # thread with no PowerShell runspace, and a scriptblock there throws
    # "There is no Runspace available" -- surfacing as "The SSL connection
    # could not be established" on every https URL. The built-in delegate
    # runs without PowerShell. Section 9 checks the cert properly.
    $handler.ServerCertificateCustomValidationCallback =
    [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new('GET', $Url)
        if ($HostHeader) { $req.Headers.Host = $HostHeader }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        return [int]$resp.StatusCode
    }
    finally { $client.Dispose() }
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
    # Token is in Key Vault, not tfvars; read it the way Terraform does.
    $vaultName = Get-HclValue $tfvars 'azure_key_vault_name'
    $token = $null
    if ($vaultName -and (Get-Command az -ErrorAction SilentlyContinue)) {
        $token = & az keyvault secret show --vault-name $vaultName --name pve-api-token --query value -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { $token = $null }
    }
    if ($endpoint -and $token) {
        try {
            $r = Invoke-RestMethod -Uri (($endpoint.TrimEnd('/')) + '/api2/json/cluster/resources?type=vm') `
                -Headers @{ Authorization = "PVEAPIToken=$token" } `
                -SkipCertificateCheck -SkipHeaderValidation -TimeoutSec 15
            $vmids = [regex]::Matches((Get-Content $locals -Raw), '(?m)vmid\s*=\s*(\d+)') |
            ForEach-Object { [int]$_.Groups[1].Value }
            foreach ($id in $vmids) {
                $g = $r.data | Where-Object { [int]$_.vmid -eq $id }
                if (-not $g) { Report "guest $id exists" 'FAIL' 'not found' }
                elseif ($g.status -eq 'running') { Report "guest $id ($($g.name))" 'PASS' 'running' }
                else { Report "guest $id ($($g.name))" 'FAIL' $g.status }
            }
        }
        catch { Report 'Proxmox API' 'WARN' $_.Exception.Message }
    }
    else { Report 'Proxmox API' 'INFO' 'pve-api-token not readable from Key Vault (az login?); skipped' }
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
# Is the resolver actually in use by THIS machine? Resolve WITHOUT -Server and
# compare: having $dnsIp in the IPv4 DNS list proves nothing. Windows prefers a
# DNS server advertised over IPv6 (router RA) regardless of the IPv4 list, so
# the browser gets the router's public answer -- no lab records -- while the
# lab resolver sits there configured and unused.
$sysName = "argocd.$domain"
$sysAnswer = $null
try {
    $sysAnswer = (Resolve-DnsName $sysName -Type A -ErrorAction Stop |
        Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
}
catch { $sysAnswer = $null }

if ($sysAnswer -eq $nodeIp) {
    Report 'this machine uses the lab resolver' 'PASS' "$sysName -> $sysAnswer without -Server"
}
else {
    # Name the culprit if we can: whoever answers is not the lab resolver.
    $v6 = (Get-DnsClientServerAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses }).ServerAddresses | Select-Object -First 1
    $why = if ($v6) { "an IPv6 DNS server ($v6) is answering first -- disable IPv6 on the adapter, or stop the router advertising DNS over IPv6" }
    else { "not your effective resolver -- router DHCP option 6 (DEPLOY.md step 5)" }
    Report 'this machine uses the lab resolver' 'WARN' `
        ("$sysName resolved to '$sysAnswer', expected ${nodeIp}: " + $why)
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

# KEDA registers the external metrics API; every ScaledObject's HPA reads
# through it. A Running pod is not enough -- the APIService goes Available
# only once the operator has patched its self-signed caBundle in.
$extMetrics = Get-KubeJson @('get','apiservice','v1beta1.external.metrics.k8s.io','-o','json')
if (-not $extMetrics) {
    Report 'external metrics API (KEDA)' 'FAIL' 'APIService v1beta1.external.metrics.k8s.io not found -- did the keda app sync?'
}
else {
    $avail = $extMetrics.status.conditions | Where-Object { $_.type -eq 'Available' } | Select-Object -First 1
    $ok = $avail -and $avail.status -eq 'True'
    Report 'external metrics API (KEDA)' ($ok ? 'PASS' : 'FAIL') ($ok ? "served by $($extMetrics.spec.service.namespace)/$($extMetrics.spec.service.name)" : ($avail.message ?? 'no Available condition'))
}

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
    # Every credential arrives through an ExternalSecret. A Ready=False one
    # names the vault entry or the auth problem in its message; the app it
    # feeds only shows a pod stuck in CreateContainerConfigError.
    $css = Get-KubeJson @('get', 'clustersecretstore', 'azure-keyvault', '-o', 'json')
    $cssReady = $css.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1
    Report 'ClusterSecretStore azure-keyvault' (($cssReady.status -eq 'True') ? 'PASS' : 'FAIL') `
        ($cssReady ? $cssReady.message : 'not found -- did the secrets app sync?')
    $ess = Get-KubeJson @('get', 'externalsecrets', '-A', '-o', 'json')
    $notReady = @($ess.items | Where-Object {
            ($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 0
        })
    if (-not $ess -or @($ess.items).Count -eq 0) {
        Report 'ExternalSecrets' 'FAIL' 'none found -- did the secrets app sync?'
    }
    elseif ($notReady.Count -gt 0) {
        foreach ($e in $notReady) {
            $msg = ($e.status.conditions | Where-Object { $_.type -eq 'Ready' } | Select-Object -First 1).message
            Report "externalsecret $($e.metadata.namespace)/$($e.metadata.name)" 'FAIL' ($msg ?? 'no Ready condition')
        }
    }
    else { Report 'all ExternalSecrets synced' 'PASS' "$(@($ess.items).Count) total" }

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

# 5432/5672/6379/1025: Traefik TCP entrypoints for Postgres, AMQP, Valkey, SMTP.
foreach ($port in 80, 443, 5432, 5672, 6379, 1025) {
    $ok = $false
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $ok = $c.ConnectAsync($nodeIp, $port).Wait(5000) -and $c.Connected
        $c.Close()
    }
    catch { $ok = $false }
    Report "node listening on :$port" ($ok ? 'PASS' : 'FAIL')
}

# Every Ingress in the cluster, checked three ways: does its host match the
# domain we think we are running, does the lab resolver answer for it, and
# does Traefik actually route it.
$ings = Get-KubeJson @('get', 'ingress', '-A', '-o', 'json')
$hosts = @()
if ($ings) {
    foreach ($i in $ings.items) {
        foreach ($rule in $i.spec.rules) {
            if ($rule.host) {
                $hosts += [pscustomobject]@{
                    Host = $rule.host
                    Ref  = "$($i.metadata.namespace)/$($i.metadata.name)"
                }
            }
        }
    }
}
if ($hosts.Count -eq 0) { Report 'ingress hosts found' 'FAIL' 'no Ingress with a host rule' }

foreach ($h in $hosts) {
    # 1. does it belong to this cluster's domain? catches config drift where a
    #    stale render leaves a host from someone else's example values.
    if ($h.Host -notlike "*.$domain") {
        Report "$($h.Ref) host" 'FAIL' "$($h.Host) is not under $domain -- stale render or hardcoded value"
        continue
    }

    # 2. does the lab resolver answer for it?
    $resolved = $null
    try {
        $resolved = (Resolve-DnsName $h.Host -Server $dnsIp -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
    }
    catch { }
    if ($resolved -ne $nodeIp) {
        Report "$($h.Host) resolves" 'FAIL' ($resolved ? "got $resolved" : "no answer from $dnsIp")
        continue
    }

    # 3. does Traefik route it? Host header against the node IP, so this tests
    #    the ingress and not this machine's resolver.
    try {
        $code = Get-HttpStatus -Url "http://$nodeIp/" -HostHeader $h.Host
        # 3xx is a healthy answer: apps that redirect to a login flow are working.
        # 401 too: Elasticsearch demands basic auth on every path, and a
        # challenge proves the request reached it.
        Report "$($h.Host)" (($code -lt 400 -or $code -eq 401) ? 'PASS' : 'FAIL') "HTTP $code via $($h.Ref)"
    }
    catch { Report "$($h.Host)" 'FAIL' $_.Exception.Message }
}

# And end-to-end from this machine, which additionally exercises your own
# resolver -- NRPT rule, VPN adapters and all.
Section '8. From this machine'
foreach ($h in $hosts) {
    try {
        $code = Get-HttpStatus -Url "https://$($h.Host)"
        Report "https://$($h.Host)" (($code -lt 400 -or $code -eq 401) ? 'PASS' : 'FAIL') "HTTP $code"
    }
    catch {
        # Distinguish "your resolver cannot find it" from "it answered badly".
        $why = if ($_.Exception.Message -match 'No such host|not known|resolve') {
            'name does not resolve from here -- NRPT rule or VPN adapters'
        }
        else { $_.Exception.Message }
        Report "https://$($h.Host)" 'WARN' $why
    }
}

# ================================================================ 9. tls
# Is Traefik serving the Let's Encrypt wildcard, or still its own self-signed
# placeholder? One handshake with SNI against the node answers for every host.
Section '9. TLS'
if ($hosts.Count -gt 0) {
    $sni = $hosts[0].Host
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new($nodeIp, 443)
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($sni)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $issuer = $cert.Issuer
        $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
        $ssl.Dispose(); $tcp.Dispose()
        if ($issuer -match "Let's Encrypt") {
            Report "certificate for $sni" (($days -gt 14) ? 'PASS' : 'WARN') "$($cert.Subject) by $issuer, $days days left"
        }
        elseif ($issuer -match 'TRAEFIK DEFAULT') {
            Report "certificate for $sni" 'FAIL' 'Traefik self-signed placeholder -- kubectl -n traefik describe certificate lab-wildcard'
        }
        else {
            Report "certificate for $sni" 'WARN' "issued by $issuer"
        }
    }
    catch { Report "certificate for $sni" 'FAIL' $_.Exception.Message }
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
