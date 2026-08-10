# Healthcheck — jd-vyos-01 + jd-proxmox-02

**Date:** 2026-08-10
**Scope:** VyOS router `10.0.50.1`, Proxmox host `10.0.50.246`, UniFi integration.
`linds-vyos-01` was explicitly out of scope and was not inspected.

Nothing in this document has been applied. Every command below is a proposal.

---

## Summary

Both boxes are fundamentally healthy — pools clean, tunnels up, BGP converged,
no failed units. The findings are concentrated in three places:

1. **The torrent VLAN (51) has no working egress and no LAN access.** Two
   independent faults, both long-standing.
2. ~~Every UniFi switch and AP is cut off from the controller.~~ **Retracted —
   see 1.4.** The controller is inside VLAN 52 with the devices; this was wrong.
3. **The Proxmox host has no VM backups and no VM snapshots** — including the
   domain controller and the file server.

---

## P1 — Act on these

### 1.1 VLAN 51 egress is dead (wg101)

`wg101` last completed a handshake **3 days 4 hours ago**. The peer is pinned to
a literal address (`103.137.14.195`) that NordVPN has since rotated. SNAT rule
9999 (`10.0.51.0/24 → wg101`) has passed **0 packets**.

`wg10` does not have this problem because it specifies the peer as a host-name,
which lets `vyos-domain-resolver` follow the rotation — the log shows it
re-resolving every few minutes.

```
set interfaces wireguard wg101 peer nordvpn host-name '<us-server>.nordvpn.com'
delete interfaces wireguard wg101 peer nordvpn address
```

Then update `wg_host` in the vault to the hostname, as was done for `wg_us_host`.

### 1.2 VLAN 51 also has no route to the LAN

Two policy routes are bound to the same interface:

```
set policy route NordVPN interface 'eth1.51'    rule 100 → table 100
set policy route VPN     interface 'eth1.51'    rule 1   → table main
```

VyOS chains both off `eth1.51` in `VYOS_PBR_PREROUTING`, with `NordVPN` first.
Its rule 100 matches `0.0.0.0/0` and returns, so the `VPN` chain never sees a
packet — its nftables counter is literally `0 packets, 0 bytes`. The intended
LAN bypass has never worked.

`NordVPNUS` gets this right: bypass at rule 9, default at rule 10, one policy.

```
delete policy route VPN
set policy route NordVPN rule 9 destination group network-group 'LAN-Addresses'
set policy route NordVPN rule 9 set table 'main'
```

Rule 9 sorts before rule 100, so the bypass is evaluated first.

> Deliberately **not** encoded in the refactor: the role now mirrors the running
> config, and adding the bypass changes behaviour. If VLAN 51 is meant to stay
> walled off from the LAN, skip this one — but then delete `policy route VPN`
> anyway, because it is dead weight either way.

### 1.3 BGP router-id is pinned to the cellular backup's DHCP address

```
BGP router identifier 192.168.0.46, local AS number 64550
```

`192.168.0.46` is the DHCP lease on `eth1.99` — the **cellular backup** WAN.
FRR picked it as the highest-numbered interface address. If that lease changes,
the router-id changes, and all five BGP sessions (four Talos nodes + the LINDS
peer) reset.

```
set protocols bgp parameters router-id 10.0.50.1
```

### 1.4 ~~UniFi gear cannot reach the UniFi controller~~ — RETRACTED

**This finding was wrong.** Corrected 2026-08-10 after the site owner pointed out
that `10.0.80.4` is the controller at the *LINDS* site, not this one.

The JD controller is **10.0.52.2**, inside VLAN 52 with every switch, AP and
camera. Confirmed by probing from the Proxmox host, which can reach that VLAN:

```
10.0.52.2    open: 22 443 8080 8443 8880     ← controller
10.0.52.3    open: 22                        ← usw-enterprise-24-poe
10.0.52.7    open: 22                        ← usw-enterprise-8-poe
10.0.52.10   open: 22                        ← AP
10.0.52.11   open: 22                        ← AP
```

Controller and devices share an L2 segment, so adoption and inform traffic never
enters the router's forward chain. Nothing was broken and nothing needed fixing.

