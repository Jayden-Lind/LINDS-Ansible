# windows.yml

The playbook makes the Windows servers and the domain agree with the code.
Each step does nothing if the setting is already correct, so you can run it
at any time. Run it after you change a file in `inventory/`.

It has two plays:

| Play | Runs on | Tag | Role | What it sets |
| --- | --- | --- | --- | --- |
| Each server | `windows_managed`, one at a time | `baseline` | `windows_baseline` | Firewall, Defender, SMB1, Print Spooler, event logs, Remote Desktop, CPU mitigations, network adapter offloads |
| | | `dc` | `windows_domain_controller` | The DNS forwarders and the resolvers of a domain controller |
| | | `ca` | `windows_ca` | The certification authority and its published templates |
| | | `fileserver` | `windows_fileserver` | Data volumes, SMB shares, NFS exports, shadow copies |
| The domain | the first host in `windows_dc` | `topology` | `windows_ad_topology` | Sites, subnets, site link, `_msdcs` delegation |
| | | `recovery` | `windows_ad_recovery` | AD Recycle Bin, FSMO roles |
| | | `dfsr` | `windows_dfsr` | The NAS replication group |
| | | `gpo` | `windows_gpo` | The GPOs that the code owns: the server baseline and the time hierarchy |
| | | `directory` | `windows_directory` | OUs, groups, users, membership, GPO links, password policy |

A server gets the settings of each group that it is in: `windows_dc`,
`windows_ca` and `windows_fileserver`. Only the servers in `windows_managed`
get them. `jd-dc-01` and `jd-fs-01` are not in that group until they are built
from the template.

## Before you start

- Use the Python environment and get a Kerberos ticket (see
  [docs/windows/README.md](../docs/windows/README.md)):
  `source .venv/bin/activate`, then `kinit -f Administrator@LINDS.COM.AU`.
- Read the README of the role that you changed.

## Procedure

**NOTE:** Merging to `main` applies this playbook to the Windows servers and the domain. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. See what would change:

   ```shell
   ansible-playbook playbooks/windows.yml --check --diff
   ```

2. Apply it:

   ```shell
   ansible-playbook playbooks/windows.yml
   ```

To do one server only, add `--limit <fqdn>`. The domain play then runs only
if that server is the first domain controller. To do one part only, add
`--tags <tag>`, for example `--tags directory`.

To install Windows updates on one server, add
`--limit <fqdn> --tags updates -e windows_baseline_updates=true`. The server
can restart.

## What it changes

- The settings of each server in `windows_managed`.
- Objects in the directory, DNS and Group Policy. Replication sends them to
  the other domain controllers.
- The servers apply a GPO change at the next Group Policy refresh, in 90 to
  120 minutes. `gpupdate /target:computer` applies it now.

## If it fails

- "credentials were rejected" or "Server not found in Kerberos database":
  run `kinit -f Administrator@LINDS.COM.AU` again.
- A server fails in the first play: the servers after it are not changed.
  Correct the cause and run the playbook again.
- Check mode shows "ignored" errors for members of a new group, or for a link
  to a new GPO: this is correct. They do not exist until the real run.
