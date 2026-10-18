# windows_data_disk

The role attaches the data disks of a Windows server to its VM, on the
Proxmox host. A data disk belongs to another VM, so a rebuild of the server
cannot delete it.

## What it does

1. For each disk, it finds the other VMs in `never_running_with` that run.
2. It stops if one of them runs. Two machines that write to one NTFS volume
   destroy it.
3. It sets those VMs not to start with the host. It sets protection on the VM
   that owns the volume (the VM ID in the volume name).
4. It attaches each disk to the VM of the server, in its slot, with its
   options. If the slot has another disk, it stops.

## Requirements

- SSH as `root` to the Proxmox host (`inventory/hypervisors.yml`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_data_disk_vm` | `{}` | The `windows_vm` host variable of the server. The playbook sets it. |

`windows_vm` in `inventory/windows.yml`:

```yaml
windows_vm:
  hypervisor: linds-proxmox-01     # inventory host of the Proxmox host
  id: 113                          # VM ID of the server
  data_disks:
    - slot: scsi1
      volume: NAS:vm-102-disk-0    # owned by VM 102
      options: backup=0,cache=none,discard=on,iothread=1
      never_running_with: [102, 104]
```

## How to use it

`playbooks/windows-data-disk.yml`. See `playbooks/windows-data-disk.md`.

## Safety

**WARNING:** Do not start a VM in `never_running_with` while the server runs.
The role refuses to attach a disk in that case, but nothing stops a person
from starting a VM by hand.

**WARNING:** Do not delete the VM that owns a volume. Proxmox deletes the
volumes that carry the ID of the VM.

## Known problems

- A disk that the role attaches to a running VM arrives in Windows offline,
  read-only and with a free drive letter. `windows_fileserver` corrects this.
