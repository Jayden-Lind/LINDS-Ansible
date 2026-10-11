# storage_health role

Makes sure every block on the Proxmox hosts' disks gets read on a schedule,
and that a disk, pool or array in trouble reaches a person.

It does three things on a host:

1. **Patrol.** Schedules what reads the disks end to end: a monthly SMART long
   self-test on every drive, and weekly ZFS scrubs for the pools that warrant
   more than Debian's monthly one. On a host with a PERC it checks that the
   controller's own patrol covers every virtual disk.
2. **Report.** A script asks `zpool`, `smartctl`, `perccli` and `lvs` what
   they know every ten minutes and writes it as Prometheus metrics;
   node_exporter serves that one file.
3. **Alert.** Prometheus in the cluster scrapes both hosts, and its rules go to
   Discord through the existing Alertmanager. That half is in
   LINDS-Kubernetes: `base/monitoring/proxmox-storage-health.yaml` (scrape and
   rules) and the `Storage.+` route in `base/monitoring/alertmanager-config.yaml`.

```
 drives ── zpool · smartctl · perccli · lvs
              │   storage-health-exporter, every 10 min (systemd timer)
              ▼
   /run/node-exporter-textfile/storage_health.prom
              │   node_exporter :9100, textfile collector only
              ▼
   Prometheus (job proxmox-storage-health) ── rules ──▶ Alertmanager ──▶ Discord
```

Why it exists: until 2026-10-11 the only thing either host could do about a
failing disk was mail root, and that mail bounced. And on linds-proxmox-01
nothing was patrolling at all: patrol read was on but excluded every virtual
disk, so when the SSD mirror was rebuilt on 2026-10-10 it found thousands of
sectors that had gone unreadable without anyone knowing.

## Hosts

`inventory/storage_health.yml`. The group is deliberately not `proxmox`:
`playbooks/proxmox.yml` gives that group the JD storage role (ZFS datasets,
NFS, iSCSI targets), which linds-proxmox-01 must never get.

| Host | Storage | Collectors that report |
|---|---|---|
| jd-proxmox-02 (inventory name `jd-proxmox-01.linds.com.au`) | ZFS pools `VM`, `NAS-SSD`, `HDD-20T` on ten SATA drives behind an Adaptec HBA; boots from NVMe | zfs, smart, lvm |
| linds-proxmox-01 | PERC H730 in RAID mode: two RAID 5 arrays of four disks, one SSD mirror; LVM thin pools on top | raid, smart, lvm |

## What reads the disks, and when

