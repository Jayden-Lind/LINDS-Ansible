param([string]$Machine, [string]$Address, [string]$Domain, [int]$SettleSeconds, [int]$TimeoutSeconds)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false
$fqdn = "$Machine.$Domain."
# The address records a domain controller registers for itself.
# Any other name at that address was put there by a person and is
# left alone, in case the replacement is to answer to it too.
$ownNames = @($Machine, '@', 'DomainDnsZones', 'ForestDnsZones', 'gc', 'gc._msdcs')
$removed = @()
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$cleanScans = 0

do {
    $found = 0
    $unreachable = @()
    foreach ($server in (Get-ADDomainController -Filter * | ForEach-Object HostName)) {
        try {
            $zones = Get-DnsServerZone -ComputerName $server | Where-Object {
                $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors'
            }
            foreach ($zone in $zones) {
                $stale = Get-DnsServerResourceRecord -ComputerName $server -ZoneName $zone.ZoneName | Where-Object {
                    $d = $_.RecordData
                    ($_.RecordType -eq 'A' -and $d.IPv4Address.IPAddressToString -eq $Address -and $_.HostName -in $ownNames) -or
                    ($_.RecordType -eq 'NS' -and $d.NameServer -ieq $fqdn) -or
                    ($_.RecordType -eq 'CNAME' -and $d.HostNameAlias -ieq $fqdn) -or
                    ($_.RecordType -eq 'SRV' -and $d.DomainName -ieq $fqdn) -or
                    ($_.RecordType -eq 'PTR' -and $d.PtrDomainName -ieq $fqdn)
                }
                foreach ($record in $stale) {
                    $found++
                    try {
                        $record | Remove-DnsServerResourceRecord -ComputerName $server -ZoneName $zone.ZoneName -Force
                        $removed += "$($record.RecordType) $($record.HostName) in $($zone.ZoneName) on $(($server -split '\.')[0])"
                    } catch {
                        # Already gone by replication between the listing and the delete.
                    }
                }
            }
        } catch {
            $unreachable += "$(($server -split '\.')[0]): $($_.Exception.Message)"
        }
    }
    if ($found -or $unreachable) { $cleanScans = 0 } else { $cleanScans++ }
    if ($cleanScans -lt 2) { Start-Sleep -Seconds $SettleSeconds }
} until ($cleanScans -ge 2 -or (Get-Date) -gt $deadline)

if ($cleanScans -lt 2) {
    throw "DNS records for $Machine kept coming back, or a DNS server could not be asked. $($unreachable -join '; ')"
}
$Ansible.Changed = $removed.Count -gt 0
$removed
