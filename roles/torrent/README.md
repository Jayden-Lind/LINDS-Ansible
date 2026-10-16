# torrent

The `torrent` role installs qBittorrent (`qbittorrent-nox`), writes its
configuration, mounts the NAS over NFS and tunes the kernel for torrent
traffic.

## What it does

1. Installs the packages in `torrent_packages_debian` or
   `torrent_packages_redhat`.
2. Makes `torrent_config_dir`.
3. Compares the qBittorrent configuration with the file in the role (content
   only). If it is different, it stops the service and writes the file. Hosts
   in `jd_torrent` get `files/qBittorrent.conf`; hosts in `linds_torrent` get
   `files/qBittorrent_linds.conf`. Both files are in the vault.
4. Mounts the NAS at `/mnt/nas` and keeps it in `/etc/fstab`:
   - `jd_torrent`: `jd-truenas-01.linds.com.au:/mnt/HDD` (the storage address
     of `jd-proxmox-02`), NFS 4 with `nconnect=4` and `soft`.
   - `linds_torrent`: `{{ nfs_server }}:{{ nfs_path }}`, NFS 4.2 with `soft`.
5. Writes `torrent_sysctl_settings` to `torrent_sysctl_file` and applies them.
6. Sets the NFS client RPC slot count in `/etc/modprobe.d/sunrpc.conf`. If the
   `sunrpc` module is loaded, it also sets the running value.
7. Stops and disables the old unit `qbittorrent.service` if it exists. Then
   it enables and starts `torrent_service_name`. It does not restart a
   running service.

## Requirements

- The play uses `become: true`.
- The `vault_password` file is in the repository root.

## Variables

The defaults are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `torrent_packages_debian` | `qbittorrent-nox`, `cifs-utils`, `nfs-common` | The packages for Debian-family hosts. |
| `torrent_packages_redhat` | `qbittorrent`, `qbittorrent-nox`, `cifs-utils`, `nfs-utils` | The packages for RedHat-family hosts. |
| `torrent_service_name` | `qbittorrent-nox@root.service` | The qBittorrent service. |
| `torrent_config_dir` | `/root/.config/qBittorrent` | The directory of `qBittorrent.conf`. |
| `torrent_sysctl_file` | `/etc/sysctl.d/99-torrent.conf` | The sysctl file. |
| `torrent_sysctl_settings` | see `defaults/main.yml` | The network buffer, TCP and dirty-page settings. |
| `torrent_sunrpc_modprobe_file` | `/etc/modprobe.d/sunrpc.conf` | The file for the RPC slot setting. |
| `torrent_sunrpc_slot_table_entries` | `"64"` | The first NFS RPC slot count. The kernel default is 2. |

`inventory/torrent.yml` sets `nfs_server` and `nfs_path` for `linds_torrent`.

## How to use it

`playbooks/torrent.yml` applies `common` and then this role to the group
`torrent`. See [playbooks/torrent.md](../../playbooks/torrent.md).

## Safety

**CAUTION:** A setting that you change in the qBittorrent web UI is only in
the file on the host. The next run writes the file in the role over it. Copy
the file from the host to the role first:

```shell
ansible <host> -b -m fetch -a "src=/root/.config/qBittorrent/qBittorrent.conf dest=/dev/shm/q.conf flat=yes"
ansible-vault encrypt --output roles/torrent/files/<file> /dev/shm/q.conf && rm /dev/shm/q.conf
```

**NOTE:** qBittorrent writes its configuration file when it stops. The role
stops the service before it writes the file, so that the service cannot write
the old settings over the new file.
