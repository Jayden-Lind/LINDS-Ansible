# windows_ad_converge

The role makes every domain controller replicate now, and it can wait until
all domain controllers agree about one computer account.

## What it does

1. On each domain controller, it runs `repadmin /syncall <dc> /Aed` two times.
   It also runs `repadmin /kcc` when the computer must be absent.
2. It finds each domain controller that does not have the replication name
   of the computer (`E3514235-4B06-11D1-AB04-00C04FC2DCD2/*`). It sends the
   computer account, the server object and the NTDS settings to that domain
   controller with `Sync-ADObject`.
3. It compares the computer account on all domain controllers (object GUID,
   password date, service names). It repeats steps 1 to 3 until they agree, or
   until the time-out.
4. It fails if a domain controller has no inbound partner, or has a link that
   fails. Links to a deleted domain controller do not count.

## Requirements

- A Kerberos ticket with delegation (`kinit -f Administrator@LINDS.COM.AU`).
- The role runs on one domain controller. The playbooks use the partner
  (`playbooks/tasks/windows-partner-dc.yml`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_ad_converge_computer` | `""` | The computer to wait for. Empty: replicate only. |
| `windows_ad_converge_state` | `present` | `present`: all domain controllers have the same object. `absent`: none has it. |
| `windows_ad_converge_timeout` | `900` | The maximum time, in seconds. |

## How to use it

`windows-join.yml`, `windows-promote.yml` and `windows-retire.yml` use it.
You do not run it alone.

## Known problems

- The two sites replicate every 15 minutes. Without this role, a new or
  removed computer is not known at the other site for that time. Kerberos then
  answers "Server not found in Kerberos database", or gives a ticket for the
  old server of the same name.
- A new domain controller is the only source of its own replication name. If
  the partner at the other site does not have that name, it cannot pull from
  the new server (error 1396). Step 2 prevents this.
