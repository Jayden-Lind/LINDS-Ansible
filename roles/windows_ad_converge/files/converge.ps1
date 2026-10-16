param([string]$Computer, [string]$State, [int]$TimeoutSeconds)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

# The SPN a domain controller is replicated from. A domain controller
# that does not hold it for a partner cannot authenticate to that
# partner at all ("the target account name is incorrect").
$replicationSpn = 'E3514235-4B06-11D1-AB04-00C04FC2DCD2/*'

function Get-View([string]$Server) {
    # What one domain controller believes about the computer.
    try {
        $account = Get-ADComputer -Filter "Name -eq '$Computer'" -Properties pwdLastSet, servicePrincipalName -Server $Server -ErrorAction Stop
        $isDc = [bool](Get-ADDomainController -Filter "Name -eq '$Computer'" -Server $Server -ErrorAction Stop)
        # The same object with the same password and the same service
        # names: a machine changes its password as it joins, and a new
        # domain controller adds its service names after its first start.
        $spns = @($account.servicePrincipalName | Sort-Object)
        $stamp = if ($account) { "$($account.ObjectGUID)/$($account.pwdLastSet)/$($spns -join ',')" } else { '' }
        [pscustomobject]@{ server = $Server; reachable = $true; guid = $stamp; dc = $isDc; dn = $account.DistinguishedName
                           replicable = [bool]($spns | Where-Object { $_ -like $replicationSpn }) }
    } catch {
        [pscustomobject]@{ server = $Server; reachable = $false; guid = ''; dc = $false; dn = $null; replicable = $false }
    }
}

function Get-ReplicationTrouble([string]$Server) {
    # A domain controller with no inbound partner, or with one it cannot
    # pull from. A link to a server that has just been demoted (shown as
    # a deleted DSA until the topology generator clears it away) does
    # not count: it fails by design.
    $lines = @(& repadmin.exe /showrepl $Server 2>&1 | ForEach-Object { "$_".Trim() })
    $partners = 0; $source = ''; $errors = @()
    foreach ($line in $lines) {
        if ($line -match ' via RPC') { $source = $line; if ($line -notmatch 'deleted DSA|0ADEL') { $partners++ } }
        elseif ($line -match 'CONSECUTIVE FAILURES|could not add this REPLICA LINK' -and $source -notmatch 'deleted DSA|0ADEL') { $errors += "$source $line" }
    }
    if (-not $partners) { "$Server has no inbound replication partner" }
    elseif ($errors) { "${Server}: $($errors | Select-Object -First 1)" }
}

do {
    $problems = @()
    $dcs = @(Get-ADDomainController -Filter * -Server $env:COMPUTERNAME | ForEach-Object HostName)
    # Retiring a domain controller can take away the one the other
    # site replicated through. Each topology generator notices by
    # itself within 15 minutes; asking makes it now. Not while a new
    # server is being introduced: recalculating then can point another
    # site at the newcomer before that site is able to talk to it.
    if ($State -ne 'present') {
        foreach ($dc in $dcs) { & repadmin.exe /kcc $dc 2>&1 | Out-Null }
    }

    # A new domain controller's account, complete with the name it is
    # replicated under, handed to every domain controller that lacks
    # it, from here. Left to ordinary replication, the other site's only
    # way to fetch it can be the newcomer itself, which it cannot yet
    # authenticate to: that left JD without replication for a day.
    if ($Computer -and $State -eq 'present') {
        $mine = Get-View $env:COMPUTERNAME
        if ($mine.dc -and $mine.replicable) {
            $subject = Get-ADDomainController -Identity $Computer -Server $env:COMPUTERNAME
            foreach ($dc in $dcs | Where-Object { $_ -notlike "$env:COMPUTERNAME.*" -and $_ -notlike "$Computer.*" }) {
                if (-not (Get-View $dc).replicable) {
                    foreach ($object in $mine.dn, $subject.ServerObjectDN, $subject.NTDSSettingsObjectDN) {
                        try { Sync-ADObject -Object $object -Source $env:COMPUTERNAME -Destination $dc -ErrorAction Stop }
                        catch { $problems += "push to ${dc}: $($_.Exception.Message)" }
                    }
                }
            }
        }
    }

    # Pull mode, on every domain controller: each one fetches from all
    # of its partners, across the site link too (/e). Twice, because a
    # change can be two hops away. A push (/P) from the one that has
    # the change reported success and moved nothing here.
    foreach ($round in 1, 2) {
        foreach ($dc in $dcs) {
            $out = & repadmin.exe /syncall $dc /Aed 2>&1
            if ($LASTEXITCODE -ne 0 -or ($out -match 'Error contacting server|SyncAll exited with fatal')) {
                $problems += "${dc}: " + (($out | Where-Object { $_ -match 'rror' } | Select-Object -First 1) -replace '\s+', ' ')
            }
        }
    }

    $agreed = $true
    $views = @()
    if ($Computer) {
        $views = @($dcs | ForEach-Object { Get-View $_ })
        $reachable = @($views | Where-Object reachable)
        if ($State -eq 'absent') {
            $agreed = -not ($reachable | Where-Object { $_.guid -or $_.dc })
        } else {
            $mine = (Get-View $env:COMPUTERNAME).guid
            $agreed = $mine -and -not ($reachable | Where-Object { $_.guid -ne $mine })
        }
        # A domain controller nobody can reach has not agreed to
        # anything; keep trying until the time runs out.
        if ($reachable.Count -ne $views.Count) { $agreed = $false }
    }
    # Agreement about one object proves little if a domain controller
    # has stopped receiving anything else.
    $trouble = @($dcs | ForEach-Object { Get-ReplicationTrouble $_ } | Where-Object { $_ })
    if ($trouble) { $agreed = $false }
    if (-not $agreed) { Start-Sleep -Seconds 20 }
} until ($agreed -or (Get-Date) -gt $deadline)

if (-not $agreed) {
    $detail = ($views | ForEach-Object { "$($_.server): reachable=$($_.reachable) account=$([bool]$_.guid) dc=$($_.dc)" }) -join '; '
    throw "The domain controllers do not agree, or do not all replicate (computer '$Computer', wanted: $State). $detail. Replication: $(($trouble + $problems) -join ' | ')"
}
[pscustomobject]@{ domain_controllers = $dcs; problems = $problems }
