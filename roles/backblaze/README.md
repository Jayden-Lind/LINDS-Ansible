# backblaze

The `backblaze` role backs up the NAS to Backblaze once a week. The
Backblaze VM reads a ZFS clone of the data disk of the file server. The file
server stays in service during the backup.

Backblaze Personal Backup backs up only disks that are attached to a Windows
computer. It does not back up a network share. Thus the Backblaze VM gets the
data disk as a second disk.

## What it does

The role installs `/usr/local/sbin/backblaze-run`, its settings in
`/etc/default/backblaze-run`, and `backblaze-run.service` with a weekly
timer. A run does these steps:

1. It freezes the file systems of the file server through the QEMU guest
   agent (VSS), takes the ZFS snapshot `<data zvol>@backblaze`, and thaws
   the file systems. The file server holds its writes for a few seconds.
2. It clones the snapshot to `<pool>/vm-<Backblaze VM>-nas-clone`, and
   attaches the clone to the Backblaze VM as `scsi1`.
3. It starts the Backblaze VM. If the drive does not show the Backblaze
   volume ID within 15 minutes, the run fails.
4. It waits until Backblaze has scanned the drive again, and has written a
   finished backup in `bzstat_lastbackupcompleted.xml` after that scan. The
   scanner writes the file list of the drive at the end of a scan. Backblaze
   also writes a finished backup soon after a start, from the file list of
   the last run, so that one does not count. At `backblaze_max_hours`, the
   run stops without a finished backup.
5. It shuts down the VM, destroys the clone, and destroys the snapshot.

The script writes metrics to
`/run/node-exporter-textfile/backblaze.prom`. node_exporter serves them with
the storage health metrics (role `storage_health`). The alert
`BackblazeRunOverdue` is in LINDS-Kubernetes,
`base/monitoring/proxmox-storage-health.yaml`.

## Requirements

- The Backblaze VM and the file server VM exist on the host. Both have the
  QEMU guest agent.
- Backblaze in the VM backs up the drive `backblaze_drive_letter`, and backs
  up continuously.
- The data disk has the folder `.bzvol` at the root, with the file
  `bzvol_id.xml` of the Backblaze volume `backblaze_volume_guid`. Backblaze
  writes this folder when it first backs up a drive. See "Give a new data
  disk to Backblaze".
- Hibernation is off in the Backblaze VM (`powercfg /hibernate off`), and
  with it Fast Startup. Each run gives Windows a newer clone of the same
  volume. A Windows that resumes a saved session can write old file system
  data to it.
- The role `storage_health` makes `/run/node-exporter-textfile`. Without it,
  the script writes no metrics.

## Variables

Set the first six for the host in
`inventory/host_vars/<host>/backblaze.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `backblaze_vmid` | `""` | The Backblaze VM. |
| `backblaze_source_vmid` | `""` | The file server VM. |
| `backblaze_source_zvol` | `""` | The zvol of the data disk, for example `NAS-SSD/vm-1113-disk-0`. |
| `backblaze_storage` | `""` | The Proxmox storage of the pool that holds the zvol. |
| `backblaze_volume_guid` | `""` | The Backblaze volume ID of the drive (`vguid` in `bzvol_id.xml`). |
| `backblaze_drive_letter` | `D` | The drive letter of the clone in the Backblaze VM. |
| `backblaze_clone_name` | `vm-<backblaze_vmid>-nas-clone` | The name of the clone. It must start with `vm-<backblaze_vmid>-`. |
| `backblaze_disk_slot` | `scsi1` | The slot of the clone in the Backblaze VM. |
| `backblaze_disk_options` | `backup=0,discard=on,iothread=1,ssd=1` | The options of the clone in the Backblaze VM. |
| `backblaze_schedule` | `Sat 02:30` | When the timer starts a run (systemd calendar expression). |
| `backblaze_max_hours` | `12` | The run stops the VM after this time. |

## How to use it

The playbook `playbooks/hypervisor.yml` applies the role to the group
`storage_hypervisors` (`jd-proxmox-02`):

```sh
ansible-playbook playbooks/hypervisor.yml --tags backblaze --check --diff
ansible-playbook playbooks/hypervisor.yml --tags backblaze
```

The timer does the weekly run. To do a run by hand, use these commands on the
host:

| Command | What it does |
| --- | --- |
| `systemctl start --no-block backblaze-run.service` | Starts a full run now, as the timer does. |
| `backblaze-run start` | Steps 1 to 3. The VM stays on, for example to look at Backblaze in the console. |
| `backblaze-run finish` | Shuts down the VM, then step 5. |
| `backblaze-run status` | Shows the VM, the clone, and what Backblaze reports. |
| `journalctl -u backblaze-run` | Shows the log of the runs. |

## Safety

**WARNING:** Do not attach the live data disk to the Backblaze VM. Two
machines that write to one volume destroy it. The Backblaze VM gets only the
clone.

**CAUTION:** Do not change the disks of the Backblaze VM while a run is
active. Proxmox can unplug a disk from a running VM. Use
`backblaze-run status` first.

**NOTE:** Changes that the Backblaze VM makes to the clone are lost when the
run ends. This includes the Backblaze scratch files, which Backblaze keeps on
the backed-up drive.

**NOTE:** While a run is active, the snapshot keeps the blocks that the file
server changes. These blocks are released when the run ends.

## Give a new data disk to Backblaze

Backblaze knows a drive by the volume ID in `.bzvol\bzvol_id.xml` at the
root of the drive. If a new data disk has no `.bzvol` folder, Backblaze sees
a new drive, and the old drive becomes a missing drive. Backblaze removes the
files of a drive that it does not see for 30 days (with the default version
history).

To continue the same backup on a new data disk:

1. Copy the folder `.bzvol` from the root of the old data disk to the root
   of the new data disk. A replicated folder does not include it.
2. Set `backblaze_source_vmid`, `backblaze_source_zvol` and
   `backblaze_storage` to the new disk.
3. Run `backblaze-run start`.
4. In the Backblaze VM, make sure that the clone has the drive letter
   `backblaze_drive_letter`. If not, set it with
   `Set-Partition -DriveLetter <letter> -NewDriveLetter <backblaze_drive_letter>`.
   Windows keeps the letter for the next runs.
5. Run `backblaze-run status`, and make sure that Backblaze scans the drive.

## If it fails

- Read the log: `journalctl -u backblaze-run`.
- If a run stops on an error, the script stops the VM and removes the clone.
  If the script cannot remove them, it tells why. Correct the cause, then run
  `backblaze-run finish`.
- "shows no D:\.bzvol\bzvol_id.xml": the clone has a different drive letter
  in the VM, or the data disk has no `.bzvol` folder. See "Give a new data
  disk to Backblaze".
- If the file server does not freeze, the run continues with a
  crash-consistent snapshot. Windows repairs the file system of the clone
  when it mounts it.