**What led me astray.** Probing those hosts *from the router* showed every port
closed, which I read as "blocked". The real cause is input filter rule 2:

```
rule 2  drop  all   iifname "eth1.52"
rule 50 accept all  ct state { established, related }
```

Rule 2 sorts before rule 50, so return traffic for router-originated connections
into VLAN 52 is dropped along with everything else. The router can transmit into
that VLAN but can never complete a handshake — it is one-way by construction.
For an isolated VLAN that is a reasonable design, and it matches the stated
intent, but it does mean the router cannot ping, poll or monitor anything in
VLAN 52.

The 91,704 packets counted by rule 100 are the isolated VLAN attempting other
inter-VLAN traffic — the rule doing its job, not a symptom.

A forward rule 95 permitting `10.0.52.0/24 → 10.0.80.4` was briefly added and
has been removed; it granted the isolated VLAN a path to a LINDS host for no
reason.

### 1.5 Proxmox has no VM backups and no VM snapshots

`/etc/pve/jobs.cfg` does not exist and `vzdump.cron` is empty. Sanoid's policy
covers only `VM/truenas-nas`:

```
[VM/truenas-nas]
    use_template = ssd_short
    recursive = yes
```

The VM zvols — `vm-1102` (JD-DC-01, the domain controller), `vm-1103` (JD-FS-01,
plus its 14.5 TB data disk), the Talos nodes — have **neither**. The VMs carry
`backup=1` flags, but no job ever reads them.

Add a `VM` dataset stanza to `roles/proxmox/templates/sanoid.conf.j2` (cheap,
local, immediate), and a vzdump job to somewhere off-host. Snapshots on the same
pool are not a backup.

---

## P2 — Worth doing

### 2.1 ZFS write throttle is causing the load-34 stalls

Load average is 34 on 128 threads with **17.5 % iowait**. `txg_sync` has 67
minutes of CPU and sits in D state; a dozen `z_wr_iss` threads are blocked
alongside it.

`/etc/modprobe.d/zfs.conf` allows a very large dirty set:

```
options zfs zfs_dirty_data_max=8589934592                      # 8 GiB
options zfs zfs_vdev_async_write_active_max_dirty_percent=80   # throttle at 6.4 GiB
```

The `VM` pool is a 3-wide SATA raidz1. It cannot absorb a 6.4 GiB flush, so
every txg turns into a long stall. Something closer to:

```
options zfs zfs_dirty_data_max=2147483648                      # 2 GiB
options zfs zfs_vdev_async_write_active_max_dirty_percent=60
```

smooths the flushes out. Needs `update-initramfs -u` and a reboot — which is
due anyway (2.3).

### 2.2 The VM pool wastes 1.27 TB

```
raidz1-0                                       1.62T
  ata-Samsung_SSD_870_EVO_2TB_S5Y3NF0RA03724J  1.82T
  ata-VK0600GDUTQ_PHWL5456008E600TGN            559G
  ata-VK0600GDUTQ_PHWL5456002Z600TGN            559G
```

raidz1 sizes every member to the smallest, so the 2 TB Samsung contributes
559 GB and ~1.27 TB is unreachable. The pool is 45 % full and **62 % fragmented**
— the fragmentation is a symptom of running a 16 K volblocksize on a narrow
raidz1 that is filling up.

No cheap fix; it needs a rebuild. Worth planning, given it holds every VM.

### 2.3 Host is running a kernel five versions behind

```
running: 7.0.14-4-pve
installed: 7.0.14-11-pve, -8, -6, -5
uptime: 29 days
```

### 2.4 NIC offloads are off on both interfaces

```
eth1 (virtio):  scatter-gather off, GSO off, GRO off
eth2 (mlx5 VF): scatter-gather off, GSO off, GRO off
```

VyOS explicitly disables offloads unless the CLI node is set, so this is the
default state, not a driver quirk. On a router that has forwarded 570 GB on eth1
and 630 GB on eth2, that is real CPU spent segmenting in software.

The post-boot script tries to fix eth2 with `ethtool -K`, but **VyOS re-applies
its own offload settings on every commit that touches the interface**, wiping it
until the next reboot. The current state proves it: the script ran at boot, and
the values are off now, after the Aug 8 commits.

