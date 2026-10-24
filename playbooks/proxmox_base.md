# proxmox_base.yml

The playbook applies the role `proxmox_base` to both Proxmox hosts,
`jd-proxmox-02` and `linds-proxmox-01`.

## Before you start

- Read [roles/proxmox_base/README.md](../roles/proxmox_base/README.md).
- You can connect to `10.0.50.246` and `192.168.6.205` as `root` with SSH.

## Procedure

**NOTE:** Merging to `main` applies this playbook to both hosts. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/proxmox_base.yml --check --diff` to see the
   changes.
2. Apply all parts: `ansible-playbook playbooks/proxmox_base.yml`.
3. Or apply one part: `ansible-playbook playbooks/proxmox_base.yml --tags syslog`.

## What it changes

- The hosts in `inventory/proxmox_base.yml`: `jd-proxmox-01.linds.com.au`
  (this is `jd-proxmox-02` under its old name) and `linds-proxmox-01`.
- See the role README for the parts.

## If it fails

- If rsyslog does not restart, run `rsyslogd -N1` on the host. It shows the
  error in the configuration.
