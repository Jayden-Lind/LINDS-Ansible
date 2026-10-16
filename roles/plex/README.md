# plex

The `plex` role installs Plex Media Server. On the LINDS host, it also mounts
the media shares with autofs.

## What it does

1. Loads `vars/plex.yml` into the variable `plex`.
2. On RedHat-family hosts, sets the system crypto policy to `LEGACY`. It
   installs `nfs-utils` and `cifs-utils`, adds the Plex yum repository, and
   installs and starts `plexmediaserver`.
3. On Debian-family hosts, installs `curl`, `gnupg2` and `cifs-utils`. It
   adds the Plex signing key and apt repository, and installs and starts
   `plexmediaserver`.
4. On hosts in the group `linds`, adds an autofs map (role
   `robertdebock.autofs`) with three mounts under `/mnt/`:

| Mount | Source | Type |
| --- | --- | --- |
| `/mnt/nas` | `{{ server }}:{{ path }}` | NFS 4.2 |
| `/mnt/cifs` | `//{{ smb_server }}{{ smb_path }}/` | SMB 3.1.1 |
| `/mnt/truenas` | `{{ truenas_host }}:{{ truenas_path }}` | NFS 4.2 |

## Requirements

- Install the Galaxy roles: `make update-requirements`.
- The `vault_password` file must be in the repository root.

## Variables

The role has no defaults. `inventory/plex.yml` sets these values.

| Variable | Value | Description |
| --- | --- | --- |
| `server` | `linds-truenas-01.linds.com.au` | The NFS server for `/mnt/nas`. |
| `path` | `/mnt/ZFS_NAS` | The NFS export for `/mnt/nas`. |
| `smb_server` | `linds-dc.linds.com.au` | The SMB server for `/mnt/cifs`. |
| `smb_path` | `/nas/holiday videos` | The SMB share path for `/mnt/cifs`. |
| `truenas_host` | `jd-truenas-01.linds.com.au` | The NFS server for `/mnt/truenas`. |
| `truenas_path` | `/mnt/NAS` | The NFS export for `/mnt/truenas`. |

`vars/plex.yml` sets `smb_username` and `smb_password` (stored in the vault)
and `smb_domain` (`linds.com.au`).

## How to use it

`playbooks/plex.yml` applies `common` and then this role to the group `plex`
(`linds-plex-01.linds.com.au`). See
[playbooks/plex.md](../../playbooks/plex.md).

## Safety

**CAUTION:** On RedHat-family hosts, the role sets the crypto policy of the
whole host to `LEGACY`. This allows old, weak algorithms. It does this on
every run.

## Known problems

- `inventory/plex.yml` sets `plex_base_dir`, `plex_files_backup` and
  `truenas_plex_path`. No task uses them.