Use the CLI nodes so the setting survives commits:

```
set interfaces ethernet eth1 offload gro
set interfaces ethernet eth1 offload gso
set interfaces ethernet eth1 offload sg
set interfaces ethernet eth2 offload gro
set interfaces ethernet eth2 offload gso
set interfaces ethernet eth2 offload sg
set interfaces ethernet eth2 offload tso
```

Then set `vyos_wan_offload` / `vyos_lan_offload` in
`inventory/group_vars/jd_vyos.yml` to match — the role already reads them.

Leave `hw-tc-offload`, `rfs` and `rps` off: `rfs`/`rps` are software steering
that mostly hurts on a 4-vCPU guest with 4 queues already, and `hw-tc-offload`
is meaningless on virtio.

### 2.5 eth2 is dropping frames at the ring

```
RX: 5427 overrun, 1029 collisions
Ring: RX 1024 / TX 1024   (hardware max 8192)
```

```
set interfaces ethernet eth2 ring-buffer rx 4096
set interfaces ethernet eth2 ring-buffer tx 4096
```

### 2.6 The conntrack table-size sysctl does nothing

The config asks for 524288:

```
set system sysctl parameter net.netfilter.nf_conntrack_max value '524288'
```

The running value is **262144**. VyOS owns `nf_conntrack_max` through its own
conntrack node and overwrites the raw sysctl. Current usage is only 650 entries,
so there is no pressure — but the setting is a lie. Either drop it or use:

```
set system conntrack table-size 524288
```

### 2.7 LLDP is running but listening on nothing

`lldpd` is active, SNMP and four legacy protocols are configured — but there is
no `set service lldp interface`, so it neither sends nor receives. `lldpcli show
neighbors` is empty.

```
set service lldp interface all
```

This is what makes the router show up in UniFi's topology map, and gives you
`show lldp neighbors` for tracing which switch port a device is on.

### 2.8 NFS exports `/mnt/NAS` with `no_root_squash` to the main LAN

```
/mnt/NAS  10.0.50.0/24(sec=sys,rw,no_root_squash,insecure,no_subtree_check)
```

Any host on the main client LAN can mount that share and write as uid 0.
`10.0.53.0/24` (k8s) needs it; `10.0.50.0/24` almost certainly does not.

### 2.9 `/etc/exports` has two owners

The file header says:

```
# Managed by Terraform (proxmox/nfs.tf). Manual edits will be overwritten.
```

but `roles/proxmox/tasks/nfs.yml` renders it from `templates/exports.j2` using
`proxmox_nfs_exports`. Whichever ran last wins. Pick one.

### 2.10 The iSCSI target in inventory does not exist

`inventory/proxmox.yml` declares:

```yaml
proxmox_iscsi_targets:
  - iqn: iqn.2005-10.org.truenas:arr-suite
    luns:
      - {name: arr-iscsi, plugin: fileio, path: /mnt/NAS/arr-iscsi, ...}
```

`/mnt/NAS/arr-iscsi` does not exist and there are **zero** fileio backstores.
The 13 live backstores are all k8s CSI block devices under
`iqn.2026-06.au.com.linds:csi-pvc-*`, managed by the CSI driver. Dead config.

### 2.11 Node name mismatch in storage.cfg

The host is `jd-proxmox-02`. Two references still say `jd-proxmox-01`:

```
lvmthin: NAS
    nodes jd-proxmox-01        # ← storage is inert on this host
```

and `inventory/proxmox.yml` addresses it as `jd-proxmox-01.linds.com.au`.

### 2.12 One SSD is wearing 15× faster than its peers

```
sdd: Wear_Leveling_Count  value 083  raw 392
others:                   value 098  raw 26-27
```

Not failing (SMART PASSED, ~17 % consumed), but worth watching — it is almost
certainly the member of the `VM` pool absorbing the write amplification from 2.1.

---

## P3 — Dead config worth deleting

Each of these is live on the router, does nothing, and was removed from the
Ansible code during the refactor. The role only ever adds, so they persist until
deleted by hand.

