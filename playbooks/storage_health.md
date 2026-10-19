# storage_health.yml

The `storage_health.yml` playbook applies the role `storage_health` to the
Proxmox hosts at both sites. It schedules disk patrols and exports storage
health metrics for Prometheus.

## Before you start

- Read [roles/storage_health/README.md](../roles/storage_health/README.md).
- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.

## Procedure

**NOTE:** Merging to `main` applies this playbook to both hosts. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/storage_health.yml --check --diff` to see
   the changes.
2. Run `ansible-playbook playbooks/storage_health.yml`.
3. To apply one part, add `--tags exporter`, `selftests`, `scrub` or `raid`.

**NOTE:** Unlike `proxmox.yml`, this playbook is safe to run in full, on both
hosts. It touches nothing that serves storage.

## What it changes

- The group `storage_health` in `inventory/storage_health.yml`:
  `jd-proxmox-01.linds.com.au` (`jd-proxmox-02`) and `linds-proxmox-01`
  (`192.168.6.205`). Ansible connects as `root`.
- It installs node_exporter and a script. It restarts `smartd` and
  node_exporter when their configuration changes.

## If it fails

- See "Running it" in the role README.
