# plex

The `plex` role installs Plex Media Server and mounts the media shares with
systemd automounts. It is for Debian and Ubuntu hosts.

## What it does

1. Loads `vars/plex.yml` (the SMB user and password, in the vault) into the
   variable `plex`.
2. Installs `curl`, `gnupg2` and `python3-debian`, adds the Plex signing key
   and the Plex repository (`/etc/apt/sources.list.d/plex.sources`), and
   installs and starts `plexmediaserver`.
3. Installs `nfs-common` and `cifs-utils`.
4. Writes the SMB user, password and domain to `plex_smb_credentials_file`,
   which only root reads.
5. Adds one line to `/etc/fstab` for each of three mounts under `/mnt/`, with
   the option `x-systemd.automount`. systemd mounts a share when a program
   first opens its path, and unmounts it after `plex_mount_idle_timeout`
   seconds without use. No daemon is necessary for this.
6. If the host has autofs (the role used it until 2026-11): stops Plex Media
   Server, removes autofs and its maps, makes the mounts as above, and starts
   Plex Media Server again.

| Mount | Source | Type |
| --- | --- | --- |
| `/mnt/nas` | `{{ plex_nas_server }}:{{ plex_nas_path }}` | NFS 4.2 |
| `/mnt/cifs` | `//{{ plex_smb_server }}{{ plex_smb_path }}/` | SMB 3.1.1 |
| `/mnt/truenas` | `{{ plex_truenas_server }}:{{ plex_truenas_path }}` | NFS 4.2 |

## Requirements

- The play uses `become: true`.

## Variables

| Variable | Where | Description |
| --- | --- | --- |
| `plex_nas_server`, `plex_nas_path` | `inventory/media.yml`: `linds-truenas-01.linds.com.au`, `/mnt/ZFS_NAS` | The NFS export for `/mnt/nas`. |
| `plex_smb_server`, `plex_smb_path` | `inventory/media.yml`: `linds-dc.linds.com.au`, `/nas/holiday videos` | The SMB share for `/mnt/cifs`. |
| `plex_truenas_server`, `plex_truenas_path` | `inventory/media.yml`: `jd-truenas-01.linds.com.au`, `/mnt/NAS` | The NFS export for `/mnt/truenas` (the storage address of `jd-proxmox-02`). |
| `smb_username`, `smb_password`, `smb_domain` | `vars/plex.yml` (vault) | The account for `/mnt/cifs`: `svc-plex-smb`, a domain account that can only read the NAS and only log on over the network. Its password is also in `windows_directory_initial_passwords`. |
| `plex_mount_idle_timeout` | `defaults/main.yml` | The time without use, in seconds, after which systemd unmounts a share: `60`. |
| `plex_mount_options` | `defaults/main.yml` | The options that make each mount an automount. |
| `plex_smb_credentials_file` | `defaults/main.yml` | The file with the SMB account: `/etc/plex-smb.credentials`. |
| `plex_mounts` | `defaults/main.yml` | The three mounts: path, source, type and options. |

## How to use it

`playbooks/media.yml` applies `common` and then this role to the group
`plex`. See [playbooks/media.md](../../playbooks/media.md).

To see the state of the mounts on the host:

```
systemctl list-units 'mnt-*'
findmnt -t nfs4,cifs
```

## Safety

**NOTE:** On a host that has autofs, the role stops Plex Media Server while it
moves the mounts (less than one minute). If Plex scans a library while a
folder under `/mnt/` is empty, it can remove the library items.

**NOTE:** If a share cannot be mounted, a program that opens its path gets an
error. It does not see an empty folder.
