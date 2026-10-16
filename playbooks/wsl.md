# wsl.yml

The playbook sets up the WSL workstation of the operator. It applies the role
`wsl` to `localhost`.

## Before you start

- Run the playbook on the WSL host, from the repository root.
- Install the collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/wsl.yml --check --diff`.
2. Run `ansible-playbook playbooks/wsl.yml`.

## What it changes

- The WSL host only. See [roles/wsl/README.md](../roles/wsl/README.md).
