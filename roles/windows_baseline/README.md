# windows_baseline

The role applies the security baseline to a Windows server.

## What it does

1. It turns on Windows Firewall for all profiles. It does not change rules.
2. It turns on Microsoft Defender real-time protection.
3. It removes SMB1 and refuses SMB1 connections.
4. It stops and disables the Print Spooler.
5. It stops and disables the services in `windows_baseline_services_disabled`:
   services of the desktop that a server VM does not use (see below).
6. It sets the maximum sizes of the event logs.
7. It allows Remote Desktop with Network Level Authentication, and opens its
   firewall rules.
8. It sets the CPU side-channel mitigations of Windows (see Variables).
9. If `windows_baseline_ipv6` is false, it turns off IPv6 on the server and on
   each network adapter.
10. It keeps the large send and receive offloads of the VirtIO network adapter
    on. If a value changes, it restarts the adapter.
11. If `windows_baseline_updates` is true, it installs Windows updates and
    restarts the server.

The role applies the settings one time, when the server is built. After the
server joins the domain, the GPO `Server - Baseline` keeps steps 1 to 8 and the
server setting of step 9 in place (role `windows_gpo`). If you change a setting
here, change it in `inventory/group_vars/windows/gpo.yml` too.

## Requirements

- A connection to the server: Kerberos for a domain member, or the local
  Administrator for a new clone (the playbooks set this).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_baseline_firewall_profiles` | Domain, Private, Public | The profiles to turn on. |
| `windows_baseline_defender_realtime` | `true` | Turn on Defender real-time protection. |
| `windows_baseline_disable_spooler` | `true` | Stop and disable the Print Spooler. |
| `windows_baseline_services_disabled` | 13 services, see `defaults/main.yml` | The services that the role stops and disables. |
| `windows_baseline_event_logs` | Security 1 GB, System and Application 256 MB | The maximum size of each log. |
| `windows_baseline_rdp` | `true` | Allow Remote Desktop with Network Level Authentication. |
| `windows_baseline_cpu_mitigations` | `true` | `false` turns off the Spectre variant 2 and Meltdown mitigations (and MDS buffer clearing). The inventory sets `false`. |
| `windows_baseline_ipv6` | `true` | `false` turns off IPv6 on the server and on each network adapter. The inventory sets `false`. |
| `windows_baseline_nic_offloads` | LSO and RSC on (the driver defaults) | The properties of the VirtIO network adapter to keep, by registry keyword. `{}` leaves the adapter as it is. |
| `windows_baseline_updates` | `false` | Install updates. `windows/prepare.yml` and `windows/join.yml` set `true`. |
| `windows_baseline_update_categories` | security, critical, rollups, definitions | The update categories. |
| `windows_baseline_update_reject` | `KB5007651` | Updates that the role does not install. |

## How to use it

- `playbooks/windows.yml` applies it to each server in `windows_managed`
  (tag `baseline`). Add `--limit <fqdn>` for one server, and
  `--tags cpu-mitigations`, `--tags ipv6` or `--tags nic-offloads` for one
  setting.
- The build playbooks apply it to each new server.

## Safety

**CAUTION:** The first run on a server that had no firewall and no Defender
can block a service or slow the server. Apply it to one server at a time, and
look at the server after the run.

**NOTE:** A change to the CPU mitigations takes effect at the next restart. On
the Intel host at LINDS the mitigations cost about 5 to 10% of system-call
speed; on the AMD host at JD no mitigation was on. They protect the kernel from
code that already runs in the server. The hypervisor keeps the VMs apart in
both cases.

**CAUTION:** With `windows_baseline_ipv6: false`, each network adapter loses
IPv6 at once. Connections over IPv6 stop, and the clients must connect again
over IPv4. The setting on the server takes effect at the next restart. Only the
loopback address `::1` then stays. Microsoft does not recommend this setting,
because some Windows components can stop working.

**CAUTION:** A change to the network adapter offloads restarts the adapter 15
seconds after the task. The network stops for about 3 seconds. The server
closes its SMB connections, and the clients connect again by themselves. The
role waits for the server to answer again.

**NOTE:** With large send offload (LSO) off, the server sends only 1500-byte
packets. With receive segment coalescing (RSC) off, the host must cut every
packet for the server to 1500 bytes. On `jd-fs-01` both were off. SMB reads
from the cluster then got about 210 MB/s for each stream.

**NOTE:** A service in `windows_baseline_services_disabled` stops at once. To
use one again, remove it from the list here and from the GPO
`Server - Baseline` (`inventory/group_vars/windows/gpo.yml`), set its start
mode on the server (`Set-Service <name> -StartupType Manual`) and start it.
The list has no service that Microsoft marks "Do not disable", and no service
that a running service needs. Remote Desktop stays.

## Known problems

- KB5007651 (Update for Windows Security platform) installs, reports success
  and is offered again. `win_updates` then fails with a loop. Windows Update
  installs it by itself.
- A server that loses IPv6 can keep its AAAA records in DNS. The role does not
  remove them. See "IPv6 records that do not route" in
  `docs/windows/runbooks/replication.md`.
