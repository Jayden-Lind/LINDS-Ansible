# proxmox

The `proxmox` role configures the storage services on `jd-proxmox-02`: ZFS,
NFS, iSCSI, sanoid snapshots, LXC containers and fan control.

## What it does

1. Installs `nfs-kernel-server`, `open-iscsi`, `targetcli-fb` and `sanoid`.
   It loads the iSCSI target kernel modules.
2. Writes the ZFS module parameters to `/etc/modprobe.d/zfs.conf` and updates
   the initramfs. It also writes the runtime-writable parameters to
   `/sys/module/zfs/parameters/`.
3. Installs `/etc/udev/rules.d/61-drive-write-cache.rules`, which turns on
   the write cache of the SATA drives.
4. Sets the ZFS properties in `proxmox_zfs_datasets`.
5. Writes `/etc/exports` from `proxmox_nfs_exports`, runs `exportfs -ra` and
   starts `nfs-server`.
6. Writes `/etc/rtslib-fb-target/saveconfig.json` from
   `proxmox_iscsi_targets` and runs `targetctl restore`. It also makes the
   restore at boot wait for the zvol devices.
7. Writes `/etc/sanoid/sanoid.conf`, installs
   `/usr/local/sbin/sanoid-snapshot-gate` and starts `sanoid.timer`. It sets
   `au.com.linds:sanoid=off` on each dataset in `proxmox_sanoid_optout`.
8. Makes each container in `proxmox_lxc_containers` that does not exist
   (`pct create`). It sets the entry point, bind mounts and environment, and
   starts the container.
9. Installs `/usr/local/sbin/fan-control.sh` and starts
   `fan-control.service`. The script is for a Lenovo ThinkSystem SR655. It
   sets the fan speed through the BMC with `ipmitool`.

## Requirements

- Install the collections: `make update-requirements`.
- The OCI template of each LXC container is in `/var/lib/vz/template/cache/`.
  Stage it with `pveam download local <name>`.
- `vault_minio_root_user` and `vault_minio_root_password` are defined. See
  "Known problems".

## Variables

The defaults are in `defaults/main.yml`. Set the lists in
`inventory/proxmox.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `proxmox_zfs_datasets` | `[]` | The datasets and the ZFS properties to set on them. |
| `proxmox_zfs_module_params` | ARC 16 to 64 GiB, queue depths, dirty data, TRIM floor | The ZFS module parameters, in groups with a comment. |
| `proxmox_nfs_exports` | `[]` | The NFS exports: `path`, `options` and `networks`. |
| `proxmox_iscsi_targets` | `[]` | The iSCSI targets and LUNs for `saveconfig.json`. |
| `proxmox_sanoid_policies` | `[]` | The datasets that sanoid snapshots, and the template for each. |
| `proxmox_sanoid_templates` | `ssd_short`: 14 daily snapshots | The sanoid retention templates. |
| `proxmox_sanoid_optout` | `[]` | The datasets that sanoid must not snapshot. |
| `proxmox_lxc_containers` | `[]` | The LXC containers to make and start. |
| `proxmox_packages` | Four packages | The packages to install. |
| `proxmox_iscsi_kmods` | `target_core_mod`, `iscsi_target_mod` | The kernel modules to load. |
| `proxmox_exports_file` | `/etc/exports` | The NFS exports file. |
| `proxmox_iscsi_saveconfig` | `/etc/rtslib-fb-target/saveconfig.json` | The iSCSI target configuration file. |
| `proxmox_sanoid_conf_dir` | `/etc/sanoid` | The sanoid configuration directory. |

## How to use it

`playbooks/proxmox.yml` applies this role to the group `proxmox`, as `root`.
The group has one host, `jd-proxmox-01.linds.com.au` (`10.0.50.246`). This
is `jd-proxmox-02`, under its old name. See
[playbooks/proxmox.md](../../playbooks/proxmox.md) for the procedure.

## Safety

**WARNING:** Do not run the full role against `jd-proxmox-02`. Skip the
iSCSI tasks.

The iSCSI tasks replace `/etc/rtslib-fb-target/saveconfig.json` with only the
targets in `proxmox_iscsi_targets`. The Kubernetes storage driver,
democratic-csi, keeps its iSCSI targets in the same file. The handler then
runs `targetctl restore`, which removes every target that is not in the file.
The Kubernetes volumes on this host then lose their disks. If the run stops
before the handler, the host loses the targets at the next boot. At boot,
`rtslib-fb-targetctl` restores the file.

**CAUTION:** The role writes all of `/etc/exports` from `proxmox_nfs_exports`.
It removes an export that is not in the list.

**CAUTION:** If a dataset in `proxmox_zfs_datasets` does not exist, the role
makes it.

**CAUTION:** If the `env` of an LXC container changes, the role stops and
starts the container.

## Known problems

- `inventory/proxmox.yml` uses `vault_minio_root_user` and
  `vault_minio_root_password`, but no file in this repository defines them.
  The first LXC task fails. The fan control tasks and the handlers do not run.
- The tasks have no tags. You cannot select or skip a part with `--tags` or
  `--skip-tags`. Use `--start-at-task` or `--step`.