| Host | Patrol | Covers | When | Set by |
|---|---|---|---|---|
| jd | ZFS scrub | every pool | second Sunday of the month, 00:24 | `/etc/cron.d/zfsutils-linux` (Debian's, untouched) |
| jd | ZFS scrub | `VM` | every Wednesday, 03:00 | `zfs-scrub-weekly@VM.timer`, this role |
| both | SMART long self-test | every drive, the NVMe and unused disks included | third Friday of the month from 21:00, one drive every three hours, so into Sunday | smartd, this role |
| linds | Patrol read | VD 0 `NAS`, VD 3 `RAID-5` | weekly, Tuesday 16:00 UTC | the controller ([below](#the-perc-on-linds-proxmox-01)) |
| linds | Consistency check | VD 1 `OS` | weekly, Saturday 15:00 UTC | the controller |

How long they take, for judging a change to the schedule: a scrub of `VM` is a
quarter of an hour, `NAS-SSD` two hours, `HDD-20T` nearly fifteen. A long
self-test is 2 minutes on the HP SSDs, 1.5 to 5.5 hours on the Samsungs, 8 to
10 hours on the 4 TB disks at linds and 31 hours on each 22 TB disk.

`VM` is scrubbed weekly because it is quick and because one of its three
drives is a worn consumer SSD that has already replaced 1,231 sectors. The
scrub of 2026-10-11 raised the control plane's disk write latency from 1.5 ms
to 1.7 ms and did not show in API latency. A long self-test of that SSD the
same afternoon ran its 160 minutes without showing in either, and passed.

## Layout

| What | Where |
|---|---|
| The exporter | `files/usr/local/sbin/storage-health-exporter` (Python, standard library only) |
| Its service and timer | `files/etc/systemd/system/storage-health-exporter.{service,timer}` |
| What it should expect of the host | `templates/config.json.j2` → `/etc/storage-health/config.json` |
| node_exporter's arguments | `templates/prometheus-node-exporter.default.j2` → `/etc/default/prometheus-node-exporter` |
| The self-test schedule | `templates/smartd.conf.j2` → `/etc/smartd.conf` |
| When weekly scrubs start | `templates/zfs-scrub-weekly.conf.j2` → a drop-in for `zfs-scrub-weekly@<pool>.timer` |
| Defaults, with the reasoning | `defaults/main.yml` |
| Per-host values | `inventory/storage_health.yml` |
| Tests for the exporter | `tests/` — `python3 -m unittest discover -s roles/storage_health/tests` |

## Running it

```sh
ansible-playbook playbooks/storage_health.yml --check --diff   # what would change
ansible-playbook playbooks/storage_health.yml                  # apply, both hosts
ansible-playbook playbooks/storage_health.yml --tags exporter  # one part: exporter, selftests, scrub, raid
```

Safe to run in full at any time. It installs one package
(`prometheus-node-exporter`, without the collectors package it recommends),
restarts node_exporter or smartd when their configuration changed, and touches
nothing that serves storage. A self-test that is running is not interrupted by
smartd restarting.

The run ends by starting the exporter once and reading its metrics back
through node_exporter, and fails if a collector failed. On a host with
`storage_health_raid_patrol` set it also compares the controller's patrol
settings with the inventory and fails if they differ.

`--check` on a host that has never had the role stops at the first systemd
task, because the units are not there yet. After the first real run it is
clean.

## Metrics

All gauges, all prefixed `storage_`. `curl -s localhost:9100/metrics` on a host
shows them with their help text; running `/usr/local/sbin/storage-health-exporter`
by hand prints the same and writes nothing.

| Family | Labels | What |
|---|---|---|
| `storage_health_last_run_timestamp_seconds`, `storage_health_collector_success` | `collector` | when the file was written; whether each collector ran to the end |
| `storage_zfs_pool_expected`, `_pool_state`, `_pool_data_errors`, `_pool_size_bytes`, `_pool_allocated_bytes` | `pool`, `state` | pools the host should have; state; blocks ZFS could not rebuild |
| `storage_zfs_vdev_state`, `_vdev_errors` | `pool`, `vdev`, `type`, `state`, `kind` | per disk and per raidz/mirror group; `kind` is read, write or checksum |
| `storage_zfs_scrub_last_end_timestamp_seconds`, `_last_start_`, `_in_progress`, `_max_age_seconds`, `storage_zfs_pool_created_timestamp_seconds` | `pool` | when the last scrub ran to the end, and how old that may get |
| `storage_smart_device_info`, `_healthy`, `_read_success`, `_devices` | `device`, `model`, `serial` | the drive's own verdict; whether it answered |
| `storage_smart_reallocated_sectors`, `_uncorrectable_errors`, `_pending_sectors`, `_offline_uncorrectable_sectors`, `_crc_errors`, `_attributes_failing`, `_nvme_critical_warning` | same | the counters that mean a drive is losing sectors |
| `storage_smart_endurance_used_ratio`, `_spare_available_ratio`, `_spare_threshold_ratio`, `_wear_leveling_cycles`, `_written_bytes` | same | SSD wear. `rate(storage_smart_written_bytes[1d])` is the write rate |
| `storage_smart_selftest_last_passed`, `_long_age_seconds`, `_in_progress`, `_long_max_age_seconds` | same | self-test results and how long since the last long one |
| `storage_smart_temperature_celsius`, `_power_on_hours` | same | |
| `storage_raid_controller_state`, `_battery_state` | `controller`, `state` | |
| `storage_raid_vd_state`, `_vd_bad_blocks`, `_vd_patrol_read_scheduled`, `_vd_consistency_check_scheduled` | `vd`, `name`, `raid`, `state`, `kind` | per virtual disk; the last two say whether anything patrols it |
| `storage_raid_pd_state`, `_pd_media_errors`, `_pd_other_errors`, `_pd_predictive_failures`, `_pd_smart_alert` | `slot`, `model`, `serial`, `state` | per physical disk, as the controller sees it |
| `storage_raid_patrol_read_iterations`, `_consistency_check_iterations` | `controller` | completed rounds; they should move every week |
| `storage_lvm_thin_used_ratio`, `_thin_size_bytes`, `_thin_healthy` | `vg`, `lv`, `space` | thin pools; `space` is data or metadata |

`device` is the kernel name (`sde`, `nvme0`) or, behind the PERC,
`megaraid,N`, where N is the bay. A state is the `state` label of a series
whose value is always 1, so an alert can say what the state is.

About 260 series per host. node_exporter's own collectors are switched off;
`defaults/main.yml` says why.

## Alerts

The rules, their thresholds and what to do about each are in
LINDS-Kubernetes `base/monitoring/proxmox-storage-health.yaml`; that file is
the reference. In outline:

| About | Critical | Warning |
|---|---|---|
| ZFS | pool not imported, pool not ONLINE, blocks it cannot rebuild | a disk not ONLINE, error counters on a disk, scrub overdue, pool over 85% full |
| SMART | drive reports it is failing, endurance 95% used | failed self-test; more reallocated, unreadable or pending sectors than yesterday; CRC errors; endurance 80% used; spare area under 25%; no long self-test in 45 days; above 55 °C; not answering; a drive gone |
| RAID | controller not optimal, virtual disk not optimal, disk predicts its failure | disk not online (a rebuild shows here), more media errors or bad blocks than yesterday, a virtual disk nothing patrols, patrol read or consistency check not completing, cache battery |
| LVM thin | pool 90% full, pool unhealthy | pool 80% full |
| The reporting itself | | no metrics from a host, metrics older than half an hour, a collector failing |

Three things about how they behave:

- **Counters alert on change, not on value.** Several drives carry old damage
  that is known and stable. The rules compare each counter with itself a day
  earlier, so they speak when there is one more and are quiet otherwise.
- **They repeat once a day**, not every four hours like the cluster's alerts,
  and they keep firing for half an hour after the condition clears, so a host
  reboot or a failed scrape across the site tunnel does not resolve and
  re-raise them.
- **Prometheus and Alertmanager run on VMs on jd-proxmox-02.** If that host is
  down, nothing here can say so.

To see what is firing without Discord:
`kubectl -n monitoring exec alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 alert query alertname=~"Storage.+"`.

## The PERC on linds-proxmox-01

The controller's patrol is configured on the controller and lives in its
NVRAM. The role does not set it; `tasks/raid-patrol.yml` compares it with
`storage_health_raid_patrol` in the inventory and says why. This is what was
set by hand on 2026-10-10 and how:

```sh
cd /tmp                                   # perccli writes scratch files where it stands
perccli /c0 show patrolread nolog         # mode, excluded VDs, next start
perccli /c0 show cc nolog

# Patrol read for the two disk arrays. excludevd replaces the list it had.
perccli /c0 set patrolread excludevd=1 nolog
perccli /c0 set patrolread starttime=2026/10/13 16 nolog

# Weekly consistency check for the SSD mirror only.
perccli /c0 set cc=seq delay=168 starttime=2026/10/10 15 excludevd=0,3 nolog
```

- Patrol read does not read an array made only of SSDs (`PR on SSD:
  OnlyMixed`), which is why the mirror gets the consistency check instead.
- Start times are in the controller's clock, which is UTC
  (`perccli /c0 show time`).
- `PR iterations completed` kept counting for years while every virtual disk
  was excluded. A patrol that runs is not a patrol that reads anything, which
  is why the exporter reports coverage per virtual disk.

`perccli` is Dell's build of storcli and is not in Debian. It was installed by
hand on 2026-10-10 from `PERCCLI_7.1910.00_A12_Linux.tar.gz` (dell.com), which
contains the .deb; `/usr/local/sbin/perccli` is a link to
`/opt/MegaRAID/perccli/perccli64`. The exporter also accepts `storcli`. With
`storage_health_raid_patrol` set, a host where neither is found reports the
raid collector as failed instead of saying nothing.

## Changing things

- **A pool added or renamed:** list it under `storage_health_zfs_pools` with
  `scrub: weekly` or `monthly`. A pool that is not listed is still reported,
  on the monthly limit, but nothing notices if it fails to import.
- **A drive added or swapped:** nothing to change here. The exporter finds it
  on its next run. smartd only looks for drives when it starts, so
  `systemctl reload smartmontools` gets the new one into the schedule. Until
  it has had a long test it counts its whole powered life as untested: a used
  drive is flagged at once, a new one after 45 days.
- **Another host:** add it to `inventory/storage_health.yml`, run the
  playbook, then add its address to the ScrapeConfig in LINDS-Kubernetes.
- **The self-test schedule:** `storage_health_selftest_schedule`. The template
  is validated with `smartd -q showtests`, which also prints the dates an
  expression works out to. Adding a schedule to a host that had none does not
  start tests for the months it "missed": smartd counts from when it first
  sees the schedule.
- **A self-test by hand:** `smartctl -t long /dev/sdX`, or
  `smartctl -t long -d megaraid,N /dev/bus/4` behind the PERC. `smartctl -X`
  stops one.

## Things worth knowing

- The metrics file is on `/run`: rewritten every ten minutes, nothing in it
  needs to survive a reboot, and so it costs the boot disk no writes. The one
  thing the exporter keeps on disk is when each pool last finished a scrub
  (`/var/lib/storage-health/state.json`), because `zpool status` forgets that
  as soon as the next scrub starts or a resilver runs.
- The hour stamp in an ATA self-test log is 16 bits and starts again after
  65,535 hours. The exporter allows for that; the two HP SSDs at JD pass it
  in December 2026.
- The unused WD Blue in bay 4 at linds reports 0 power-on hours and stamps its
  self-tests at about 1,600. Its test results are read; its "time since the
  last long test" cannot be worked out and is never overdue.
- ZED and smartd still mail root on both hosts, and that mail still bounces.
  Nothing here depends on it.
- linds-proxmox-01 still has `check-thin-pools.timer`, installed by hand on
  2026-08-15, which mails root about thin pool usage. The `StorageThinPool*`
  alerts cover the same ground and do arrive; the timer is not managed here.
