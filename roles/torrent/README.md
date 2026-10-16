# torrent

The `torrent` role installs qBittorrent (`qbittorrent-nox`), writes its
configuration, mounts the NAS over NFS and tunes the kernel for torrent
traffic.

## What it does

1. Installs the packages in `torrent_packages_debian` or
   `torrent_packages_redhat`.
2. Makes `torrent_config_dir`.
3. If the qBittorrent configuration changed, stops the service and writes
   the file. Hosts in `jd_torrent` get `files/qBittorrent.conf`. Hosts in
   `linds_torrent` get `files/qBittorrent_linds.conf`. Both files are stored
   in the vault.
4. Mounts the NAS at `/mnt/nas`:
   - `jd_torrent`: `jd-truenas-01.linds.com.au:/mnt/HDD`, NFS 4 with
     `nconnect=4` and `soft`.
   - `linds_torrent`: `{{ nfs_server }}:{{ nfs_path }}`, NFS 4.2 with `soft`.
5. Writes `torrent_sysctl_settings` to `torrent_sysctl_file` and applies them.
6. Sets the NFS client RPC slot count in `/etc/modprobe.d/sunrpc.conf`. If
   the `sunrpc` module is loaded, it also sets the running value.
7. Stops the old `qbittorrent` unit and the slice
   `system-qbittorrent\x2dnox.slice`. Then it enables and starts
   `torrent_service_name`.

## Requirements

- The host is Debian family or RedHat family.
- The `vault_password` file must be in the repository root.

## Variables

The defaults are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `torrent_packages_debian` | `qbittorrent-nox`, `cifs-utils`, `nfs-common` | The packages for Debian-family hosts. |
| `torrent_packages_redhat` | `qbittorrent`, `qbittorrent-nox`, `cifs-utils`, `nfs-utils` | The packages for RedHat-family hosts. |
| `torrent_service_name` | `qbittorrent-nox@root.service` | The qBittorrent service. |
| `torrent_config_dir` | `/root/.config/qBittorrent` | The directory for `qBittorrent.conf`. |
| `torrent_sysctl_file` | `/etc/sysctl.d/99-torrent.conf` | The sysctl file. |
| `torrent_sysctl_settings` | See `defaults/main.yml` | The network buffer, TCP and dirty-page settings. |
| `torrent_sunrpc_modprobe_file` | `/etc/modprobe.d/sunrpc.conf` | The file for the RPC slot setting. |
| `torrent_sunrpc_slot_table_entries` | `"64"` | The first NFS RPC slot count. The kernel default is 2. |

`inventory/torrent.yml` sets `nfs_server` (`linds-truenas-01.linds.com.au`)
and `nfs_path` (`/mnt/ZFS_NAS`) for `linds_torrent`.

## How to use it

`playbooks/torrent.yml` applies `common` and then this role to the group
`torrent`. See [playbooks/torrent.md](../../playbooks/torrent.md).

## Safety

**NOTE:** qBittorrent writes its configuration file when it stops. The role
stops the service before it writes the file, so the service cannot overwrite
the new file.

## Known problems

- `tasks/service.yml` stops `system-qbittorrent\x2dnox.slice`. This slice
  holds `qbittorrent-nox@root.service`, so each run stops and starts
  qBittorrent.
- On `jd_torrent`, the role mounts the share only when the `/etc/fstab` line
  changes. If the share is not mounted, run `mount /mnt/nas` on the host.
- `tasks/jd.yml` loads `vars/torrent.yml` (an SMB user name and password,
  stored in the vault). No task uses them.
