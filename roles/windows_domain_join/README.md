# windows_domain_join

The role joins a server to the domain with an offline domain join. No domain
password goes to the new server.

## What it does

The role has no main task file. Use one of its task files:

| Task file | Runs on | What it does |
| --- | --- | --- |
| `provision.yml` | a domain controller | Refuses if the name belongs to a domain controller. Makes the computer account and the offline-join data (`djoin /provision`), replicates the account, and keeps the data for the next step. |
| `join.yml` | the new server | Uses the offline-join data (`djoin /requestodj`), restarts, and confirms that the server is a domain member. |

## Requirements

- A Kerberos ticket (`make kinit`) for the domain controller.
- A connection to the new server as its local Administrator.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_domain` | none | The domain. The inventory sets it. |
| `windows_domain_netbios` | none | The NetBIOS name of the domain. The inventory sets it. |
| `windows_domain_join_ou` | `""` | The OU of the computer account. Empty: the default container. |
| `windows_domain_join_machine` | none | The computer name. The playbook sets it. |
| `windows_domain_join_blob` | none | The offline-join data. The playbook sets it. |

## How to use it

`make windows-join HOST=<fqdn> ADDRESS=<DHCP address>` applies it.
