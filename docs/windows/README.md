# Windows domain (linds.com.au)

This repository manages four Windows Server 2025 VMs over WinRM with Kerberos.
LINDS-Terraform makes the VMs. Ansible configures what runs in them, and can
build a server from a clone of the template.

| Host | Address | Site | Roles |
| --- | --- | --- | --- |
| `jd-dc-01` | 10.0.50.200 | JD | Domain controller, DNS, PDC emulator, RID master |
| `jd-fs-01` | 10.0.50.201 | JD | File server, `D:` (12 TB) |
| `linds-dc` | 10.3.1.200 | LINDS | Domain controller, DNS, schema, naming and infrastructure master, CA `linds-CA`, file server, `E:` (11 TB) |
| `linds-dc2` | 10.3.1.201 | LINDS | Domain controller, DNS |

## Start here

Run every command from the top directory of the repository.

1. Make the Python environment one time:

   ```shell
   /usr/bin/python3 -m venv .venv
   .venv/bin/pip install -r requirements-windows.txt
   ansible-galaxy collection install -r requirements.yml
   ```

2. At the start of each session, use the environment and get a Kerberos
   ticket. `kinit` asks for the password of the domain administrator:

   ```shell
   source .venv/bin/activate
   kinit -f Administrator@LINDS.COM.AU
   ```

3. Run `ansible-playbook playbooks/windows.yml --check --diff` to see if the
   domain agrees with the code.

**NOTE:** `-f` makes the ticket forwardable. The GPO cmdlets need it. DNS
finds the domain controllers, so Kerberos needs no configuration file. The
ticket is in `/tmp/krb5cc_<uid>`, so a restart of the control node removes it.

**NOTE:** A playbook for one server takes the server with
`-e target=<fqdn>`. A playbook for a new clone also takes its DHCP address
with `-e bootstrap_address=<address>`.

## What to use for each job

| Job | Command | Page |
| --- | --- | --- |
| Make the servers and the domain agree with the code | `ansible-playbook playbooks/windows.yml` | [windows.md](../../playbooks/windows.md) |
| Do one server only | `ansible-playbook playbooks/windows.yml --limit <fqdn>` | [windows.md](../../playbooks/windows.md) |
| Do one part only, for example the directory | `ansible-playbook playbooks/windows.yml --tags directory` | [windows.md](../../playbooks/windows.md) |
| Record the state of the domain | `ansible-playbook playbooks/windows-capture.yml` | [windows-capture.md](../../playbooks/windows-capture.md) |
| Back up the CA | `ansible-playbook playbooks/windows-ca-backup.yml` | [windows-ca-backup.md](../../playbooks/windows-ca-backup.md) |
| Build a new server | prepare, edition, join, promote | [build-a-server.md](build-a-server.md) |
| Replace a domain controller | retire, then build | [runbooks/replace-a-domain-controller.md](runbooks/replace-a-domain-controller.md) |
| Replace a file server that is not a domain controller | retire, then build | [runbooks/replace-a-file-server.md](runbooks/replace-a-file-server.md) |
| Add a replicated folder | edit the inventory, then `ansible-playbook playbooks/windows.yml` | [runbooks/replication.md](runbooks/replication.md) |
| See or change who can open the NAS folders | `ansible-playbook playbooks/windows-nas-access.yml` | [runbooks/nas-permissions.md](runbooks/nas-permissions.md) |
| Update the VirtIO drivers and the guest agent | installer from the virtio-win ISO, one restart | [runbooks/update-virtio-drivers.md](runbooks/update-virtio-drivers.md) |

## Where the settings are

| File | Contents |
| --- | --- |
| `inventory/windows.yml` | The servers, their groups, addresses and VMs |
| `inventory/group_vars/windows/main.yml` | The domain, the WinRM connection, DNS forwarders, NTP, CPU mitigations, IPv6 |
| `inventory/group_vars/windows/topology.yml` | Sites, subnets, site link, FSMO role holders |
| `inventory/group_vars/windows/replication.yml` | The NAS replication group |
| `inventory/group_vars/windows/gpo.yml` | The GPOs that the code owns: the server baseline and the time hierarchy |
| `inventory/group_vars/windows/directory.yml` | OUs, GPO links, owned groups |
| `inventory/group_vars/windows/directory.vault.yml` | Users, members, privileged groups, password policy (vault) |
| `inventory/group_vars/windows/vault.yml` | The template Administrator password and the restore-mode password (vault) |
| `inventory/host_vars/<fqdn>/` | Settings of one server, for example the shares of a file server |
| `windows-state/` | The captured state of the domain, and the CA backup |

## Rules

