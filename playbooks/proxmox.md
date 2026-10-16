# proxmox.yml

The `proxmox.yml` playbook applies the role `proxmox` to `jd-proxmox-02`. It
configures ZFS, NFS, iSCSI, sanoid, LXC containers and fan control.

## Before you start

- Read "Safety" in [roles/proxmox/README.md](../roles/proxmox/README.md).
- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the collections: `make update-requirements`.

## Procedure

**WARNING:** Do not run the full playbook against `jd-proxmox-02`. Its iSCSI
tasks replace `/etc/rtslib-fb-target/saveconfig.json` and run
`targetctl restore`. This removes every iSCSI target that the Kubernetes
storage driver, democratic-csi, made. Skip the iSCSI tasks.

1. Run `ansible-playbook playbooks/proxmox.yml --check --diff` to see the
   changes.
2. Apply only the tasks that you need. The tasks have no tags, so use one of
   these options:
   - `--start-at-task "<task name>"` starts at that task. Use a task after
     the iSCSI tasks, for example `"Install fan-control script"`.
   - `--step` asks before each task. Answer `n` for
     `Render iSCSI saveconfig.json`.

## What it changes

- The group `proxmox` in `inventory/proxmox.yml`. It has one host,
  `jd-proxmox-01.linds.com.au` (`10.0.50.246`). This is `jd-proxmox-02`,
  under its old name. Ansible connects as `root`.
- For the settings, see the role README.

## If it fails

- `'vault_minio_root_user' is undefined`: no file in this repository defines
  this variable. In a real run, the tasks before the LXC tasks have already
  run. See "Known problems" in the role README.
