# windows_domain_join

The role joins a server to the domain with an offline domain join. No domain
password goes to the new server.

## What it does

The role has no main task file. Use one of its task files:

| Task file | Runs on | What it does |
| --- | --- | --- |
| `provision.yml` | a domain controller | Refuses if the name belongs to a domain controller. Makes the computer account (`microsoft.ad.computer`) and the offline-join data (`microsoft.ad.offline_join`), replicates the account, and keeps the data for the next step. |
| `join.yml` | the new server | Uses the offline-join data (`microsoft.ad.membership`), restarts, and confirms that the server is a domain member. |

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`) for the domain
  controller.
- A connection to the new server as its local Administrator.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_domain` | none | The domain. The inventory sets it. |
| `windows_domain_netbios` | none | The NetBIOS name of the domain. The inventory sets it. |
| `windows_domain_join_ou` | `""` | The OU of the computer account, as a full DN. If the account exists in another OU, the role moves it. Empty: a new account goes to the default container, and an existing account does not move. |
| `windows_domain_join_machine` | none | The computer name. The playbook sets it. |
| `windows_domain_join_blob` | none | The offline-join data. The playbook sets it. |

## How to use it

`playbooks/windows-join.yml` applies it. See `playbooks/windows-join.md`.
