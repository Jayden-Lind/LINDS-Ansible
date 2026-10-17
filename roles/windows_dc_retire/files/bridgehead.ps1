param([string]$Retiring, [int]$TimeoutSeconds)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false

$me = Get-ADDomainController -Identity $env:COMPUTERNAME
$all = @(Get-ADDomainController -Filter *)
$leaving = $all | Where-Object { $_.Name -ieq $Retiring }
$outside = @($all | Where-Object { $_.Site -ne $me.Site })
if (-not $leaving -or $leaving.Site -ne $me.Site -or -not $outside) {
    # Already demoted, a different site, or a single-site domain.
    return 'nothing to move'
}

$ip = 'CN=IP,CN=Inter-Site Transports,CN=Sites,' + (Get-ADRootDSE).configurationNamingContext
$mine = Get-ADObject -Identity $me.ServerObjectDN -Properties bridgeheadTransportList
if ($mine.bridgeheadTransportList -notcontains $ip) {
    Set-ADObject -Identity $me.ServerObjectDN -Add @{ bridgeheadTransportList = $ip }
    $Ansible.Changed = $true
}

function Get-Links([string]$Server) {
    & repadmin.exe /showrepl $Server /csv 2>$null | ConvertFrom-Csv |
        Where-Object { $_.'Last Success Time' -match '^\d{4}-' }
}

$started = (Get-Date).AddSeconds(-5)
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    # Twice round: the other site has to receive the preference before
    # its topology generator can act on it.
    foreach ($round in 1, 2) {
        foreach ($dc in $all) { & repadmin.exe /kcc $dc.HostName 2>&1 | Out-Null }
        foreach ($dc in $all) { & repadmin.exe /syncall $dc.HostName /Aed 2>&1 | Out-Null }
    }

    # Proof, not topology: a successful pull through this server, in
    # each direction, since this task began.
    $waiting = @()
    foreach ($dc in $outside) {
        $viaMe = Get-Links $dc.HostName | Where-Object {
            $_.'Source DSA' -ieq $me.Name -and [datetime]$_.'Last Success Time' -ge $started
        }
        if (-not $viaMe) { $waiting += "$($dc.Name) has not pulled from $($me.Name)" }
    }
    $inbound = Get-Links $me.HostName | Where-Object {
        $_.'Source DSA Site' -ne $me.Site -and [datetime]$_.'Last Success Time' -ge $started
    }
    if (-not $inbound) { $waiting += "$($me.Name) has not pulled from another site" }

    if ($waiting) { Start-Sleep -Seconds 20 }
} until (-not $waiting -or (Get-Date) -gt $deadline)

if ($waiting) {
    throw "Replication between the sites still depends on ${Retiring}: $($waiting -join '; '). Not demoting it. Look at repadmin /showrepl on both sides; the preferred bridgehead setting on $($me.Name) is still in place."
}
"replication between the sites runs through $($me.Name)"