- The repository is public. Put secrets only in vault files. Never paste the
  content of a vault file into a pull request or a page.
- Do not use CredSSP. The GPO cmdlets need Kerberos delegation; the inventory
  turns it on.
- Build the Python environment with `/usr/bin/python3`. `pykerberos` does not
  load under the nix Python.
- Group variables must be in `inventory/group_vars/`. A `group_vars/` at the
  top of the repository is not read.
- There are no system-state backups, by decision. If a domain controller is
  lost, build a new one. If the directory is lost, make the domain again with
  `windows-forest.yml` (see [windows-forest.md](../../playbooks/windows-forest.md)).
- The code owns the GPOs in `inventory/group_vars/windows/gpo.yml` (role
  `windows_gpo`). Change them there, not in GPMC. Edit the other GPOs in GPMC.
  `ansible-playbook playbooks/windows-capture.yml` keeps a backup of each GPO.
- Use a module of `microsoft.ad`, `ansible.windows` or `community.windows`
  where one exists. Write PowerShell only for what no module does, and put a
  long script in the `files/` directory of the role.

## Notes for a person who changes the code

- `playbooks/windows.yml` must change nothing on a second run, and
  `--check` must show the true changes. Test both before a merge.
- A PowerShell task that changes something must start with
  `[CmdletBinding(SupportsShouldProcess)]`. Without it, `win_powershell` does
  not run the script in check mode and reports a change. The script must not
  make the change if `$Ansible.CheckMode` is true.
- A PowerShell task that only reads must have `check_mode: false`.
- In a playbook, use `import_role` and `import_tasks`. A tag on
  `include_role` does not reach the tasks of the role.
- Do not use `delegate_to` from one Windows host to another. The task keeps
  `ansible_winrm_kerberos_hostname_override` of the first host, and Kerberos
  fails. Use a separate play for the other host.
- A play on `localhost` needs `connection: local`. `inventory/wsl.yml` lists
  `localhost` as an SSH host.
- In a script that supports check mode, `ForEach-Object <property>` returns
  nothing under `-WhatIf`. Use a script block.
- Put a PowerShell script of more than about 25 lines in `files/` of the role,
  and load it with `lookup('ansible.builtin.file', '<name>.ps1')`. The script
  then gets no Jinja templating, so give values as `parameters`.
- Write all text in STE ([docs/STYLE.md](../STYLE.md)).

## Runbooks

| Runbook | When to use it |
| --- | --- |
| [replace-a-domain-controller.md](runbooks/replace-a-domain-controller.md) | A domain controller must be rebuilt |
| [replace-a-file-server.md](runbooks/replace-a-file-server.md) | A file server that is not a domain controller must be rebuilt |
| [replication.md](runbooks/replication.md) | DFS Replication: add a folder, join a member again, faults |
| [directory-replication.md](runbooks/directory-replication.md) | AD replication between the sites fails |
| [thin-storage.md](runbooks/thin-storage.md) | A data disk uses more space on the host than Windows shows |
| [shadow-copies.md](runbooks/shadow-copies.md) | Restore files from Previous Versions |
| [wrong-clock.md](runbooks/wrong-clock.md) | A server starts with the wrong time |
| [certificate-enrolment.md](runbooks/certificate-enrolment.md) | Computers cannot enrol certificates |
| [entra-connect.md](runbooks/entra-connect.md) | Sync the domain to Entra again |
| [update-virtio-drivers.md](runbooks/update-virtio-drivers.md) | A new VirtIO driver version is out, or a clone has old drivers |

## Known problems

- Nothing syncs to Entra. See [runbooks/entra-connect.md](runbooks/entra-connect.md).
- The DNS zone `linds.com.au` accepts non-secure dynamic updates, and
  scavenging is off.
- `Optimize-Volume -ReTrim` fails on all servers with `0x80070001`. See
  [runbooks/thin-storage.md](runbooks/thin-storage.md).
- `jd-dc-01` has 8 GB free on `C:`. It has two scheduled tasks
  `ShadowCopyVolume{...}` for volumes that do not exist.
- `jd-dc-01` is not yet built from the template. `jd-fs-01` is (VM 1113, 19
  October 2026).
- `linds-dc2` reports that Windows is not activated. The other servers were
  not checked.
- On the LINDS host, VM 102 (`LINDS-DC-old`) must stay. It owns the NAS disk
  that VM 113 (`linds-dc`) uses. Do not start it. Its own system disk (74 GB
  used) can go. VM 110 (`LINDS-DC2-old`) is off and can go.
- `E:\server\old_backup` on `linds-dc` holds 248 GB of Veeam backups from
  2019 to 2021, of hosts that do not exist.
