# proxmox_base

The `proxmox_base` role applies the base settings that both Proxmox hosts
need. It sets where the logs go, and it removes the causes of some errors
that the hosts log at boot.

## What it does

Each part has a tag.

| Tag | What it does |
| --- | --- |
| `syslog` | Writes `/etc/rsyslog.d/90-remote.conf`, which sends all logs to Alloy on UDP port 1514. Removes `/etc/rsyslog.d/remote-logging.conf`, a second forwarder to UDP port 1515. |
| `services` | Stops and disables `nfs-blkmap`, the pNFS block layout daemon. The hosts do not use it. |
| `ipmi-watchdog` | If `ipmiutil_wdt.service` exists, installs a `crond.service` that does nothing. Then the restart of `crond.service` in the ipmiutil script succeeds. |

## What it does not do

- It does not install `ipmiutil`.
- It does not arm or change the BMC watchdog. `ipmiutil_wdt.service` arms
  it.
- It does not configure storage. The role `proxmox` configures the storage of
  `jd-proxmox-02`. The role `storage_health` patrols the disks of both hosts.

## Requirements

- SSH as `root` to the hosts.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `proxmox_base_rsyslog_remote_line` | `*.* @(o)172.16.1.23:1514;RSYSLOG_SyslogProtocol23Format` | The rsyslog line that sends all logs to Alloy. If it is empty, the role does not write the file. |

## How to use it

`playbooks/proxmox_base.yml` applies this role to the group `proxmox_base`.
See [playbooks/proxmox_base.md](../../playbooks/proxmox_base.md).

## Safety

**NOTE:** A change to a file in `/etc/rsyslog.d` restarts rsyslog. The
restart does not stop a VM.

## Known problems

- At boot, rsyslog starts a few seconds before the network. It cannot send
  the first lines of the boot to Alloy, and for each line it logs "Network is
  unreachable". The lines stay in the journal of the host.
- On `jd-proxmox-02`, rasdaemon 0.8.3 logs "Can't get traces from cxl:..."
  for eight CXL events at each start. It waits 30 seconds for each event, so
  it records no hardware errors for the first four minutes. The kernel log
  still shows them. `DISABLE` in `/etc/default/rasdaemon` does not stop this.
  The CXL events are in the module `cxl_core`, which also loads `einj`, so
  the role does not load it.
