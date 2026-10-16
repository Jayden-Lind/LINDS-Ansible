# windows_fileserver

The role makes a server the file server for a data disk that it did not make.
It brings the volumes online and makes the shares, the NFS exports and the
shadow copy schedule.

## What it does

1. It finds each volume in `windows_fileserver_volumes` by its label, brings
   it online, makes it writable and gives it its drive letter.
2. It installs the file server roles (and NFS and DFS Replication if needed),
   and restarts if needed.
3. If the server is a replication member and is not yet in a replication
   group, it removes the replication data of an earlier member from the
   volumes (`System Volume Information\DFSR` and each `DfsrPrivate` link).
4. It makes each SMB share in `windows_fileserver_shares` with exactly the
   listed permissions.
5. It sets the NFS server settings and makes each NFS export with exactly the
   listed clients.
6. It makes a scheduled task for the shadow copies of each volume.

File permissions are on the disk. They name domain accounts, so they do not
change.

## Requirements

- The data disk is attached to the VM (`make windows-data-disk`).
- A Kerberos ticket (`make kinit`).

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

## How to use it

`make windows-promote HOST=<fqdn>` applies it to a host in the group
`windows_fileserver`.

## Safety

**WARNING:** Step 3 deletes the replication database on the data volume. It
does this only when the server is in no replication group. Never run it on a
server that replicates.

**NOTE:** The role does not change or remove shares and exports that are not
in the list.

## Known problems

- After a restart, Server for NFS can take 10 to 20 minutes to start.
- An NFS client keeps a mount to the old server. Remount it after the server
  changes.
