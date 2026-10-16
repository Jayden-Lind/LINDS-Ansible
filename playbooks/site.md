# site.yml

The `site.yml` playbook imports eight other playbooks and runs them one after
the other. It cannot run now, because one imported file does not exist.

## Before you start

- Read the page of each imported playbook.

## Procedure

**WARNING:** Do not run `site.yml`. It imports `proxmox.yml`, which removes
the Kubernetes iSCSI targets on `jd-proxmox-02`. See [proxmox.md](proxmox.md).

1. Run each playbook alone, as its own page tells you.

## What it changes

The imports, in order:

| Order | Playbook | File exists |
| --- | --- | --- |
| 1 | `plex.yml` | Yes |
| 2 | `kubernetes.yml` | Yes |
| 3 | `backup.yml` | Yes |
| 4 | `proxmox.yml` | Yes |
| 5 | `terraform.yml` | Yes |
| 6 | `ansible.yml` | No |
| 7 | `torrent.yml` | Yes |
| 8 | `dev.yml` | Yes |

It does not import `minecraft.yml`, `router.yml`, `storage_health.yml`,
`truenas.yml`, `vyos.yml`, `wsl.yml` or the Windows playbooks.

## If it fails

- `Could not find or access '.../playbooks/ansible.yml'`: the file does not
  exist. Ansible stops before the first play, so nothing changes.

## Known problems

- `playbooks/ansible.yml` does not exist. `--syntax-check` fails on it.
- `proxmox.yml` runs the iSCSI tasks in full. See the WARNING above.
- `terraform.yml` fails at the package task. See
  [roles/terraform/README.md](../roles/terraform/README.md).
