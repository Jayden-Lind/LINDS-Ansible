# windows.yml

The playbook applies the settings of the whole domain. Run it after you change
a file in `inventory/group_vars/windows/`.

| Tag | Role | What it sets |
| --- | --- | --- |
| `topology` | `windows_ad_topology` | Sites, subnets, site link, `_msdcs` delegation |
| `recovery` | `windows_ad_recovery` | AD Recycle Bin, FSMO roles |
| `dfsr` | `windows_dfsr` | The NAS replication group |
| `gpo` | `windows_gpo` | The GPOs that the code owns: the server baseline and the time hierarchy |
| `directory` | `windows_directory` | OUs, groups, users, membership, GPO links, password policy |

All of them run on the first domain controller in the group `windows_dc`. The
other domain controllers get the changes through replication.

## Before you start

- Run `make kinit`.
- Read the README of the role that you changed.

## Procedure

1. Run `make windows-check` to see what would change. Add `TAGS=<tag>` for one
   part.
2. Run `make windows`, or `make windows TAGS=<tag>`.
3. For the directory, use `make windows-directory-check` and
   `make windows-directory`.

## What it changes

- Objects in the directory, DNS and Group Policy. Replication sends them to
  the other domain controllers.
- The servers apply a GPO change at the next Group Policy refresh, in 90 to
  120 minutes. `gpupdate /target:computer` applies it now.

## If it fails

- "credentials were rejected" or "Server not found in Kerberos database":
  run `make kinit` again.
- Check mode shows "ignored" errors for members of a new group: this is
  correct. The group does not exist until the real run.
- Check mode shows "ignored" errors for a link to a new GPO: this is correct.
  The GPO does not exist until the real run.
