# nas.yml

The playbook configures the TrueNAS at LINDS: the host name, the NFS share and
syslog. It applies the role `truenas`.

## Before you start

- Run the commands from the repository root.
- Install the collection `arensb.truenas`:
  `ansible-galaxy install -r requirements.yml`.
- You can connect to `10.3.1.50` as `root` with SSH.

## Procedure

**NOTE:** Merging to `main` applies this playbook to the TrueNAS. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/nas.yml --check --diff`.
2. Run `ansible-playbook playbooks/nas.yml`.

## What it changes

- The group `truenas` in `inventory/nas.yml`: `linds-truenas-01.linds.com.au`
  (`10.3.1.50`).
- See [roles/truenas/README.md](../roles/truenas/README.md).