| Config | Evidence |
|---|---|
| `policy route VPN` (4 lines) | nftables counter: 0 packets |
| `protocols static route 1.0.0.1/32` | no next-hop or interface — incomplete |
| `protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast route-map` | dangling empty node, no direction |
| `policy route-map RM-EXPORT-IPSEC` + `K8S-EXT`/`K8S-PODS`/`K8S-SVC` prefix-lists | defined, never attached to anything |
| `nat source rule 100` (`10.100.100.0/24 → eth2`) | 0 packets; no such subnet exists |
| `nat source rule 20` (`172.16.1.1`) | 0 packets; covered by catch-all rule 200 |
| `system login user vyos authentication plaintext-password ''` | empty artifact node |
| `service dns forwarding listen-address 10.0.52.1` | input rule 2 drops all eth1.52→router traffic except DHCP, so nothing can query it |

```
delete policy route VPN
delete protocols static route 1.0.0.1/32
delete protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast route-map
delete policy route-map RM-EXPORT-IPSEC
delete policy prefix-list K8S-EXT
delete policy prefix-list K8S-PODS
delete policy prefix-list K8S-SVC
delete nat source rule 100
delete nat source rule 20
delete system login user vyos authentication plaintext-password
delete service dns forwarding listen-address 10.0.52.1
```

Keep `NO-ADVERTISE` — `RM-NO-ADVERTISE` uses it and is attached to the k8s
peer-group.

---

## Security notes

- **The LINDS CA private key is stored in the router's running config**
  (`set pki ca LINDS private key`). Anyone who can read the config — or a config
  backup, or a commit revision — can mint certificates trusted across the estate.
  The router only needs the CA *certificate* to validate peers; it does not need
  the private key. Removing it is a one-line change with a large payoff.
- **IPsec remote-access users have short, guessable passwords** stored in
  cleartext in the config (`vpn ipsec remote-access ... local-users`). They are
  the second factor behind an x509 server cert, but EAP-MSCHAPv2 is brute-forcible.
- **SNMP community is `public`**, readable from all of RFC1918.
- These are all in the running config, so they are also in `/config/config.boot`
  and its 50-odd retained revisions.

---

## UniFi-specific

Beyond 2.7 (LLDP). Note 1.4 has been retracted — the controller is local to
VLAN 52 and adoption was never broken:

**No mDNS repeater.** The router sees mDNS (`224.0.0.251`) and SSDP
(`239.255.255.250`) groups on `eth1` only. Cameras and APs are in VLAN 52,
clients in VLAN 50, so AirPlay, Chromecast, printer and Sonos discovery cannot
cross. VyOS has the node:

```
set service mdns repeater interface eth1
set service mdns repeater interface eth1.52
```

(Requires the firewall to permit the answering traffic across the two VLANs.)

**L3 adoption is not in play** — controller and devices share VLAN 52, so
discovery happens by broadcast on the local segment. The note below applies only
if the controller is ever moved off that VLAN. This VyOS build has **no**
`vendor-option ubiquiti unifi-controller` node (I checked the template tree), so
DHCP option 43 is not available through the CLI. The workable options are:

```
set system static-host-mapping host-name unifi inet 10.0.80.4
```

so `unifi` resolves via the DNS forwarder for VLANs that use it — or set the
inform URL per device with `set-inform http://10.0.80.4:8080/inform` over SSH.

Note VLAN 52's DHCP hands out `1.1.1.1` as the resolver, not the router, so the
static-host-mapping route needs the scope changed to `10.0.52.1` first — which
in turn needs input rule 2 relaxed to allow DNS.

**The isolation policy is inverted for management traffic.** VLAN 52 is named
"isolated" and is treated as untrusted — no router access beyond DHCP, no
inter-VLAN. But it currently holds the network *management* plane (both
Enterprise switches, both APs) alongside the cameras. Management gear needs to
reach the controller; cameras do not need to reach anything. Splitting them into
two VLANs would let each get the policy it actually wants.

---

## What was verified

