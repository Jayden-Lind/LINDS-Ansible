# windows_dns

The role makes the DNS records in `windows_dns_records` exist in the zones of
the domain.

## What it does

1. For each record in `windows_dns_records`, it makes the record with its
   value and its TTL.
2. If the name already has records of that type with other values, it removes
   them. Each name and type then has only the values in the list.

The role does not remove a record that is not in the list. Most records in the
zones are not in the code: machines register their own records, and the
records that were made by hand are listed in `windows-state/dns/records/`.

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`).
- The zone of each record must exist.

## Variables

Set them in `inventory/group_vars/windows/dns.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `windows_dns_records` | `[]` | `{zone, name, type, value, ttl}` for each record. `name` is relative to the zone. `value` is a value or a list of values. `ttl` is in seconds: 3600 if it is not set. |

## How to use it

`playbooks/windows.yml` applies it (tag `dns`).

The records that the role makes are static. The capture
(`playbooks/windows/capture.yml`) therefore also lists them in
`windows-state/dns/records/`.

## Known problems

- **CAUTION:** Do not add a name that a machine registers for itself. The role
  replaces that record with a static record, and the machine then cannot
  change its address in DNS.
