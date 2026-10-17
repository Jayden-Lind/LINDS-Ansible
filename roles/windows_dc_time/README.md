# windows_dc_time

The role makes the PDC emulator the time source of the domain. The other
domain controllers follow the domain hierarchy.

## What it does

1. It finds out if this domain controller holds the PDC emulator role.
2. On the PDC emulator, it sets `ntp_servers` as the external source and
   marks the server as a reliable time source.
3. On the other domain controllers, it sets the time type to the domain
   hierarchy (NT5DS).

## Requirements

- A Kerberos ticket (`make kinit`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `ntp_servers` | `pool.ntp.org` | The external NTP servers. The inventory sets the Australian pool. |

## How to use it

`make windows` applies it to all domain controllers (tag `time`).

## Known problems

- The Default Domain Policy sets all members, also the domain controllers, to
  NTP with `0.au.pool.ntp.org`. The policy wins. The role reports `ok`, but
  `w32tm /query /source` shows the pool. Move that setting to a policy that
  applies only to the PDC emulator.
