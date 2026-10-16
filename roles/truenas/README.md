# truenas

The `truenas` role configures TrueNAS hosts through the TrueNAS middleware:
the `NAS` dataset, the host name, an NFS share, snapshots, services and
remote syslog.

## What it does

1. Makes the dataset `NAS`.
2. Sets the host name to `hostname`.
3. On `jd_truenas`: shares `/mnt/NAS` over NFS as `NFS_NAS_Kubernetes` to
   `10.0.50.0/24`, `10.0.53.0/24` and `10.3.1.0/24`. Root maps to
   `root:wheel`.
4. On `jd_truenas`: adds a recursive snapshot task for `NAS`. It runs every
   day at 02:00 and keeps each snapshot for 2 weeks.
5. Enables and starts the `ssh` and `nfs` services.
6. If `truenas_syslog_server` is set, makes it the remote syslog server (UDP).
   It uses `midclt`, because the collection has no module for this setting.

## Requirements

- Install the collection `arensb.truenas`: `make update-requirements`.
- The play sets `middleware_method: client` in the environment.

## Variables

The role has no defaults. `inventory/truenas.yml` sets these values.

| Variable | Value | Description |
| --- | --- | --- |
| `hostname` | `jd-truenas-01.linds.com.au` or `linds-truenas-01.linds.com.au` | The host name to set. |
| `truenas_syslog_server` | `172.16.1.23:1514` (`linds_truenas` only) | The Alloy RFC 5424 UDP listener in the Kubernetes cluster. If it is not set, the role does not change syslog. |

## How to use it

`playbooks/truenas.yml` applies this role to the group `truenas`. See
[playbooks/truenas.md](../../playbooks/truenas.md).

## Safety

**CAUTION:** The role replaces the list of remote syslog servers with one
server, `truenas_syslog_server`.

## Known problems

- The snapshot names start with `hourly-`, but the task runs once a day.
- `inventory/proxmox.yml` also exports `/mnt/NAS` over NFS, from
  `jd-proxmox-02`. Not known if `jd-truenas-01.linds.com.au` is still a
  TrueNAS host. Make sure before you run the role on `jd_truenas`.
