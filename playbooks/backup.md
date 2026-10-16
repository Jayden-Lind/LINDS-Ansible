# backup.yml

The `backup.yml` playbook sets up the backup host. It applies the roles
`common` and `backup`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/backup.yml`.

## What it changes

- The group `backup` in `inventory/backup.yml`: `jd-backup-01.linds.com.au`.
  Ansible connects as `root`.
- For the settings, see [roles/common/README.md](../roles/common/README.md)
  and [roles/backup/README.md](../roles/backup/README.md).

## If it fails

- Read "Known problems" in the two role READMEs.
