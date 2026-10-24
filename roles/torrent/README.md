# torrent

The `torrent` role installs qBittorrent (`qbittorrent-nox`), writes its
configuration, mounts the NAS over NFS and tunes the kernel for torrent
traffic.

## What it does

1. Installs the packages in `torrent_packages_debian` or
   `torrent_packages_redhat`.
2. If `torrent_user` is not `root`: makes that system account, with its home
   in `torrent_home`. The first time, it stops `qbittorrent-nox@root`, copies
   root's profile (`~/.config/qBittorrent`, `~/.local/share/qBittorrent`,
   which holds the resume data of every torrent) to the new home and gives it
   to the account. The copy in `/root` stays.
3. Makes `torrent_config_dir`.
4. Compares the qBittorrent configuration with the file in the role (content
   only), and `categories.json` with `torrent_categories` if that is set. If
   either is different, it stops the service and writes the file. Hosts in
   `jd_torrent` get `files/qBittorrent.conf`; hosts in `linds_torrent` get
   `files/qBittorrent_linds.conf`. Both files are in the vault.
5. Mounts the NAS at `/mnt/nas` and keeps it in `/etc/fstab`:
   - `jd_torrent`: `jd-truenas-01.linds.com.au:/mnt/HDD` (the storage address
     of `jd-proxmox-02`), NFS 4 with `nconnect=4` and `soft`.
   - `linds_torrent`: `{{ nfs_server }}:{{ nfs_path }}`, NFS 4.2 with `soft`.
6. Writes `torrent_sysctl_settings` to `torrent_sysctl_file` and applies them.
7. Sets the NFS client RPC slot count in `/etc/modprobe.d/sunrpc.conf`. If the
   `sunrpc` module is loaded, it also sets the running value.
8. Stops and disables the old unit `qbittorrent.service` if it exists, and
   `qbittorrent-nox@root.service` if `torrent_user` is not `root`. Then it
   enables and starts `torrent_service_name`. It does not restart a running
   service.

## Requirements

- The play uses `become: true`.
- The `vault_password` file is in the repository root.

## Variables

The defaults are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `torrent_packages_debian` | `qbittorrent-nox`, `cifs-utils`, `nfs-common` | The packages for Debian-family hosts. |
| `torrent_packages_redhat` | `qbittorrent`, `qbittorrent-nox`, `cifs-utils`, `nfs-utils` | The packages for RedHat-family hosts. |
| `torrent_user` | `root` | The account qBittorrent runs as. `linds_torrent`: `qbittorrent`. |
| `torrent_home` | `/root`, or `/var/lib/<torrent_user>` | The account's home, which holds the profile. |
| `torrent_service_name` | `qbittorrent-nox@<torrent_user>.service` | The qBittorrent service. |
| `torrent_config_dir` | `<torrent_home>/.config/qBittorrent` | The directory of `qBittorrent.conf` and `categories.json`. |
| `torrent_categories` | `{}` | `{name: {save_path}}` for `categories.json`. Empty: the file is not changed. |
| `torrent_sysctl_file` | `/etc/sysctl.d/99-torrent.conf` | The sysctl file. |
| `torrent_sysctl_settings` | see `defaults/main.yml` | The network buffer, TCP and dirty-page settings. |
| `torrent_sunrpc_modprobe_file` | `/etc/modprobe.d/sunrpc.conf` | The file for the RPC slot setting. |
| `torrent_sunrpc_slot_table_entries` | `"64"` | The first NFS RPC slot count. The kernel default is 2. |

`inventory/torrent.yml` sets `nfs_server`, `nfs_path`, `torrent_user` and
`torrent_categories` for `linds_torrent`. Its downloads go to
`/mnt/nas/downloads/<category>`, which no Plex library contains. Radarr and
Sonarr hardlink them into the libraries (LINDS-Kubernetes mounts the same
share at `/mnt/nas`).

## How to use it

`playbooks/torrent.yml` applies `common` and then this role to the group
`torrent`. See [playbooks/torrent.md](../../playbooks/torrent.md).

## Safety

**CAUTION:** A setting that you change in the qBittorrent web UI is only in
the file on the host. The next run writes the file in the role over it. Copy
the file from the host to the role first:

```shell
ansible <host> -b -m fetch -a "src=<torrent_config_dir>/qBittorrent.conf dest=/dev/shm/q.conf flat=yes"
ansible-vault encrypt --output roles/torrent/files/<file> /dev/shm/q.conf && rm /dev/shm/q.conf
```

**NOTE:** qBittorrent writes its configuration file when it stops. The role
stops the service before it writes the file, so that the service cannot write
the old settings over the new file.

**CAUTION:** A change to the `save_path` of a category moves the data of
every torrent in that category that uses automatic torrent management. The
move starts when qBittorrent starts again. The setting "when the category
save path changes, switch torrents to manual mode" does not apply, because
the role changes the file while qBittorrent is stopped. If the old folder is
a library, the files go out of the library. On 2026-10-25 a change moved 442
torrents out of `Movies` and `TVShows`. The files were linked back in at their
old paths.
