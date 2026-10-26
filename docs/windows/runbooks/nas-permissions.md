# Change the permissions of the NAS folders

The NAS folders are on `jd-fs-01` (`D:`) and on `linds-dc` (`E:`). DFS
Replication keeps the two copies the same, also their NTFS permissions.

## Who can do what

| Folder | Family (`FreeNAS Read & Write`) | Cluster (`Service Accounts`) | Other domain accounts |
| --- | --- | --- | --- |
| `business doc`, `holiday videos`, `Music`, `papa usb`, `photos` | Change | Read (`photos`: change) | Read |
| `jayden`, `cheryls files`, `zoe` | Change | None | None |
| `personal files` | Read all, add files, change own files | None | None |
| `immich` | Read | Change | None |
| `server` | None | None | None |

Administrators have full control of all folders.

Two layers give these rights:

- The share `NAS` sets the upper limit for each group: administrators full,
  the family and the cluster change, the other domain accounts read. The share
  is in `fileserver.vault.yml` of each server.
- The NTFS permissions of each folder set the rest. They are in
  `inventory/host_vars/jd-fs-01.linds.com.au/fileserver.yml`. The role
  `windows_fileserver` applies them.

## Check the rights

1. Run `ansible-playbook playbooks/windows-nas-access.yml`.
2. Compare each table with the table above.

## Change the share permissions

A change to a share has an effect immediately. DFS Replication does not
replicate it.

1. Edit `fileserver.vault.yml` of both servers with `ansible-vault edit`.
2. Run `ansible-playbook playbooks/windows.yml --tags fileserver --limit <fqdn>`
   for each server.
3. If you added an account to a group, close the SMB sessions of that account.
   See the caution below.

**CAUTION:** An SMB session keeps the groups that the account had when the
session started. If you add an account to a group, the share does not see
this until the client connects again. The cluster mounts never disconnect.
Close the sessions of `svc-k8s-smb` on the file server:
`Get-SmbSession | Where-Object ClientUserName -eq 'LINDS\svc-k8s-smb' | Close-SmbSession -Force`.
The cluster connects again in less than one minute.

## Change the NTFS permissions of a small folder

1. Edit the folder in `inventory/host_vars/jd-fs-01.linds.com.au/fileserver.yml`.
2. Run the role in check mode:
   `ansible-playbook playbooks/windows.yml --tags fileserver --limit jd-fs-01.linds.com.au --check`.
3. Read the output. It shows how many items below each folder change.
4. Run the same command without `--check`.
5. Monitor the backlog to `linds-dc` until it is empty
   ([replication.md](replication.md)).

**WARNING:** Do not set the replicated folders on `linds-dc` too. If both
members change the same files, DFS Replication settles a conflict for each
file and writes the files again on both members.

## What a change costs

A change to the permissions of a folder changes each item below it. DFS
Replication then does these steps for each file:

1. `jd-fs-01` reads the file and writes a copy into its staging folder.
2. `linds-dc` writes a copy into its staging folder, then writes the file
   again. It reads and writes about 2.8 times the size of the folder.
3. While shadow copies of `E:` exist, the old blocks of each file stay on the
   thin pool `NAS` of `linds-proxmox-01`. The pool grows by about 2 times the
   size of the folder.

The staging copies stay until the staging quota of the folder is full. The
old blocks stay until Windows deletes the shadow copies that hold them.

Measured on 19 October 2026:

| Folder | Size | `linds-dc` reads | `linds-dc` writes | Pool `NAS` | Time |
| --- | --- | --- | --- | --- | --- |
| `Music` | 4.6 GB | 13.0 GB | 13.0 GB | +8.9 GiB | 4 minutes |

## Change a large folder

A large folder is one that holds more than about 200 GB, or a change to
several folders at the same time. Without shadow copies of `E:`, the pool
grows by about the staging quota of each folder. With them, it grows by about
2 times the size of the folders.

Before you start:

- Make sure that the pool `NAS` is below 65 %:
  `ssh root@192.168.6.205 lvs NAS/NAS`.
- Make sure that a Kerberos ticket stays valid for the whole run. Get one that
  you can renew for a week: `kinit -f -r 7d Administrator@LINDS.COM.AU`.

Procedure:

1. Delete the shadow copies of `E:` on `linds-dc`:
   `vssadmin delete shadows /for=E: /all /quiet`. `jd-fs-01` keeps its own
   shadow copies of `D:`.
2. Disable the scheduled task `shadow-copy-E` on `linds-dc`.
3. Free the space that the shadow copies kept ([thin-storage.md](thin-storage.md)).
4. Set the full-sync staging quotas
   ([replication.md](replication.md#staging-quotas)).
5. Change the folders in `fileserver.yml`, and apply them as for a small
   folder.
6. Monitor the pool every hour. If it reaches 80 %, stop DFS Replication on
   `linds-dc` (`Stop-Service DFSR`), and find what holds the space.
7. When the backlog is empty, enable `shadow-copy-E` again, and set the normal
   staging quotas again.

**WARNING:** If the pool `NAS` becomes full, new blocks of `E:` silently
become zeros. Never let it reach 100 %.

**NOTE:** `linds-dc` finishes 5 to 12 MB/s of files: its disks are four hard
disks in RAID 5. A change to all NAS folders took 6.6 days in October 2026. While the backlog is large, new files reach `linds-dc`
only after the files that are in the backlog before them.
