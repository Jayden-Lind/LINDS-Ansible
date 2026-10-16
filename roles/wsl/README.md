# wsl

The `wsl` role sets up the WSL workstation of the operator: Git, Ansible,
Terraform, Packer, Go and Zsh, and the clones of the two IaC repositories.

## What it does

1. Updates the apt cache and installs `python3-pip`.
2. Sets the global Git name and e-mail of `wsl_user` (in the vault).
3. Installs `python3-argcomplete`, `python3-paramiko` and `pipx`. Clones
   LINDS-Ansible to `wsl_root_dir`, installs its Galaxy requirements, and
   copies the SSH private key (in the vault) to `~/.ssh/id_rsa`.
4. Adds the HashiCorp apt repository and installs `terraform` and `packer`.
   Clones LINDS-Terraform, runs `terraform init` in each folder if no folder
   has a `.terraform`, copies the variable files (in the vault) and runs
   `packer init`.
5. Installs Zsh, makes it the shell of `wsl_user`, installs Oh My Zsh and
   writes `~/.zshrc`.
6. Installs Go.

A clone that exists is not updated.

## Requirements

- An Ubuntu WSL host. The playbook runs on it (`connection: local`).
- The `vault_password` file is in the repository root. The sudo password is
  in the playbook, in the vault.

## Variables

| Variable | Where | Description |
| --- | --- | --- |
| `wsl_user` | `defaults/main.yml`: `user`, or `jayden` | The user of the workstation. |
| `wsl_root_dir` | `defaults/main.yml`: `/home/<wsl_user>/git` | The folder for the clones. |
| `ssh_private_key` | `vars/main.yml`, in the vault | The SSH private key of the user. |
| `user`, `zsh_path`, `oh_my_zsh_url` | `inventory/wsl.yml` | The user, the Zsh path, and the Oh My Zsh installer. |

## How to use it

`playbooks/wsl.yml`. See [playbooks/wsl.md](../../playbooks/wsl.md).

## Safety

**CAUTION:** The role writes `~/.ssh/id_rsa` and `~/.zshrc`. It replaces
those files if they are different.
