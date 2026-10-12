# Read-only. Describes the DNS zones the directory holds: their settings, and
# the records a person put there. Records that machines register for
# themselves (they carry a timestamp) are left out: they come and go by
# themselves.

$ErrorActionPreference = 'Stop'

function DataOf($record) {
    $d = $record.RecordData
    switch ("$($record.RecordType)") {
        'A'     { "$($d.IPv4Address)" }
        'AAAA'  { "$($d.IPv6Address)" }
        'CNAME' { $d.HostNameAlias }
        'NS'    { $d.NameServer }
        'PTR'   { $d.PtrDomainName }
        'MX'    { "$($d.Preference) $($d.MailExchange)" }
        'SRV'   { "$($d.Priority) $($d.Weight) $($d.Port) $($d.DomainName)" }
        'TXT'   { $d.DescriptiveText }
        default { "$($record.RecordType)" }
    }
}

$zones = @(Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' } | Sort-Object ZoneName | ForEach-Object {
    $zone = $_
    $entry = [ordered]@{
        name              = $zone.ZoneName
        type              = "$($zone.ZoneType)"
        reverse           = $zone.IsReverseLookupZone
        directory_integrated = $zone.IsDsIntegrated
        replication_scope = "$($zone.ReplicationScope)"
    }
    if ("$($zone.ZoneType)" -in 'Forwarder', 'Stub', 'Secondary') {
        # Somebody else's zone: what matters here is whom this server asks.
        $entry.master_servers = @($zone.MasterServers | ForEach-Object { "$_" })
    } else {
        $aging = Get-DnsServerZoneAging -Name $zone.ZoneName -ErrorAction SilentlyContinue
        $records = @(Get-DnsServerResourceRecord -ZoneName $zone.ZoneName)
        $entry.dynamic_update     = "$($zone.DynamicUpdate)"
        $entry.zone_transfer      = "$($zone.SecureSecondaries)"
        $entry.transfer_to        = @($zone.SecondaryServers | Where-Object { "$_" } | ForEach-Object { "$_" })
        $entry.notify             = "$($zone.Notify)"
        $entry.aging              = [bool]$aging.AgingEnabled
        $entry.no_refresh_hours   = [int]$aging.NoRefreshInterval.TotalHours
        $entry.refresh_hours      = [int]$aging.RefreshInterval.TotalHours
        # The SOA is left out: its serial number moves with every change.
        $entry.static_records = @($records | Where-Object { -not $_.Timestamp -and $_.RecordType -ne 'SOA' } | ForEach-Object {
            [ordered]@{ name = $_.HostName; type = "$($_.RecordType)"; data = DataOf $_; ttl = [int]$_.TimeToLive.TotalSeconds }
        } | Sort-Object { $_.name }, { $_.type }, { $_.data })
    }
    $entry
})

[ordered]@{ zones = $zones } | ConvertTo-Json -Depth 6 -Compress
