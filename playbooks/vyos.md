# vyos.yml

The `vyos.yml` playbook applies the role `vyos` to the VyOS routers. Only
`linds-vyos-01` (`192.168.6.1`) is a VyOS router in this inventory.

## Before you start

- Read [roles/vyos/README.md](../roles/vyos/README.md).
- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the collection `vyos.vyos`: `make update-requirements`.
- `inventory/group_vars/linds_vyos.yml` says that its values are not checked
  against the running configuration. Read each change in check mode.

## Procedure

**CAUTION:** Always use `--limit linds_vyos`. The group `jd_vyos` points at
`10.0.50.1`, which is `jd-router-01` in `inventory/router.yml`. That host is
a Debian router, not VyOS.

1. Run `ansible-playbook playbooks/vyos.yml --limit linds_vyos --check --diff`
   to see the changes.
2. Run `ansible-playbook playbooks/vyos.yml --limit linds_vyos`.

**NOTE:** The role README shows `--limit jd_vyos`. That example is out of
date.

## What it changes

- The group `linds_vyos` in `inventory/vyos.yml`: `192.168.6.1`. Ansible
  connects with `network_cli` as `vyos`. The password is stored in the vault.
- `module_defaults` sets `save: true`, so each change is saved to the boot
  configuration.

## If it fails

- A task times out: a commit that touches an interface can take a long
  time. The inventory allows 180 seconds (`ansible_command_timeout`).
- For other failures, see "Conventions and sharp edges" in the role README.
