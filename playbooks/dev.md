# dev.yml

The `dev.yml` playbook applies the role `common` to the development host.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/dev.yml`.

## What it changes

- The group `dev` in `inventory/dev.yml`: `jd-dev-01.linds.com.au`. Ansible
  connects as `root`.
- For the settings, see [roles/common/README.md](../roles/common/README.md).

## If it fails

- Read "Known problems" in the role README.