| Check | Result |
|---|---|
| VyOS uptime / load | 7 d, 3 % / 1 % / 0.2 % |
| VyOS memory | 1.08 GB of 3.83 GB |
| VyOS disk | 30 % of 16 GB |
| Failed systemd units | none |
| BGP | 5 peers, all up 1 d 22 h, 24 prefixes advertised |
| IPsec site-to-site | up, 267 M in / 9 G out |
| Dual-WAN failover | both routes installed, eth2 metric 1, eth1.99 metric 10 |
| DNS resolution | working, 1.1.1.1 at 9.8 ms |
| ZFS pools | 3 pools ONLINE, 0 errors, scrubs clean within 2 days |
| SMART | 10/10 disks PASSED |
| ARC | 64 GiB, at target |

---

## Ansible reconciliation

Committed on branch `vyos-reconcile-refactor` (`fe48c7c`). The role now matches
the running config; the drift it used to push on every run is gone.

| | before | after |
|---|---|---|
| tasks executed against the router | 121 | 42 |
| real config changes in `--check --diff` | 6 | 0 |
| one-shot `ignore_errors` migration blocks | 5 | 0 |

The six drifts the role was pushing back onto the router each run:

1. `conntrack modules h323` + `sip` — added by `main.yml`, deleted by `jd_system.yml`
2. `ntp allow-client 0.0.0.0/0` + `::/0` — added by `main.yml`, deleted by `jd_services.yml`
3. `update-check url` reverted to a dead `vyos-rolling-nightly-builds` path
4. `offload gro/gso/hw-tc-offload/rfs/rps/sg` pushed onto both NICs
5. `nat destination rule 24 protocol tcp`, live is `tcp_udp`
6. `wg10` peer reset from the host-name to a stale literal IP

(1) and (2) are the interesting ones — the role was fighting itself, so every run
reported changes and every run left the router exactly where it started.

Structurally: VLANs, DHCP scopes, firewall rules, NAT rules, BGP config and
WireGuard tunnels are now declarative data in
`inventory/group_vars/jd_vyos.yml`, rendered through `roles/vyos/templates/*.j2`.
Adding a port forward or a DHCP reservation is a dict entry rather than a new
task. The inventory also gained a real `linds_vyos` group — both routers were
previously inside a group named `jd_vyos`, which is why site dispatch was done
with `when: inventory_hostname == ...`.

`linds-vyos-01` is untouched and unverified. Its group_vars pin the values the
shared `main.yml` used to supply so this work cannot change it, with one
deliberate exception noted in that file: its NTP client ACL is no longer
`0.0.0.0/0`, which had been leaving it an open NTP reflector.

---

# Appendix: config option audit

Second pass, 2026-08-10 — reviewing the VyOS *settings themselves* for
correctness, performance value and compatibility, rather than drift.

Verdict up front: nothing here is dangerous to forwarding, and the box performs
fine. But a large share of the tuning block is **inert on a router**, two
settings are actively counterproductive, one is a no-op on this kernel, and
IPv6 has no firewall at all.

## A.1 IPv6 is completely unfiltered

This is the most significant finding in the whole review.

```
chain VYOS_IPV6_FORWARD_filter {
    type filter hook forward priority filter; policy accept;
    counter packets 137072814 bytes 157125574833 accept comment "FWD-filter default-action accept"
}
```

**Zero rules. 137 million packets, 157 GB forwarded.** The IPv4 forward chain
has 3 rules; the IPv6 one has none. `ipv6 input filter` is `accept` too, where
IPv4 input is `drop`.

Meanwhile the router hands out real, globally-routable addresses:

```
net.ipv6.conf.all.forwarding = 1
eth1     2001:8003:dc51:bc00::/64   (delegated, sla-id 0)
eth1.52  2001:8003:dc51:bc01::/64   (delegated, sla-id 1)
```

~163 devices currently hold a GUA, spread across several prefixes the ISP has
rotated through:

```
113  2001:8003:dc90:e600
 43  2001:8003:dc51:bc00
  2  2001:8003:dd7a:cb00
  ...
```

IPv4 is protected by NAT plus `input drop`. IPv6 has neither — every one of
those devices is directly addressable from the internet, including the cameras
and UniFi gear on VLAN 52, which the IPv4 policy goes to some trouble to
isolate. The VLAN 52 isolation rules are IPv4-only, so IPv6 bypasses them
entirely.

