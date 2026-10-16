# LINDS-Ansible

This repository configures the hosts of the two sites, JD and LINDS: the
Proxmox hosts, the routers, the Kubernetes nodes, and the Windows domain
`linds.com.au`. Terraform (LINDS-Terraform) makes the VMs. Ansible configures
what runs in them.

All text in this repository uses Simplified Technical English. See
[docs/STYLE.md](docs/STYLE.md).

## Start here

1. Install the collections and roles: `ansible-galaxy install -r requirements.yml`.
2. Put the vault password in the file `vault_password` in the repository root.
   Git ignores it.
3. Run playbooks from the repository root. `ansible.cfg` reads the inventory
   in `inventory/` and the vault password from there.
4. For the Windows playbooks, run `make venv` one time and `make kinit` in each
   session. See [docs/windows/README.md](docs/windows/README.md).

**WARNING:** The repository is public. Put secrets only in vault files.

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
| [backup](playbooks/backup.md) | The backup host |
| [dev](playbooks/dev.md) | The development host |
| [kubernetes](playbooks/kubernetes.md) | The kubeadm cluster (not the Talos cluster) |
| [minecraft](playbooks/minecraft.md) | The Minecraft host |
| [plex](playbooks/plex.md) | Plex Media Server and its media mounts |
| [proxmox](playbooks/proxmox.md) | The JD Proxmox host (read the WARNING first) |
| [router](playbooks/router.md) | The Debian routers (always with `--limit`) |
| [site](playbooks/site.md) | Eight of the playbooks above, in order (does not run now) |
| [storage_health](playbooks/storage_health.md) | Disk and pool health checks on the Proxmox hosts |
| [terraform](playbooks/terraform.md) | The Terraform host |
| [torrent](playbooks/torrent.md) | The qBittorrent hosts |
| [truenas](playbooks/truenas.md) | The TrueNAS hosts |
| [vyos](playbooks/vyos.md) | The VyOS router at LINDS (`linds-vyos-01`) |
| [wsl](playbooks/wsl.md) | A WSL workstation |
| [windows](playbooks/windows.md) | The settings of the Windows domain |
| [windows-baseline](playbooks/windows-baseline.md) | The baseline of one Windows server |
| [windows-prepare](playbooks/windows-prepare.md) | Build step 1: baseline and updates on a new clone |
| [windows-edition](playbooks/windows-edition.md) | Build step 2: convert the Evaluation edition |
| [windows-join](playbooks/windows-join.md) | Build step 3: name, address and domain join |
| [windows-promote](playbooks/windows-promote.md) | Build step 4: domain controller, CA, file server |
| [windows-retire-dc](playbooks/windows-retire-dc.md) | Retire a domain controller |
| [windows-data-disk](playbooks/windows-data-disk.md) | Attach the data disks of a file server to its VM |
| [windows-ca](playbooks/windows-ca.md) | Install or restore the CA |
| [windows-ca-backup](playbooks/windows-ca-backup.md) | Back up the CA |
| [windows-capture](playbooks/windows-capture.md) | Record the state of the domain |
| [windows-forest](playbooks/windows-forest.md) | Make a new forest |

## Roles

Each role has a README in `roles/<role>/README.md`. The Windows roles start
with `windows_`.
