# LINDS-Ansible

This repository configures the hosts of the two sites, JD and LINDS: the
Proxmox hosts, the routers, the media and torrent hosts, the TrueNAS, and the
Windows domain `linds.com.au`. The Kubernetes cluster runs Talos and is not
managed here. Terraform (LINDS-Terraform) makes the VMs. Ansible configures
what runs in them.

All text in this repository uses Simplified Technical English. See
[docs/STYLE.md](docs/STYLE.md).

## Start here

1. Install the collections: `ansible-galaxy collection install -r requirements.yml`.
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
| `playbooks/` | One playbook for each kind of host, with a page `<name>.md` beside it |
| `playbooks/windows/` | The steps to build, retire and record a Windows server |
| `inventory/` | `<name>.yml` lists the hosts of `playbooks/<name>.yml`. `host_vars/<host>/` has the settings of one host. |
| `roles/` | The roles, each with a `README.md` |
| `deploy/` | The deploy on merge |
| `scripts/` | Helper scripts, for example `winrun.py` and `windows_state.py` |
| `windows-state/` | The captured state of the Windows domain, and the CA backup |
| `docs/` | The Windows overview and runbooks, and the style guide |

## Playbooks

| Playbook | Hosts | Roles |
| --- | --- | --- |
| [hypervisor](playbooks/hypervisor.md) | `jd-proxmox-02`, `linds-proxmox-01` | `proxmox_base`, `storage_health`, and `proxmox` on `jd-proxmox-02` |
| [router](playbooks/router.md) | `jd-router-01`, `linds-router-01` (always with `--limit`) | `router` |
| [nas](playbooks/nas.md) | `linds-truenas-01` | `truenas` |
| [media](playbooks/media.md) | The Plex host and the qBittorrent hosts | `common`, `plex`, `torrent` |
| [windows](playbooks/windows.md) | The Windows servers and the domain. Run it at any time. | The `windows_*` roles |
| [certificates](playbooks/certificates.md) | The devices that get a TLS certificate from the cluster CA | `cluster_cert` |
| [vyos](playbooks/vyos.md) | `linds-vyos-01`, until `linds-router-01` replaces it | `vyos` |

The steps for one Windows server are in `playbooks/windows/`:

| Playbook | What it does |
| --- | --- |
| [prepare](playbooks/windows/prepare.md) | Build step 1: baseline and updates on a new clone |
| [edition](playbooks/windows/edition.md) | Build step 2: convert the Evaluation edition |
| [join](playbooks/windows/join.md) | Build step 3: name, address and domain join |
| [promote](playbooks/windows/promote.md) | Build step 4: domain controller, CA, file server |
| [retire](playbooks/windows/retire.md) | Retire a Windows server (domain controller or member) |
| [data-disk](playbooks/windows/data-disk.md) | Attach the data disks of a file server to its VM |
| [ca-backup](playbooks/windows/ca-backup.md) | Back up the CA |
| [capture](playbooks/windows/capture.md) | Record the state of the domain |
| [nas-access](playbooks/windows/nas-access.md) | Show what each account can do in the NAS share |
| [forest](playbooks/windows/forest.md) | Make a new forest |

## Roles

Each role has a README in `roles/<role>/README.md`. The table above shows
which playbook applies each role. The Windows roles start with `windows_`.
