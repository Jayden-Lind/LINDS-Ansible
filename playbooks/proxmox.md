# proxmox.yml

The playbook applies the role `proxmox` to `jd-proxmox-02`.

## Before you start

- Read [roles/proxmox/README.md](../roles/proxmox/README.md).
- You can connect to `10.0.50.246` as `root` with SSH.
- The host runs the Talos VMs and their storage. Do not apply changes during
  a cluster upgrade.

## Procedure

**NOTE:** Merging to `main` applies this playbook to `jd-proxmox-02`. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/proxmox.yml --check --diff` to see the
   changes.
2. Apply all parts: `ansible-playbook playbooks/proxmox.yml`.
3. Or apply one part: `ansible-playbook playbooks/proxmox.yml --tags fan-control`.

## What it changes

- The host `jd-proxmox-01.linds.com.au` (`10.0.50.246`) in
  `inventory/proxmox.yml`. This is `jd-proxmox-02` under its old name.
- See the role README for the parts.
