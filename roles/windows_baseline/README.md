# windows_baseline

The role applies the security baseline to a Windows server.

## What it does

1. It turns on Windows Firewall for all profiles. It does not change rules.
2. It turns on Microsoft Defender real-time protection.
3. It removes SMB1 and refuses SMB1 connections.
4. It stops and disables the Print Spooler.
5. It removes the Windows features in `windows_baseline_features_absent`.
6. If `windows_baseline_multicast_names` is false, it turns off LLMNR and
   mDNS. The server then finds names with DNS only.
7. If `windows_baseline_vendor_reports` is false, it turns off the reports to
   Microsoft: diagnostic data, crash reports, the Customer Experience
   Improvement Program, application telemetry and the diagnostic data of
   Edge.
8. It stops and disables the services in `windows_baseline_services_disabled`:
   services of the desktop that a server VM does not use (see below). It
   disables the services in `windows_baseline_services_disabled_at_restart`
   and does not stop them: they stop at the next restart.
9. It sets the maximum sizes of the event logs.
10. It allows Remote Desktop with Network Level Authentication, and opens its
   firewall rules.
11. It sets the CPU side-channel mitigations of Windows (see Variables).
12. If `windows_baseline_ipv6` is false, it turns off IPv6 on the server and on
    each network adapter.
13. It keeps the large send and receive offloads of the VirtIO network adapter
    on. If a value changes, it restarts the adapter.
14. If `windows_baseline_updates` is true, it installs Windows updates and
    restarts the server.

The role applies the settings one time, when the server is built. After the
server joins the domain, the GPO `Server - Baseline` keeps steps 1 to 4, 6 to
11 and the server setting of step 12 in place (role `windows_gpo`). If you change a setting
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
| `windows_baseline_features_absent` | `Wireless-Networking`, `XPS-Viewer` | The Windows features that the role removes. |
| `windows_baseline_multicast_names` | `true` | `false` turns off LLMNR and mDNS. The inventory sets `false`. |
| `windows_baseline_vendor_reports` | `true` | `false` turns off the reports to Microsoft. The inventory sets `false`. |
| `windows_baseline_vendor_report_policies` | 8 policies, see `defaults/main.yml` | The registry policies that turn the reports off. |
| `windows_baseline_services_disabled` | 13 services, see `defaults/main.yml` | The services that the role stops and disables. |
| `windows_baseline_services_disabled_at_restart` | `RmSvc` | The services that the role disables. Windows does not stop them while they run. |
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

**NOTE:** The removal of a feature is complete after the next restart of the
server. The role does not restart the server. Restart the domain controllers
one at a time.

**NOTE:** With `windows_baseline_multicast_names: false`, LLMNR stops at the
next refresh of Group Policy and mDNS stops at the next restart. A computer
that found a server by its short name without DNS (for example from a network
with no DNS suffix) does not find it then. Use the full name.

**NOTE:** With `windows_baseline_vendor_reports: false`, the servers send no
diagnostic data and no crash reports to Microsoft. Windows Update and the
updates of Edge still contact Microsoft, and so does the cloud protection of
Defender (`MAPSReporting`), which the role does not change. The scheduled
tasks that collect the data still start. They find the policy and stop.

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
