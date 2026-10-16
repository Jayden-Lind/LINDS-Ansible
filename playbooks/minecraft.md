# minecraft.yml

The `minecraft.yml` playbook prepares the Minecraft host. It applies the
roles `common` and `minecraft`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/minecraft.yml`.

## What it changes

- The group `minecraft` in `inventory/minecraft.yml`: `jd-minecraft-01`.
- For the settings, see [roles/common/README.md](../roles/common/README.md)
  and [roles/minecraft/README.md](../roles/minecraft/README.md).

## If it fails

- Read "Known problems" in the two role READMEs.
