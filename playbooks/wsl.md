# wsl.yml

The `wsl.yml` playbook sets up the local WSL workstation. It applies the role
`wsl` to `localhost`.

## Before you start

- Run the playbook on the WSL host, from the repository root. `ansible.cfg`
  reads the inventory and the `vault_password` file from there.
- Install the collections: `make update-requirements`.
- Set up the HashiCorp apt repository. The role does not add it.

## Procedure

1. Run `ansible-playbook playbooks/wsl.yml`.

## What it changes

- The group `wsl` in `inventory/wsl.yml`: `localhost`, with
  `connection: local`.
- The play uses `become`. The sudo password is stored in the vault, in
  `playbooks/wsl.yml`.
- For the settings, see [roles/wsl/README.md](../roles/wsl/README.md).

## If it fails

- `Install Ansible reqs` fails: `vars.root_dir` is not defined. See "Known
  problems" in the role README.
