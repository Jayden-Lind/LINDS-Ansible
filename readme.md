# LINDS-Ansible

This repository configures the hosts of the two sites, JD and LINDS: the
Proxmox hosts, the routers, the media and torrent hosts, the TrueNAS, and the
Windows domain `linds.com.au`. The Kubernetes cluster runs Talos and is not
managed here. Terraform (LINDS-Terraform) makes the VMs. Ansible configures
what runs in them.

All text in this repository uses Simplified Technical English. See
[docs/STYLE.md](docs/STYLE.md).

## Start here

1. Install the collections and roles: `ansible-galaxy install -r requirements.yml`.
2. Put the vault password in the file `vault_password` in the repository root.
   Git ignores it.
3. Run playbooks from the repository root. `ansible.cfg` reads the inventory
   in `inventory/` and the vault password from there.
4. For the Windows playbooks, make the Python environment and get a Kerberos
   ticket first. See [docs/windows/README.md](docs/windows/README.md).

**WARNING:** The repository is public. Put secrets only in vault files.

## Deploy on merge

Merging to `main` applies the playbooks in `deploy/playbooks` to their
hosts: `jd-router-01`, the Proxmox hosts, the TrueNAS, the Plex and torrent
hosts, and the Windows servers. The deploy runs on `jd-jump-01`. See
[deploy/README.md](deploy/README.md).

**NOTE:** If you change a host by hand, the deploy does not undo the change.
It stops for that playbook until the change is merged.

## Layout

| Folder | Contents |
| --- | --- |
| `inventory/` | The hosts, their groups and their variables |
| `playbooks/` | One playbook for each job, with a page `<name>.md` beside it |
| `roles/` | The roles, each with a `README.md` |
| `scripts/` | Helper scripts, for example `winrun.py` and `windows_state.py` |
| `windows-state/` | The captured state of the Windows domain, and the CA backup |
| `docs/` | The Windows overview and runbooks, the style guide, reports |

## Playbooks

| Playbook | What it does |
| --- | --- |
| [minecraft](playbooks/minecraft.md) | The Minecraft host |
| [plex](playbooks/plex.md) | Plex Media Server and its media mounts |
| [proxmox](playbooks/proxmox.md) | The JD Proxmox host (read the WARNING first) |
| [router](playbooks/router.md) | The Debian routers (always with `--limit`) |
| [storage_health](playbooks/storage_health.md) | Disk and pool health checks on the Proxmox hosts |
| [torrent](playbooks/torrent.md) | The qBittorrent hosts |
| [truenas](playbooks/truenas.md) | The TrueNAS hosts |
| [vyos](playbooks/vyos.md) | The VyOS router at LINDS (`linds-vyos-01`) |
| [wsl](playbooks/wsl.md) | A WSL workstation |
| [windows](playbooks/windows.md) | The Windows servers and the domain: everything, any time |
| [windows-prepare](playbooks/windows-prepare.md) | Build step 1: baseline and updates on a new clone |
| [windows-edition](playbooks/windows-edition.md) | Build step 2: convert the Evaluation edition |
| [windows-join](playbooks/windows-join.md) | Build step 3: name, address and domain join |
| [windows-promote](playbooks/windows-promote.md) | Build step 4: domain controller, CA, file server |
| [windows-retire](playbooks/windows-retire.md) | Retire a Windows server (domain controller or member) |
| [windows-data-disk](playbooks/windows-data-disk.md) | Attach the data disks of a file server to its VM |
| [windows-ca-backup](playbooks/windows-ca-backup.md) | Back up the CA |
| [windows-capture](playbooks/windows-capture.md) | Record the state of the domain |
| [windows-forest](playbooks/windows-forest.md) | Make a new forest |

## Roles

Each role has a README in `roles/<role>/README.md`. The Windows roles start
with `windows_`.
