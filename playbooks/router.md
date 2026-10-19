# router.yml

The `router.yml` playbook applies the role `router` to the Debian routers,
`jd-router-01` and `linds-router-01`. One role serves both sites.

## Before you start

- Read [roles/router/README.md](../roles/router/README.md) first. It has the
  layout, the run options and the hazards.
- `router_site` in `inventory/group_vars/jd_router.yml` and
  `inventory/group_vars/linds_router.yml` selects the site files:
  `roles/router/files/jd/` or `roles/router/files/linds/`.
- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.

## Procedure

**NOTE:** Merging to `main` applies this playbook to `jd-router-01`. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

**WARNING:** Always name one router with `--limit`. Without it, the play
changes both routers, one after the other.

1. See the changes:

   ```sh
   ansible-playbook playbooks/router.yml --limit jd-router-01 --check --diff
   ```

2. Apply the changes:

   ```sh
   ansible-playbook playbooks/router.yml --limit jd-router-01
   ```

For LINDS, use `--limit linds-router-01`.

## What it changes

- The group `router` in `inventory/router.yml`: `jd-router-01` (`10.0.50.1`,
  group `jd_router`) and `linds-router-01` (`10.3.1.250`, group
  `linds_router`). Ansible connects as `jayden` and uses `become`.
- The play has `serial: 1` and `force_handlers: true`. A failed run still
  restarts the daemons whose configuration changed.
- For each area and its tag, see the role README.

## If it fails

- If the first router fails, the play stops before the second router.
- The run ends with the checks in `roles/router/tasks/validate.yml`. See
  "Running it" in the role README.
