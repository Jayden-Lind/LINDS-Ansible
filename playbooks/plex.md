# plex.yml

The `plex.yml` playbook installs Plex Media Server and mounts the media
shares. It applies the roles `common` and `plex`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/plex.yml`.

## What it changes

- The group `plex` in `inventory/plex.yml`. Its only host is
  `linds-plex-01.linds.com.au`, in the group `linds`.
- For the settings, see [roles/common/README.md](../roles/common/README.md)
  and [roles/plex/README.md](../roles/plex/README.md).

## If it fails

- Read "Known problems" in the two role READMEs.
