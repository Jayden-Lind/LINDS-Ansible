# windows_dc_retire

The role retires a domain controller: it demotes the server, stops it, and
removes what is left of it in the directory and in DNS.

## What it does

`main.yml` runs on the server to retire:

1. It stops if the server holds a FSMO role or is the last domain controller.
2. It demotes the server and restarts it from inside the same session. A
   demoted server refuses new logons until it restarts.
3. It confirms that the server is a member server, and stops it.

The other task files run from the playbook:

| Task file | Runs on | What it does |
| --- | --- | --- |
| `unique-files.yml` | the server to retire | Compares its replicated files with the files of its partner. Stops if a file is only on this server. |
| `handover.yml` | the partner | Moves the FSMO roles of the server to the partner, and removes the server from its replication groups. |
| `bridgehead.yml` | the partner | Makes the partner the preferred bridgehead of its site, and waits until replication works through it in both directions. |
| `cleanup.yml` | the partner | Deletes the computer account and the empty server object, waits until no domain controller knows the server, removes its DNS records on every DNS server, and releases the bridgehead. |
| `bridgehead-release.yml` | the partner | Removes the preferred bridgehead. |

## Requirements

- A Kerberos ticket with delegation (`kinit -f Administrator@LINDS.COM.AU`).
- The domain must have another domain controller.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_dc_retire_machine` | `""` | The computer name of the server. The playbook sets it. |
| `windows_dc_retire_address` | `""` | The IPv4 address of the server. The playbook sets it. |
| `windows_dc_retire_local_password` | random | The local Administrator password after the demotion. Nobody keeps it. |
| `windows_dc_retire_shutdown` | `true` | Stop the server after the demotion. |
| `windows_dc_retire_accept_unique_files` | `false` | Continue although the server has files that its partner does not have. |
| `windows_dc_retire_keep_bridgehead` | `false` | Keep the preferred bridgehead. Set it to `true` when a new server with the same name comes next. |
| `windows_dc_retire_bridgehead_timeout` | `900` | Seconds to wait for replication through the bridgehead. |
| `windows_dc_retire_dns_settle` | `200` | Seconds between two DNS scans. |
| `windows_dc_retire_dns_timeout` | `1800` | Maximum seconds for the DNS clean-up. |

## How to use it

`playbooks/windows-retire.yml`. See `playbooks/windows-retire.md`.

## Known problems

- Replication between the sites goes through one domain controller at each
  site. If the server to retire is that one, the other site loses its partner.
  `bridgehead.yml` prevents this.
- If a new server with the same name comes next, keep the bridgehead (`-e
  windows_dc_retire_keep_bridgehead=true`). If you release it, the other site
  can choose the new server before it can authenticate to it (error 1396).
- A DNS server can write back records of the retired server for up to three
  minutes. `cleanup.yml` stops only after two clean scans 200 seconds apart.
