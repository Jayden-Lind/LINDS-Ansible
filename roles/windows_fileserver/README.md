# windows_fileserver

The role makes a server the file server for a data disk that it did not make.
It brings the volumes online and makes the shares, the folder permissions,
the NFS exports and the shadow copy schedule.

## What it does

1. It finds each volume in `windows_fileserver_volumes` by its label, brings
   it online, makes it writable and gives it its drive letter.
2. It installs the file server roles (and NFS and DFS Replication if needed),
   and restarts if needed.
3. It removes the replication data of an earlier member from the volumes:
   `System Volume Information\DFSR` and each `DfsrPrivate` link. It does this
   only for a replication member that is not yet in a replication group.
4. If `windows_fileserver_smb_require_signing` is set, it sets if the SMB
   server requires signing. If there are shares, it turns on the firewall rule
   `File and Printer Sharing (SMB-In)`.
5. It makes each SMB share in `windows_fileserver_shares` with exactly the
   listed permissions.
6. It sets the NTFS permissions of each folder in
   `windows_fileserver_folder_permissions`. See
   [Folder permissions](#folder-permissions).
7. It sets the NFS server settings and makes each NFS export with exactly the
   listed clients.
8. It makes a scheduled task for the shadow copies of each volume.

## Folder permissions

For each folder in `windows_fileserver_folder_permissions`, the role does
these steps:

1. It gives the folder exactly these entries: `SYSTEM` and `Administrators`
   with full control, then the listed `rules`. The folder does not inherit
   from its parent. Windows then gives the new inherited entries to all items
   below the folder.
2. If `clean_below` is `true`, it examines each item below the folder. If the
   item has an own entry for an identity in
   `windows_fileserver_broad_identities`, the role removes that entry. It also
   removes the own entries for `SYSTEM`, `Administrators` and `CREATOR OWNER`,
   because the folder gives them. It keeps the other own entries, for example
   an entry for one person. Then the item inherits again.

An item without a broad entry stays as it is, also if it does not inherit.
Such an item is a folder that someone made private on purpose. The role shows
the first 20 of these items.

The role does not go into links, or into folders that have their own item in
the list. `DfsrPrivate` is a link to a folder in `System Volume Information`
that only `SYSTEM` and `Administrators` can open.

A rule has these keys:

| Key | Default | Description |
| --- | --- | --- |
| `who` | | An account, a group or a SID. |
| `rights` | | Names of `FileSystemRights`, for example `Modify` or `"CreateFiles, AppendData"`. |
| `inherit` | `ContainerInherit, ObjectInherit` | `None`: this folder only. `ObjectInherit`: the files too. |
| `propagation` | `None` | `InheritOnly`: not this folder, only the items below. `NoPropagateInherit`: one level only. |

The role writes all entries of a folder in one step. `win_acl` writes one
entry at a time, and Windows then rewrites the permissions of all items below
the folder for each entry.

**NOTE:** Set the permissions of a replicated folder on one member only. DFS
Replication copies them to the other members. If two members change the same
items, DFS Replication must settle a conflict for each item.

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
| `windows_fileserver_folder_permissions` | `[]` | The folders and their NTFS rules. |
| `windows_fileserver_broad_identities` | `Everyone`, `Authenticated Users`, `Users`, `Domain Users` | The identities that must not have an own entry below a folder with `clean_below`. |
| `windows_fileserver_report_shares` | `[NAS]` | The shares in the access report. |
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
- `playbooks/windows-nas-access.yml` shows what each domain account can do in
  each top folder (`tasks_from: access-report`). It reads only.

## Safety

**WARNING:** Step 3 deletes the replication database on the data volume. It
does this only when the server is in no replication group. Never run it on a
server that replicates.

**NOTE:** The role does not change or remove shares and exports that are not
in the list.

**WARNING:** A change to the permissions of a replicated folder changes the
permissions of each item below it. The other member then writes each file
again, and its thin pool can grow by two times the size of the folder. Read
`docs/windows/runbooks/nas-permissions.md` before you change a large folder.

**CAUTION:** A GPO wins over `windows_fileserver_smb_require_signing`. The GPO
`Server - GPO` requires signing. A server that must not require it cannot be
in an OU where that GPO is linked (`OU=Servers`, `OU=Domain Controllers`).

## Known problems

- The SMB volumes of the cluster log on as the domain account `svc-k8s-smb`
  (`windows_directory_users`). Its password is in the Vault secrets
  `linds-keyvault/smb-immich-creds` and `smb-plex-secret` (keys `username`,
  `password`, `domain`). It gets its rights from the group
  `Service Accounts`: change on `immich` and `photos`, read on
  `holiday videos`.
- An SMB session keeps the groups of the account from the start of the
  session. After you add an account to a group, close its sessions
  (`Close-SmbSession`). See `docs/windows/runbooks/nas-permissions.md`.
- An NFS client with root access reads all folders, whatever their NTFS
  permissions. An NFS user that is not root gets only the rights of an
  unmapped user, and the NAS folders give that user nothing.

- After a restart, Server for NFS can take 10 to 20 minutes to start.
- An NFS client keeps a mount to the old server. Remount it after the server
  changes.