Minimum viable fix — stateful inbound, mirroring what NAT gives you on v4:

```
set firewall ipv6 forward filter default-action drop
set firewall ipv6 forward filter rule 10 action accept
set firewall ipv6 forward filter rule 10 state established
set firewall ipv6 forward filter rule 10 state related
set firewall ipv6 forward filter rule 20 action accept
set firewall ipv6 forward filter rule 20 inbound-interface name eth1
set firewall ipv6 forward filter rule 30 action accept
set firewall ipv6 forward filter rule 30 protocol icmpv6

set firewall ipv6 input filter default-action drop
set firewall ipv6 input filter rule 10 action accept
set firewall ipv6 input filter rule 10 state established
set firewall ipv6 input filter rule 10 state related
set firewall ipv6 input filter rule 20 action accept
set firewall ipv6 input filter rule 20 protocol icmpv6
set firewall ipv6 input filter rule 30 action accept
set firewall ipv6 input filter rule 30 source address fe80::/10
set firewall ipv6 input filter rule 40 action accept
set firewall ipv6 input filter rule 40 destination port 546
set firewall ipv6 input filter rule 40 protocol udp
```

Do not skip the ICMPv6 rules — IPv6 breaks without PMTUD, NDP and RA.
Stage this with `commit-confirm` since a mistake locks you out over v6.

## A.2 Most of the TCP sysctl block does nothing on this box

Forwarded packets never touch the local TCP stack. Socket buffers, congestion
control, timestamps, SACK, keepalives and Fast Open apply **only** to sockets
terminating on the router — SSH, BGP, IKE, the DDNS client. That is a rounding
error next to the ~1 TB/day this box forwards.

Inert for forwarding (harmless, but they buy nothing):

```
net.ipv4.tcp_fastopen, tcp_mtu_probing, tcp_tw_reuse, tcp_syn_retries,
tcp_slow_start_after_idle, tcp_no_metrics_save, tcp_notsent_lowat,
tcp_keepalive_*, tcp_rmem, tcp_wmem
```

They read like they came from a web-server tuning guide. Keeping them is fine;
just don't expect throughput from them.

What *does* affect forwarding: `netdev_budget*`, `netdev_max_backlog`, the
conntrack settings, offloads, and MTU/MSS.

## A.3 `tcp_low_latency` is a no-op on this kernel

```
net.ipv4.tcp_low_latency = 1     # kernel 6.18-vyos
```

The TCP prequeue this controlled was **removed in Linux 4.14**. The knob still
accepts a write and does nothing. Worth noting that the repo's own
`jd_system.yml` carried a comment saying exactly this — "removed in kernel 4.14,
no-op" — and claimed the setting was omitted, while `main.yml` set it anyway.
The refactor consolidated it and preserved the live value; it can just go.

## A.4 `tcp_timestamps 0` — remove this one

```
net.ipv4.tcp_timestamps = 0
```

Disabling timestamps turns off **PAWS** (protection against wrapped sequence
numbers) and **RTTM** (accurate RTT measurement, which congestion control
depends on). The usual motive is hiding uptime, but Linux has used randomised
per-connection offsets since 4.10, so there is nothing left to hide.

Impact is bounded — router-terminated TCP only, so BGP and SSH — but it is a
straight downgrade with no upside. Default is `1`.

## A.5 `rmem_default` / `wmem_default` at 25 MB is the wrong knob

```
net.core.rmem_default = 26214400     # 25 MB   (kernel default: 212992 / 208 KB)
net.core.wmem_default = 26214400     # 25 MB
net.core.rmem_max     = 26214400     # 25 MB   ← this one is correct
```

`*_max` is a ceiling — raising it is right, and lets TCP autotune up when a fat
path justifies it. `*_default` is the buffer **every socket starts with**. At
25 MB, every UDP socket the router opens — and pdns-recursor opens a lot —
reserves an enormous receive queue. For UDP there is no autotuning to walk it
back, so it is both wasteful and a bufferbloat risk under load.

Leave the defaults alone and keep the max high:

```
delete system sysctl parameter net.core.rmem_default
delete system sysctl parameter net.core.wmem_default
```

