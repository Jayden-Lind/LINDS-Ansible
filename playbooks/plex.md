# plex.yml

The playbook installs Plex Media Server and mounts the media shares on the
Plex host. It applies the roles `common` and `plex`.

## Before you start

- Run the commands from the repository root.
- Install the Galaxy roles and collections: `make update-requirements`.
- The play uses `become: true`. Your user needs `sudo` without a password on
  the host.

## Procedure

**NOTE:** Merging to `main` applies this playbook to the Plex host. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/plex.yml --check --diff`.
2. Run `ansible-playbook playbooks/plex.yml`.

## What it changes

- The group `plex`: `linds-plex-01.linds.com.au` (`inventory/plex.yml`).
- See [roles/common/README.md](../roles/common/README.md) and
  [roles/plex/README.md](../roles/plex/README.md).
