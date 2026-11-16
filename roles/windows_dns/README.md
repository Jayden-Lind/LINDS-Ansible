# windows_dns

The role makes the DNS zones in `windows_dns_zones` and the DNS records in
`windows_dns_records` exist in the domain.

## What it does

1. For each zone in `windows_dns_zones`, it makes a primary zone that is
   stored in AD, or it sets the replication scope and the dynamic update
   setting of the zone if the zone exists.
2. For each record in `windows_dns_records`, it makes the record with its
   value and its TTL.
3. If the name already has records of that type with other values, it removes
   them. Each name and type then has only the values in the list.

The role does not remove a zone or a record that is not in the list. Most
records in the zones are not in the code: machines register their own records,
and the records that were made by hand are listed in
`windows-state/dns/records/`.

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`).
- The zone of each record must exist or be in `windows_dns_zones`.

## Variables

Set them in `inventory/group_vars/windows/dns.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `windows_dns_zones` | `[]` | `{name, replication, dynamic_update}` for each zone. `replication` is `forest` or `domain`. `dynamic_update` is `secure`, `nonsecureandsecure` or `none`. |
| `windows_dns_records` | `[]` | `{zone, name, type, value, ttl}` for each record. `name` is relative to the zone. `value` is a value or a list of values. `ttl` is in seconds: 3600 if it is not set. |

## How to use it

`playbooks/windows.yml` applies it (tag `dns`).

The records that the role makes are static. The capture
(`playbooks/windows/capture.yml`) therefore also lists them in
`windows-state/dns/records/`.

## Known problems

- `ansible.windows.win_dns_zone` fails in check mode for a zone that does not
  exist. The role therefore does not give such a zone to the module in check
  mode. It shows the zone as changed ("The role would make the zone ...").
- The role does not set aging on a zone (the module has no setting for it).
  Scavenging is off on all the DNS servers, so aging has no effect.
- **CAUTION:** Do not add a name that a machine registers for itself. The role
  replaces that record with a static record, and the machine then cannot
  change its address in DNS.
