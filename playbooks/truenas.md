# truenas.yml

The playbook configures the TrueNAS at LINDS: the host name, the NFS share and
syslog. It applies the role `truenas`.

## Before you start

- Run the commands from the repository root.
- Install the collection `arensb.truenas`: `make update-requirements`.
- You can connect to `10.3.1.50` as `root` with SSH.

## Procedure

**NOTE:** Merging to `main` applies this playbook to the TrueNAS. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/truenas.yml --check --diff`.
2. Run `ansible-playbook playbooks/truenas.yml`.

## What it changes

- The group `truenas`: `linds-truenas-01.linds.com.au` (`10.3.1.50`).
- See [roles/truenas/README.md](../roles/truenas/README.md).
