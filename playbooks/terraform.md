# terraform.yml

The `terraform.yml` playbook sets up the Terraform host. It applies the roles
`common` and `terraform`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

1. Run `ansible-playbook playbooks/terraform.yml`.

## What it changes

- The group `terraform` in `inventory/terraform.yml`:
  `jd-terraform-01.linds.com.au`.
- For the settings, see [roles/common/README.md](../roles/common/README.md)
  and [roles/terraform/README.md](../roles/terraform/README.md).

## If it fails

- `object of type 'dict' has no attribute 'packages'`: the role uses the
  reserved name `vars`. See "Known problems" in the terraform role README.
