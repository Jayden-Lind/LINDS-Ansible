# truenas.yml

The playbook configures the TrueNAS at LINDS: the host name, the NFS share and
syslog. It applies the role `truenas`.

## Before you start

- Run the commands from the repository root.
- Install the collection `arensb.truenas`: `make update-requirements`.
- You can connect to `10.3.1.50` as `root` with SSH.

## Procedure

1. Run `ansible-playbook playbooks/truenas.yml --check --diff`.
2. Run `ansible-playbook playbooks/truenas.yml`.

## What it changes

- The group `truenas`: `linds-truenas-01.linds.com.au` (`10.3.1.50`).
- See [roles/truenas/README.md](../roles/truenas/README.md).
