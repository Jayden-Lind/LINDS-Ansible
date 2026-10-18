# windows_fileserver

The role makes a server the file server for a data disk that it did not make.
It brings the volumes online and makes the shares, the NFS exports and the
shadow copy schedule.

## What it does

1. It finds each volume in `windows_fileserver_volumes` by its label, brings
   it online, makes it writable and gives it its drive letter.
2. It installs the file server roles (and NFS and DFS Replication if needed),
   and restarts if needed.
3. It removes the replication data of an earlier member from the volumes:
   `System Volume Information\DFSR` and each `DfsrPrivate` link. It does this
   only for a replication member that is not yet in a replication group.
4. If `windows_fileserver_smb_require_signing` is set, it sets if the SMB
   server requires signing.
5. It makes each SMB share in `windows_fileserver_shares` with exactly the
   listed permissions.
6. It sets the NFS server settings and makes each NFS export with exactly the
   listed clients.
7. It makes a scheduled task for the shadow copies of each volume.

File permissions are on the disk. They name domain accounts, so they do not
change.

## Requirements

- The data disk is attached to the VM (`playbooks/windows-data-disk.yml`).
- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`).

## Variables

Set them in `inventory/host_vars/<fqdn>/`. The shares are in
`fileserver.vault.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `windows_fileserver_volumes` | `[]` | `{label, letter}` for each data volume. |
| `windows_fileserver_shares` | `[]` | The SMB shares and their permissions. |
| `windows_fileserver_nfs_shares` | `[]` | The NFS exports and their clients. |
| `windows_fileserver_nfs_server` | `{}` | Settings for `Set-NfsServerConfiguration`. |
| `windows_fileserver_shadow_copies` | `[]` | `{letter, days, times}` for each volume. |
| `windows_fileserver_replication` | `false` | `true`: the server is a DFS Replication member. |
| `windows_fileserver_smb_require_signing` | not set | `false`: clients can connect without SMB signing. Not set: the role does not change it. |

## How to use it

- `playbooks/windows.yml` applies it to a host in `windows_fileserver` and
  `windows_managed` (tag `fileserver`).
- `playbooks/windows-promote.yml` applies it to a new server in
  `windows_fileserver`.

## Safety

**WARNING:** Step 3 deletes the replication database on the data volume. It
does this only when the server is in no replication group. Never run it on a
server that replicates.

**NOTE:** The role does not change or remove shares and exports that are not
in the list.

**CAUTION:** A GPO wins over `windows_fileserver_smb_require_signing`. The GPO
`Server - GPO` requires signing. A server that must not require it cannot be
in an OU where that GPO is linked (`OU=Servers`, `OU=Domain Controllers`).

## Known problems

- After a restart, Server for NFS can take 10 to 20 minutes to start.
- An NFS client keeps a mount to the old server. Remount it after the server
  changes.
