# wsl

The `wsl` role sets up a WSL workstation (Ubuntu) for the user `jayden`:
Git, Ansible, Terraform, Packer, Zsh and Go.

## What it does

1. Updates the apt cache and installs `python3-pip`.
2. Sets the global Git user name and email for `jayden`. Both are stored in
   the vault.
3. Loads `vars/main.yml` into the variable `ansible_vars`.
4. Installs `python3-argcomplete`, `python3-paramiko` and `pipx`. It clones
   `LINDS-Ansible` and installs its Galaxy requirements.
5. Writes the SSH private key (stored in the vault) to
   `/home/jayden/.ssh/id_rsa`.
6. Installs `packer` and `terraform` and clones `LINDS-Terraform`. If no
   `.terraform` directory exists, it runs `terraform init` in each directory
   that has `.tf` files.
7. Copies the `.tfvars` files to `LINDS-Terraform/proxmox/` and the
   `.pkrvars.hcl` files to `LINDS-Terraform/packer/`. All four are stored in
   the vault. Then it runs `packer init -upgrade`.
8. Installs Zsh and makes it the shell of `user`. It installs Oh My Zsh and
   writes `~/.zshrc`.
9. Installs `golang`.

## Requirements

- Run the playbook on the WSL host. The play uses `connection: local` on
  `localhost`.
- The HashiCorp apt repository is set up. The role does not add it.
- The `vault_password` file must be in the repository root.

## Variables

The role has no defaults.

| Variable | Value | Description |
| --- | --- | --- |
| `user` | `jayden` | The user that gets Zsh and Oh My Zsh. Set in `inventory/wsl.yml`. |
| `zsh_path` | `/usr/bin/zsh` | The login shell for `user`. Set in `inventory/wsl.yml`. |
| `oh_my_zsh_url` | The `ohmyzsh` install script on GitHub | The Oh My Zsh install script. Set in `inventory/wsl.yml`. |
| `root_dir` | `/home/jayden/git` | Where the repositories go. Set in `vars/main.yml`. |
| `ssh_private_key` | Stored in the vault | The key for `/home/jayden/.ssh/id_rsa`. Set in `vars/main.yml`. |

## How to use it

`playbooks/wsl.yml` applies this role to the group `wsl`. See
[playbooks/wsl.md](../../playbooks/wsl.md).

## Safety

**CAUTION:** The role writes all of `~/.zshrc` for `user`. A change that you
make to that file by hand is lost.

**CAUTION:** The role replaces `/home/jayden/.ssh/id_rsa` with the key from
the vault.

## Known problems

- The tasks read `vars.root_dir`, but the role loads `root_dir` into
  `ansible_vars`. With ansible-core 2.20 and 2.21, `vars.root_dir` is not
  defined. The clone of `LINDS-Ansible` fails without a stop, and the task
  `Install Ansible reqs` then fails. Use `ansible_vars.root_dir` to correct
  this.
- `vars/main.yml` sets `packages`. No task uses it.
- Some paths have `/home/jayden` in them, not `user`.
