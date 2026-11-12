# proxmox_base

The `proxmox_base` role applies the base settings that both Proxmox hosts
need. It sets where the logs go, removes the causes of some errors that the
hosts log at boot, and stops services that a host does not use. It can also
install two units that apply tuning at boot, stop KSM, and write the kernel
settings of a host.

## What it does

Each part has a tag.

| Tag | What it does |
| --- | --- |
| `syslog` | Writes `/etc/rsyslog.d/90-remote.conf`, which sends all logs to Alloy on UDP port 1514. Removes `/etc/rsyslog.d/remote-logging.conf`, a second forwarder to UDP port 1515. |
| `services` | Stops and disables `nfs-blkmap`, the pNFS block layout daemon. The hosts do not use it. If `proxmox_base_rpcbind_enabled` is false, stops and disables `rpcbind.socket` and `rpcbind.service`. |
| `ipmi-watchdog` | If `ipmiutil_wdt.service` exists, installs a `crond.service` that does nothing. Then the restart of `crond.service` in the ipmiutil script succeeds. |
| `tuning` | If `proxmox_base_cpu_governor` is set, installs, enables and starts `cpu-governor.service`, which sets the CPU frequency governor at boot. If `proxmox_base_nic_ring_interfaces` is not empty, installs `nic-ring-tuning@.service` and enables one instance for each interface. Each instance sets the ring buffers of its interface at boot. |
| `ksm` | If `proxmox_base_ksm_enabled` is false, stops and disables `ksmtuned`, stops KSM and splits the shared pages. KSM puts equal memory pages of the VMs in one shared 4 KiB page, and that splits the 2 MiB pages of the VMs. |
| `sysctl` | If `proxmox_base_sysctl` is not empty, writes the settings to `/etc/sysctl.d/90-proxmox-base.conf` and loads the file. |

## What it does not do

- It does not install `ipmiutil`.
- It does not arm or change the BMC watchdog. `ipmiutil_wdt.service` arms
  it.
- It does not configure storage. The role `proxmox` configures the storage of
  `jd-proxmox-02`. The role `storage_health` patrols the disks of both hosts.
- It does not start `nic-ring-tuning`. The new ring size applies at the next
  boot.
- It does not remove a kernel setting. If you remove a line from
  `proxmox_base_sysctl`, the kernel keeps the value until the next boot.
- It does not remove other files in `/etc/sysctl.d`. A file with a later
  name can set a different value.
- It does not change the DNS settings or `/etc/network/interfaces`. Proxmox
  VE manages them (System > DNS and System > Network in the web interface).

## Requirements

- SSH as `root` to the hosts.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `proxmox_base_rsyslog_remote_line` | `*.* @(o)172.16.1.23:1514;RSYSLOG_SyslogProtocol23Format` | The rsyslog line that sends all logs to Alloy. If it is empty, the role does not write the file. |
| `proxmox_base_rpcbind_enabled` | `true` | If false, the role stops and disables rpcbind. Set it to false only on a host that does not export or mount NFS. |
| `proxmox_base_cpu_governor` | `""` | The CPU frequency governor, for example `schedutil`. If it is empty, the role does not install `cpu-governor.service`. |
| `proxmox_base_nic_ring_interfaces` | `[]` | The interfaces that get larger ring buffers. If the list is empty, the role does not install `nic-ring-tuning@.service`. |
| `proxmox_base_nic_ring_size` | `4096` | The number of receive and transmit descriptors for each interface in `proxmox_base_nic_ring_interfaces`. |
| `proxmox_base_ksm_enabled` | `true` | If false, the role stops KSM. Set it to false only on a host that has more free memory than KSM saves. |
| `proxmox_base_sysctl` | `{}` | The kernel settings of the host, as name and value. If it is empty, the role does not write the file. |

## How to use it

`playbooks/hypervisor.yml` applies this role to the group `hypervisors`. Set
the values of one host in `inventory/host_vars/<host>/proxmox_base.yml`. See
[playbooks/hypervisor.md](../../playbooks/hypervisor.md).

## Safety

**NOTE:** A change to a file in `/etc/rsyslog.d` restarts rsyslog. The
restart does not stop a VM.

**WARNING:** When the role stops KSM, each VM gets its own copy of the shared
pages. The host must have that much free memory. Compare `MemAvailable` in
`/proc/meminfo` with `pages_sharing` in `/sys/kernel/mm/ksm`, times 4 KiB,
before you set `proxmox_base_ksm_enabled` to false.

**WARNING:** On `linds-proxmox-01`, `eno1` is the WAN port of the router VM.
A change of its ring size resets the link and stops the internet at the site
for a few seconds. For this reason the role applies a new ring size only at
the next boot.

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
