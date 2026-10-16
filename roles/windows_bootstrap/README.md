# windows_bootstrap

The role gives a new clone of the template its computer name and its static
IPv4 address.

## What it does

1. It waits until the clone answers WinRM at its DHCP address. Windows setup
   refuses all logons until it is complete.
2. It gives the clone a script that sets the name, the address, the gateway
   and the DNS servers 20 seconds later, and then restarts the server.

## Requirements

- A connection as the local Administrator at the DHCP address
  (`playbooks/vars/windows-local-admin.yml`).

## Variables

The role has no defaults. It uses these host variables from
`inventory/windows.yml`:

| Variable | Description |
| --- | --- |
| `windows_hostname` | The computer name, for example `LINDS-DC2`. |
| `windows_ipv4_address` | The static IPv4 address. |
| `windows_ipv4_prefix` | The prefix length, for example `24`. |
| `windows_ipv4_gateway` | The default gateway. |
| `windows_dns_servers` | The resolvers. For a domain member, use domain controllers. |

## How to use it

`make windows-join HOST=<fqdn> ADDRESS=<DHCP address>` applies it.

## Known problems

- Ansible cannot rename and re-address a server over the connection that it
  uses. Thus the change runs 20 seconds after the task, and the next play
  waits for the server at its new address.
- Server 2025 locks the local Administrator for 10 minutes after 10 bad
  logons.
