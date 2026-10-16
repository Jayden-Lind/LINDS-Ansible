# truenas.yml

The `truenas.yml` playbook configures the TrueNAS hosts through the TrueNAS
middleware. It applies the role `truenas`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the collection `arensb.truenas`: `make update-requirements`.
- Not known if `jd-truenas-01.linds.com.au` is still a TrueNAS host. Make sure
  before you include `jd_truenas`.

## Procedure

1. Run `ansible-playbook playbooks/truenas.yml --limit linds_truenas`.
2. If `jd-truenas-01.linds.com.au` is a TrueNAS host, run
   `ansible-playbook playbooks/truenas.yml --limit jd_truenas`.

## What it changes

- The group `truenas` in `inventory/truenas.yml`:
  `jd-truenas-01.linds.com.au` (group `jd_truenas`) and
  `linds-truenas-01.linds.com.au` (group `linds_truenas`).
- The play sets `middleware_method: client` in the environment.
- For the settings, see [roles/truenas/README.md](../roles/truenas/README.md).

## If it fails

- Read "Known problems" in the role README.