## A.6 `netdev_budget_usecs` is 4× the default

```
net.core.netdev_budget       = 600     (default 300)
net.core.netdev_budget_usecs = 8000    (default 2000)
```

8 ms is a long time to let one softirq poll loop hold a core. On a 4-vCPU guest
with 4 queues that adds latency jitter for everything else scheduled on that
CPU. Raising `netdev_budget` is reasonable; `budget_usecs` at 4000 would be a
more balanced pairing.

## A.7 Two systems own the same sysctls

```
/etc/tuned/active_profile: network-throughput
```

`set system option performance network-throughput` activates a tuned profile
that sets `net.core.rmem_max`, `wmem_max` and the `tcp_*mem` triples — the same
knobs the explicit `system sysctl parameter` lines set. Right now VyOS's sysctl
wins (`rmem_max` is 26214400, not tuned's 16 MB), so the outcome is fine, but
the ownership is ambiguous and load-order dependent. Pick one.

## A.8 The k8s DNS stub points at an unroutable address

```
set service dns forwarding domain k8s.linds.com.au name-server 10.96.0.10
```

`10.96.0.10` is the CoreDNS **ClusterIP**. It is not in the routing table:

```
$ ip route get 10.96.0.10
10.96.0.10 via 1.159.127.254 dev eth2      ← out the WAN
$ show ip route 10.96.0.12
% Network not in table
```

Cilium advertises the pod CIDRs (`10.244.x`) and the LB range (`172.16.1.x`)
over BGP, but not the service CIDR. So every `k8s.linds.com.au` query is sent
to the internet, where it dies. The recursor's counters agree:

```
outgoing-timeouts  14196
servfail-answers   14414
unreachables        2233
```

Those numbers track each other almost exactly. Also a small outbound leak of
internal query names.

Point the stub at something reachable — a CoreDNS Service of type LoadBalancer
in `172.16.1.0/24`, which *is* advertised — or drop the stub.

The `K8S-SVC` prefix-list (`10.96.0.0/12`) already exists for this, but it is
only referenced by `RM-EXPORT-IPSEC`, which is attached to nothing (see P3).

## A.9 DNS cache is sized 7000× larger than it uses

```
set service dns forwarding cache-size '1000000'
```

```
cache-entries       142          negcache-entries  45
cache-hits       52254          cache-misses    623704     →  7.7 % hit rate
packetcache-hits 102687          misses          675961     → 13 % hit rate
nxdomain-answers 181384          of 764k total   → 24 % NXDOMAIN
```

Allocation is lazy so the oversize is harmless, but a 7.7 % hit rate on a
caching resolver is worth a look. The 24 % NXDOMAIN share and the servfail
count from A.8 are the obvious contributors — fixing the k8s stub should move
this on its own.

## A.10 IPsec: PFS is off, and the fallback proposals offer SHA-1 and null encryption

The negotiated SA is strong:

```
LINDS-vti: INSTALLED, TUNNEL, ESP:AES_GCM_16-256
```

Proposal 1 wins in practice. But look at the full offer strongSwan sends:

```
proposals = aes256gcm128-sha256-modp2048-noesn,
            aes256gcm128-sha256-modp2048,
            aes256-sha1-modp2048-noesn,        ← SHA-1
            aes256-sha1-modp2048,              ← SHA-1
            aes256ccm128-sha1-modp2048-noesn,  ← SHA-1
            aes256ccm128-sha1-modp2048,        ← SHA-1
            aes256gmac-sha1-modp2048-noesn,    ← GMAC = authentication only
            aes256gmac-sha1-modp2048           ← no confidentiality
```

Proposals 2–4 set no `hash`, so they inherit SHA-1. `aes256gmac` is
`ENCR_NULL_AUTH_AES_GMAC` — it authenticates without encrypting. Both ends are
yours and proposal 1 always wins, so this is downgrade *surface* rather than an
active exposure, but proposals 2–4 buy nothing against a peer you control:

```
delete vpn ipsec ike-group MyIKEGroup proposal 2
delete vpn ipsec ike-group MyIKEGroup proposal 3
delete vpn ipsec ike-group MyIKEGroup proposal 4
```

Two more, both needing the far end changed in step:

- **PFS is disabled** on both ESP groups. The child SAs carry no DH group
  (`aes256gcm128-sha1-noesn` — no `modp`), so a compromise of the IKE keying
  material exposes past and future child SAs. `set vpn ipsec esp-group
  MyESPGroup pfs enable`.
- **DH group 14 (modp2048) only.** Group 19 (ECP-256) is both faster and
  stronger, and pfSense and VyOS have supported it for years. Add it as
  proposal 1's `dh-group 19` and keep 14 as the fallback during cutover.

## A.11 `broadcast-ping enable` makes the router an on-LAN amplifier

```
set firewall global-options broadcast-ping 'enable'
→ net.ipv4.icmp_echo_ignore_broadcasts = 0
```

The router answers ICMP echo sent to broadcast addresses, so a single spoofed
packet draws a reply — the classic smurf pattern. Confined to the LAN and
largely historical, but there is no reason to leave it on. Default is disable.
`all-ping enable` is fine and is what input rule 51 relies on.

## A.12 `accept_ra = 2` on the LAN interface

```
net.ipv6.conf.eth1.accept_ra = 2      ← LAN
net.ipv6.conf.eth2.accept_ra = 2      ← WAN, correct
```

`set interfaces ethernet eth1 ipv6 address autoconf` forces this. But eth1 is
where *this router* sends RAs (`service router-advert interface eth1`) — it
should not also be listening to them. A rogue or misconfigured RA source on the
LAN could install a default route on the router.

Addressing on eth1 comes from `dhcpv6-options pd 0 interface eth1 sla-id 0`, so
`autoconf` is not doing anything useful:

```
delete interfaces ethernet eth1 ipv6 address autoconf
```

## A.13 Conntrack established timeout is aggressive

```
net.netfilter.nf_conntrack_tcp_timeout_established = 3600     (1 hour)
```

The 5-day kernel default is far too long, so trimming it is right. But 1 hour
applies to **forwarded** flows, and clients that idle longer — SSH sessions,
RDP, IMAP — lose their conntrack entry and the connection breaks. The
`tcp_keepalive_*` settings do not help here; they govern the router's own
sockets, not transit traffic.

Current table usage is 650 of 262144, so there is no pressure justifying it.
7200–86400 would be safer.

## A.14 Things that are correct and worth keeping

- **MSS clamping** (`clamp-mss-to-pmtu`) on WAN, LAN and both VTIs — correct,
  and what keeps the tunnels working despite the reduced MTUs.
- **Tunnel MTUs** — vti0 1436, vti10 1400, wg 1420. vti0 is tight for
  AES-GCM-256 but has ~64 bytes of headroom without NAT-T, and MSS clamping
  covers TCP regardless.
- **`source-validation loose`** — the right choice for asymmetric dual-WAN;
  `strict` would break the failover path.
- **`disable-flow-control` on eth2** — correct for a router; 802.3x pause
  frames cause head-of-line blocking.
- **`interrupt-coalescing adaptive-rx/tx` + `cqe-mode-rx/tx`** — well-matched to
  the ConnectX-4 Lx VF, and mlx5 supports all four.
- **4 virtio queues against 4 vCPUs** on eth1 — correctly matched.
- **`protocols failover` design** — health-checking only the primary, with the
  check targets pinned out that interface via /32 statics, is genuinely good.
  The reasoning in the role comments is sound.
- **`disable-mitigations`** — consistent with the matching CPU flags on the
  Proxmox side. A deliberate, coherent tradeoff.
- **`ip_local_port_range 10240 65535`** — fine.

## A.15 Suggested order

Highest value first, and independent of each other:

1. **A.1** — IPv6 firewall. Everything else is a rounding error next to this.
2. **A.8** — k8s DNS stub; removes ~14k timeouts and the query leak.
3. **A.5, A.4, A.3** — drop `rmem_default`/`wmem_default`, `tcp_timestamps`,
   `tcp_low_latency`. Three deletes, no behaviour risk.
4. **A.10** — IPsec proposals 2–4. Needs a maintenance window on both ends.
5. **A.11, A.12, A.13, A.6** — small correctness cleanups.
