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
2. **Every UniFi switch and AP at the JD site is cut off from the UniFi
   controller** by the VLAN 52 isolation policy.
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

### 1.4 UniFi gear cannot reach the UniFi controller

The controller lives at `10.0.80.4` (LINDS VLAN 80). From the router it is
perfectly reachable — 14 ms over the IPsec tunnel, 8080 and 8443 both open.

But every UniFi device sits in VLAN 52, and forward rule 100 drops
`10.0.52.0/24 → LAN-Addresses`, which contains `10.0.80.0/24`:

```
100  drop  91704 packets  5581348 bytes   ip daddr @N_LAN-Addresses ip saddr 10.0.52.0/24
```

Confirmed by conntrack: there is **not one flow** from any `10.0.52.x` device to
`10.0.80.4`. The devices are falling back to Ubiquiti's cloud (`10.0.52.2` holds
an MQTT session to `54.69.74.211:8883`).

Affected: `uswenterprise24poe` (.3), `uswenterprise8poe` (.7), APs at .10/.11,
and the cameras.

```
set firewall ipv4 forward filter rule 95 action accept
set firewall ipv4 forward filter rule 95 source address 10.0.52.0/24
set firewall ipv4 forward filter rule 95 destination address 10.0.80.4
set firewall ipv4 forward filter rule 95 description 'UniFi devices → controller'
```

Rule 95 lands ahead of the rule-100 drop. Narrow it further with
`destination port 8080,8443,6789,10001` if you want least privilege.

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

Beyond 1.4 (the controller being unreachable) and 2.7 (LLDP):

**No mDNS repeater.** The router sees mDNS (`224.0.0.251`) and SSDP
(`239.255.255.250`) groups on `eth1` only. Cameras and APs are in VLAN 52,
clients in VLAN 50, so AirPlay, Chromecast, printer and Sonos discovery cannot
cross. VyOS has the node:

```
set service mdns repeater interface eth1
set service mdns repeater interface eth1.52
```

(Requires the firewall to permit the answering traffic, so pair it with 1.4.)

**L3 adoption has no discovery path.** With the controller across the IPsec
tunnel, devices cannot find it by broadcast. This VyOS build has **no**
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
