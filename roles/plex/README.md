# plex

The `plex` role installs Plex Media Server and mounts the media shares with
autofs. It is for Debian and Ubuntu hosts.

## What it does

1. Loads `vars/plex.yml` (the SMB user and password, in the vault) into the
   variable `plex`.
2. Installs `curl`, `gnupg2` and `cifs-utils`, adds the Plex signing key and
   the Plex repository (`/etc/apt/sources.list.d/plex.sources`), and installs
   and starts `plexmediaserver`.
3. Installs autofs and writes one map with three mounts under `/mnt/`:

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
| `plex_autofs_map` | `defaults/main.yml` | The name of the map in its two file names, `/etc/auto.master.d/00-<map>.autofs` and `/etc/auto.<map>`. |
| `plex_autofs_options`, `plex_mounts` | `defaults/main.yml` | The autofs options and the three mounts. |

## How to use it

`playbooks/media.yml` applies `common` and then this role to the group
`plex`. See [playbooks/media.md](../../playbooks/media.md).
