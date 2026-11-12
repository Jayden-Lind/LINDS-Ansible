# hypervisor.yml

The playbook configures the Proxmox hosts at both sites, `jd-proxmox-02` and
`linds-proxmox-01`. It is safe to run in full, at any time.

| Role | Hosts | What it does |
| --- | --- | --- |
| [proxmox_base](../roles/proxmox_base/README.md) | Both | Logs to Alloy, unused services off, CPU governor and ring buffers, KSM, kernel settings |
| [storage_health](../roles/storage_health/README.md) | Both | Disk patrols, and storage health metrics for Prometheus |
| [proxmox](../roles/proxmox/README.md) | `jd-proxmox-02` | ZFS, NFS, iSCSI, sanoid and fan control |
| [backblaze](../roles/backblaze/README.md) | `jd-proxmox-02` | The weekly Backblaze run of the NAS, from a ZFS clone of the data disk |

## Before you start

- Run the commands from the repository root.
- You can connect to `10.0.50.246` and `192.168.6.205` as `root` with SSH.
- `jd-proxmox-02` runs the Talos VMs and their storage. Do not apply changes
  during a cluster upgrade.

## Procedure

**NOTE:** Merging to `main` applies this playbook to both hosts. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/hypervisor.yml --check --diff` to see the
   changes.
2. Apply all parts: `ansible-playbook playbooks/hypervisor.yml`.
3. To apply one host, add `--limit jd-proxmox-02` or
   `--limit linds-proxmox-01`.
4. To apply one role, add its name as a tag, for example
   `--tags storage_health`.
5. To apply one part of a role, add the tag of the part, for example
   `--tags syslog` or `--tags fan-control`. The role README lists the tags.

## What it changes

- The hosts in `inventory/hypervisor.yml`. Ansible connects as `root`.
- The settings of each host are in `inventory/host_vars/<host>/<role>.yml`.
- The group `storage_hypervisors` gets the roles `proxmox` and `backblaze`.
  Only `jd-proxmox-02` is in it.
- It restarts rsyslog, `smartd` and node_exporter when their configuration
  changes. The playbook touches no VM. The timer of the role `backblaze`
  starts and stops the Backblaze VM once a week.

## If it fails

- If rsyslog does not restart, run `rsyslogd -N1` on the host. It shows the
  error in the configuration.
- For `storage_health`, see "Running it" in the role README.
