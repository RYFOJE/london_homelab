#Requires -Version 7.0
<#
.SYNOPSIS
    Print every service credential the cluster holds, decoded.

.DESCRIPTION
    Reads the Secrets that operators and Terraform wrote and prints them as
    a table plus ready-to-paste connection strings. Nothing here is stored
    anywhere else: lose the cluster and these change.

    Not listed: the Authentik admin (akadmin) -- you set that in the
    initial-setup flow and it lives only in Authentik's database.

.PARAMETER Only
    Show one service: argocd, grafana, postgres, rabbitmq, elasticsearch,
    pgadmin, kibana.

.EXAMPLE
    ./scripts/credentials.ps1
    ./scripts/credentials.ps1 -Only postgres
#>
[CmdletBinding()]
param(
    [ValidateSet('argocd', 'grafana', 'postgres', 'rabbitmq', 'elasticsearch', 'pgadmin', 'kibana')]
    [string]$Only
)

$ErrorActionPreference = 'Stop'

function Get-SecretValue {
    param([string]$Namespace, [string]$Name, [string]$Key)
    $b64 = & kubectl -n $Namespace get secret $Name -o jsonpath="{.data.$Key}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $b64) { return $null }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

# service, namespace, secret, user (key or literal prefixed with '='), password key
$catalog = @(
    @{ Service = 'argocd';        Url = 'https://argocd.lab.ryfoje.com';   Ns = 'argocd';        Secret = 'argocd-initial-admin-secret';   User = '=admin';   Pass = 'password' }
    @{ Service = 'grafana';       Url = 'https://grafana.lab.ryfoje.com';  Ns = 'observability'; Secret = 'grafana-admin';                 User = 'admin-user'; Pass = 'admin-password' }
    @{ Service = 'postgres';      Url = '192.168.18.80:5432 / db dev';     Ns = 'database';      Secret = 'dev-db-app';                    User = 'username'; Pass = 'password' }
    @{ Service = 'rabbitmq';      Url = 'https://rabbitmq.lab.ryfoje.com'; Ns = 'messaging';     Secret = 'rabbitmq-default-user';         User = 'username'; Pass = 'password' }
    @{ Service = 'elasticsearch'; Url = 'https://elasticsearch.lab.ryfoje.com'; Ns = 'elastic';  Secret = 'elasticsearch-es-elastic-user'; User = '=elastic'; Pass = 'elastic' }
    @{ Service = 'pgadmin';       Url = 'https://pgadmin.lab.ryfoje.com (bootstrap only; real login is Authentik)'; Ns = 'database'; Secret = 'pgadmin-admin'; User = '=see pgadmin.yaml env.email'; Pass = 'password' }
    @{ Service = 'kibana';        Url = 'anonymous service account (Kibana logs you in as this after Authentik)'; Ns = 'elastic'; Secret = 'kibana-anonymous'; User = 'username'; Pass = 'password' }
)

if ($Only) { $catalog = $catalog | Where-Object Service -eq $Only }

$rows = foreach ($c in $catalog) {
    $user = if ($c.User.StartsWith('=')) { $c.User.Substring(1) } else { Get-SecretValue $c.Ns $c.Secret $c.User }
    $pass = Get-SecretValue $c.Ns $c.Secret $c.Pass
    [pscustomobject]@{
        Service  = $c.Service
        Where    = $c.Url
        User     = $user
        Password = $pass ?? '<secret not found>'
        Secret   = "$($c.Ns)/$($c.Secret)"
    }
}

# One block per service, not Format-Table: a wide "Where" column makes
# Format-Table silently drop the Password column on a normal-width console.
foreach ($r in $rows) {
    Write-Host ''
    Write-Host $r.Service -ForegroundColor White
    Write-Host ("  where    : {0}" -f $r.Where)
    Write-Host ("  user     : {0}" -f $r.User)
    Write-Host ("  password : {0}" -f $r.Password) -ForegroundColor Yellow
    Write-Host ("  secret   : {0}" -f $r.Secret) -ForegroundColor DarkGray
}
Write-Host ''

# Connection strings for the two TCP services.
$pg = $rows | Where-Object Service -eq 'postgres'
$mq = $rows | Where-Object Service -eq 'rabbitmq'
if ($pg -and $pg.Password -notlike '<*') {
    Write-Host 'Postgres:' -ForegroundColor White
    Write-Host "  psql `"postgresql://$($pg.User):$($pg.Password)@192.168.18.80:5432/dev`""
    Write-Host "  in-cluster: postgresql://$($pg.User):$($pg.Password)@dev-db-rw.database.svc.cluster.local:5432/dev"
}
if ($mq -and $mq.Password -notlike '<*') {
    Write-Host 'RabbitMQ:' -ForegroundColor White
    Write-Host "  amqp://$($mq.User):$($mq.Password)@192.168.18.80:5672/"
    Write-Host "  in-cluster: amqp://$($mq.User):$($mq.Password)@rabbitmq.messaging.svc.cluster.local:5672/"
}
$es = $rows | Where-Object Service -eq 'elasticsearch'
if ($es -and $es.Password -notlike '<*') {
    Write-Host 'Elasticsearch:' -ForegroundColor White
    Write-Host "  curl -u elastic:$($es.Password) https://elasticsearch.lab.ryfoje.com/_cluster/health"
}
