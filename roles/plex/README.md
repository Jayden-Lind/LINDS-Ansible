# plex

The `plex` role installs Plex Media Server. On the LINDS host it also mounts
the media shares with autofs.

## What it does

1. Loads `vars/plex.yml` (the SMB user and password, in the vault) into the
   variable `plex`.
2. On a Debian-family host: installs `curl`, `gnupg2` and `cifs-utils`, adds
   the Plex signing key and apt repository, and installs and starts
   `plexmediaserver`.
3. On a RedHat-family host: sets the crypto policy to `plex_crypto_policy` if
   it is different, installs `nfs-utils` and `cifs-utils`, adds the Plex yum
   repository, and installs and starts `plexmediaserver`.
4. On a host in the group `linds`, adds an autofs map (`robertdebock.autofs`)
   with three mounts under `/mnt/`:

| Mount | Source | Type |
| --- | --- | --- |
| `/mnt/nas` | `{{ server }}:{{ path }}` | NFS 4.2 |
| `/mnt/cifs` | `//{{ smb_server }}{{ smb_path }}/` | SMB 3.1.1 |
| `/mnt/truenas` | `{{ truenas_host }}:{{ truenas_path }}` | NFS 4.2 |

## Requirements

- Install the Galaxy roles: `make update-requirements`.
- The play uses `become: true`.

## Variables

| Variable | Where | Description |
| --- | --- | --- |
| `plex_crypto_policy` | `defaults/main.yml`: `LEGACY` | The crypto policy on a RedHat-family host. |
| `server`, `path` | `inventory/plex.yml`: `linds-truenas-01.linds.com.au`, `/mnt/ZFS_NAS` | The NFS export for `/mnt/nas`. |
| `smb_server`, `smb_path` | `inventory/plex.yml`: `linds-dc.linds.com.au`, `/nas/holiday videos` | The SMB share for `/mnt/cifs`. |
| `smb_username`, `smb_password`, `smb_domain` | `vars/plex.yml` (vault) | The account for `/mnt/cifs`: `svc-plex-smb`, a domain account that can only read the NAS and only log on over the network. Its password is also in `windows_directory_initial_passwords`. |
| `truenas_host`, `truenas_path` | `inventory/plex.yml`: `jd-truenas-01.linds.com.au`, `/mnt/NAS` | The NFS export for `/mnt/truenas` (the storage address of `jd-proxmox-02`). |

## How to use it

`playbooks/plex.yml` applies `common` and then this role. See
[playbooks/plex.md](../../playbooks/plex.md).

## Safety

**CAUTION:** On a RedHat-family host, `LEGACY` allows old, weak algorithms
for the whole host. The reason for it is not known. The current host is
Ubuntu, so the setting does not apply to it.
