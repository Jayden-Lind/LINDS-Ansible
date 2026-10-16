# terraform

The `terraform` role installs Terraform and Packer on a RedHat-family host,
clones `LINDS-Terraform` and mounts the NAS.

## What it does

1. Loads `vars/main.yml` into the variable `vars`.
2. Adds the HashiCorp yum repository.
3. Installs `packer` and `terraform`.
4. Clones `https://github.com/Jayden-Lind/LINDS-Terraform.git` into
   `/root/LINDS-Terraform`.
5. Adds `export PATH=/usr/bin:$PATH` to `~/.bashrc` of the user that Ansible
   connects as.
6. Mounts `{{ server }}:{{ path }}` at `/mnt/NAS` with autofs (role
   `robertdebock.autofs`).

## Requirements

- The host is RedHat family. The role uses `yum_repository` and `dnf`.
- Install the Galaxy roles: `make update-requirements`.

## Variables

The role has no defaults.

| Variable | Value | Description |
| --- | --- | --- |
| `packages` | `packer`, `terraform` | The packages to install. Set in `vars/main.yml`. |
| `root_dir` | `/root/` | Where the role clones `LINDS-Terraform`. Set in `vars/main.yml`. |
| `server` | `jd-truenas-01.linds.com.au` | The NFS server. Set in `inventory/terraform.yml`. |
| `path` | `/mnt/NAS` | The NFS export. Set in `inventory/terraform.yml`. |

## How to use it

`playbooks/terraform.yml` applies `common` and then this role to the group
`terraform` (`jd-terraform-01.linds.com.au`). See
[playbooks/terraform.md](../../playbooks/terraform.md).

## Safety

**CAUTION:** The packages have `state: latest`. A run can upgrade Terraform
and Packer.

## Known problems

- The role cannot finish. Ansible reserves the name `vars`, so `vars.packages`
  does not read the loaded file. With ansible-core 2.20 and 2.21, the package
  task fails with `object of type 'dict' has no attribute 'packages'`. To
  correct this, give the loaded variables another name, for example
  `terraform_vars`.
- The clone task has `ignore_errors: true`. A failed clone does not stop the
  run.
