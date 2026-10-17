# truenas

The `truenas` role configures the TrueNAS at LINDS through its middleware
(`arensb.truenas` and `midclt`).

## What it does

1. Sets the host name to `truenas_hostname`.
2. Makes each NFS share in `truenas_nfs_shares`, with its networks and its
   root mapping.
3. If `truenas_syslog_server` is set, sends syslog to that server.

## What it does not do

It does not make snapshot tasks. The pool `NAS` on `linds-truenas-01` is the
target of the nightly pull from `jd-proxmox-02` (replication task 2). Local
snapshots on a replication target stop the next incremental pull.

## Requirements

- The collection `arensb.truenas`: `make update-requirements`.
- SSH as `root` (the inventory sets `ansible_user: root`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `truenas_hostname` | `""` | The host name. Empty: no change. |
| `truenas_nfs_shares` | `[]` | `{path, networks, maproot_user, maproot_group}` for each share. |
| `truenas_syslog_server` | `""` | `host:port` of a syslog server. Empty: no change. |
| `truenas_syslog_transport` | `UDP` | The syslog transport. |

`inventory/truenas.yml` sets the values for `linds-truenas-01`.

## How to use it

`playbooks/truenas.yml`. See [playbooks/truenas.md](../../playbooks/truenas.md).

## Known problems

- The JD host `jd-truenas-01` is not a TrueNAS any more. The name points at
  the storage address of `jd-proxmox-02`, which exports `/mnt/NAS` and
  `/mnt/HDD` itself. The inventory does not list it.
