# minecraft.yml

The playbook prepares the Minecraft host. It applies the roles `common` and
`minecraft`.

## Before you start

- Start the VM `JD-Minecraft-01` (VM 1110 on `jd-proxmox-02`) and give it the
  DNS name `jd-minecraft-01`.
- Install the Galaxy roles and collections: `make update-requirements`.
- The play uses `become: true`. Your user needs `sudo` without a password on
  the host.

## Procedure

1. Run `ansible-playbook playbooks/minecraft.yml --check --diff`.
2. Run `ansible-playbook playbooks/minecraft.yml`.

## What it changes

- The group `minecraft`: `jd-minecraft-01` (`inventory/minecraft.yml`).
- See [roles/common/README.md](../roles/common/README.md) and
  [roles/minecraft/README.md](../roles/minecraft/README.md).
