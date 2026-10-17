# proxmox

The `proxmox` role configures the storage services on `jd-proxmox-02`: ZFS,
the NFS server, the iSCSI target service, sanoid snapshots, LXC containers and
fan control.

## What it does

Each part has a tag.

| Tag | What it does |
| --- | --- |
| `packages` | Installs `nfs-kernel-server`, `open-iscsi`, `targetcli-fb` and `sanoid`, and loads the iSCSI target kernel modules. |
| `zfs` | Writes the ZFS module parameters to `/etc/modprobe.d/zfs.conf`, updates the initramfs, and sets the runtime parameters. Sets the ZFS properties in `proxmox_zfs_datasets`. |
| `drive-cache` | Installs a udev rule that turns on the write cache of the SATA drives. |
| `nfs` | Keeps `nfs-server` enabled and running. |
| `iscsi` | Makes the restore of the iSCSI targets at boot wait for the zvol devices, and keeps `rtslib-fb-targetctl` enabled. |
| `sanoid` | Writes `/etc/sanoid/sanoid.conf`, installs the snapshot gate and starts `sanoid.timer`. Sets `au.com.linds:sanoid=off` on each dataset in `proxmox_sanoid_optout`. |
| `lxc` | Makes and starts the containers in `proxmox_lxc_containers`. The list is empty: LINDS-Terraform owns the containers. |
| `fan-control` | Installs `fan-control.sh` and starts `fan-control.service` (Lenovo SR655, through the BMC). |

## What it does not do

- It does not write `/etc/exports`. LINDS-Terraform (`proxmox/nfs.tf`) writes
  it.
- It does not write `/etc/rtslib-fb-target/saveconfig.json`. democratic-csi
  (the Kubernetes storage driver) makes the iSCSI targets and saves that file.
- It does not make LXC containers. LINDS-Terraform (`bootstrap/`) owns them.

## Requirements

- SSH as `root` to the host.

## Variables

The defaults are in `defaults/main.yml`. Set the lists in
`inventory/proxmox.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `proxmox_zfs_datasets` | `[]` | The datasets and their ZFS properties. Give sizes in bytes (`"1048576"`): the module compares the number. |
| `proxmox_zfs_module_params` | ARC 16 to 64 GiB, queue depths, dirty data, TRIM floor | The ZFS module parameters, in groups with a comment. |
| `proxmox_sanoid_policies` | `[]` | The datasets that sanoid snapshots, and the template for each. |
| `proxmox_sanoid_templates` | `ssd_short`: 14 daily snapshots | The sanoid retention templates. |
| `proxmox_sanoid_optout` | `[]` | The datasets that sanoid must not snapshot. |
| `proxmox_lxc_containers` | `[]` | The LXC containers to make and start. |
| `proxmox_packages` | Four packages | The packages to install. |
| `proxmox_iscsi_kmods` | `target_core_mod`, `iscsi_target_mod` | The kernel modules to load. |
| `proxmox_iscsi_saveconfig` | `/etc/rtslib-fb-target/saveconfig.json` | The iSCSI target configuration that democratic-csi saves. |

## How to use it

`playbooks/proxmox.yml` applies this role to the group `proxmox`. See
[playbooks/proxmox.md](../../playbooks/proxmox.md).

## Safety

**CAUTION:** If a dataset in `proxmox_zfs_datasets` does not exist, the role
makes it.

**CAUTION:** A change to the ZFS module parameters takes effect at the next
boot.

## Known problems

- The host is `jd-proxmox-02`, but the inventory still calls it
  `jd-proxmox-01.linds.com.au`.
