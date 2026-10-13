# router role

Builds the Debian 13 routers from plain config files: **jd-router-01**, which
replaced jd-vyos-01 on 2026-09-06, and **linds-router-01**, which replaces
linds-vyos-01 ([its own section](#linds-router-01) has what it is, how it is
built beside VyOS and the cutover). The VMs come from LINDS-Terraform
(`proxmox/vms-jd-router.tf`, `proxmox/vms-linds-router.tf`: Debian
genericcloud image, a management NIC for the build, LAN and WAN NICs created
link-down); this role turns one into the router.

Most of this file was written about jd-router-01 and still reads that way.
Where it names an interface, an address or a VLAN without saying whose, it is
JD's; where LINDS differs, the LINDS section says so.

## Layout — where things live

| What | Where |
|---|---|
| A daemon config that is one site's, as the file it is on the box | `files/<site>/etc/…`: `files/jd/etc/`, `files/linds/etc/` (below that, the path on the box: `files/jd/etc/nftables.conf` → `/etc/nftables.conf`) |
| What every router gets unchanged | `files/etc/…`: sysctl, kernel modules, chrony, lldpd, FRR's `daemons`, Suricata, rsyslog, apt and unattended-upgrades, journald, the unit files |
| The failover daemon, the WireGuard endpoint re-resolver, miniupnpd's table script | `files/usr/local/sbin/`, unit files in `files/etc/systemd/system/` |
| The few rendered files (they carry vault secrets) | `templates/`: WireGuard `.netdev` (peer endpoint + key), `swanctl/conf.d/secrets.conf` (EAP users), `ddclient.conf` (Cloudflare token), `wg-reresolve/*.conf` |
| Certificates / keys | rendered from the vault by `tasks/ipsec.yml` (VyOS's bare-base64 PKI blobs, wrapped as PEM by `filter_plugins/router_filters.py`) |
| Secrets | `inventory/router.yml` (copied from `inventory/vyos.yml`, same vault password) |
| What a site is: its name, which optional parts it has, its tunnels, what the validator expects | `inventory/group_vars/jd_router.yml`, `inventory/group_vars/linds_router.yml` |
| Task flow | `tasks/main.yml` → one task file per area, in dependency order |
| Failover daemon tests | `tests/` — `python3 -m unittest discover -s roles/router/tests` |
| What the LINDS ruleset does to packets, in throwaway network namespaces | `tests/linds-ruleset-netns.sh` — `sudo unshare -n bash roles/router/tests/linds-ruleset-netns.sh roles/router/files/linds/etc/nftables.conf` |
| The swap from VyOS at LINDS, as a script for the hypervisor | `cutover/linds-router-cutover` (not installed by the role) |

To change something, **edit the file under `files/<site>/etc/` (or
`files/etc/` if every router should get it) and run the playbook for that
router**. Hand edits on the box are fine for experiments; `--check --diff`
shows exactly what the role would put back.

## One role, two sites

`router_site` (`jd`, `linds`; set in the site's group_vars) names the
directory under `files/` that holds the site's own files. A task names such a
file as `files/<router_site>/…` and nothing else: there is no falling back to
another site's copy, so a site that lacks a file fails at that task, and the
play refuses to start for a host without `router_site`. A router given
another site's DHCP ranges would be worse than a failed run.

The split is by one question: would the file be the same on the other
router? If so it is under `files/etc/` and changing it changes both. The
per-site ones are the networkd files, `nftables.conf`, `frr.conf`, the two
kea files, `recursor.yml`, `swanctl.conf` and `strongswan.d/router.conf`,
`snmpd.conf`, the sshd drop-in, `miniupnpd.conf`, `avahi-daemon.conf`,
`nic-tuning.service`, `resolv.conf`, and at JD `wan-failover.json`.

What only some sites have is switched in group_vars:

| Variable | Default | JD | LINDS | What it is |
|---|---|---|---|---|
| `router_upnp` | on | on | on | miniupnpd: UPnP IGD + NAT-PMP/PCP for the main LAN |
| `router_mdns` | on | on | on | avahi as an mDNS reflector between VLANs |
| `router_suricata` | on | on | on | Suricata on the LAN trunk, EVE to Loki |
| `router_failover` | off | on | off | `wan-failover`: needs a second WAN. Without it the default route is the one in the WAN's DHCP lease |
| `router_road_warrior` | off | on | off | IKEv2 remote access: its server certificate, the EAP users, `ipsec10` |

A part that is off is not installed. Turning one off on a router that has
it does not uninstall it, with one exception: the remote-access certificate,
its key and the EAP users are removed, because the credential directories
are pruned to what the site should hold.

Two things to know about files that existed before the split (2026-10):

* **Their first line still gives the old path** (`roles/router/files/etc/…`
  for what is now `files/jd/etc/…`). The files were moved without a byte
  changed so that nothing on jd-router-01 changed with them. Correcting the
  line is a content change like any other: every daemon is restarted, a
  changed `.netdev` gets its interface deleted and recreated, and a changed
  `.link` reboots the box. Do it in an upgrade run (`-e
  router_apt_upgrade=true`), which reboots anyway.
* **The WireGuard `.netdev` files and keys are written by `wireguard.yml`**,
  not `network.yml`, so `--tags wireguard` is the tag for a tunnel change.
  They were moved behind `firewall.yml` because a tunnel starts handshaking
  the moment its netdev exists: on a router still being built that would be
  out of the management NIC, through the router it is about to replace, with
  that router's key.

## Running it

Name the router. Without `--limit` the play does both, one after the other
(`serial: 1`), and stops if the first fails.

```sh
ansible-playbook playbooks/router.yml --limit jd-router-01 --check --diff   # what would change
ansible-playbook playbooks/router.yml --limit jd-router-01                  # apply
ansible-playbook playbooks/router.yml --limit jd-router-01 --tags firewall  # one area (plus the validators)
ansible-playbook playbooks/router.yml --limit jd-router-01 -e router_apt_upgrade=true   # upgrade run
```

A normal run **upgrades nothing and cannot reboot the box**: it installs
missing packages and pushes config. `apt full-upgrade`, a newer backports
kernel and the reboot that follows it happen only in an upgrade run
(`router_apt_upgrade`, off by default). Every task file has a tag of its own
name (`packages`, `system`, `network`, `tuning`, `firewall`, `upnp`, `mdns`,
`logging`, `dns`, `dhcp`, `services`, `ipsec`, `wireguard`, `routing`,
`failover`, `suricata`); `validate` is tagged `always`.

A run ends in `tasks/validate.yml`: every daemon's own config checker
(`nft -c`, `vtysh -C`, `kea-dhcp4 -t`, `suricata -T`, `sshd -t`,
`swanctl --list-conns`, `rec_control ping`), an interface check against
`router_expected_interfaces`, and `systemctl --failed` must be empty. A green
run is a box that would route the moment its links come up.

## What each piece is

The daemons are the same on both routers; the config paths below are relative
to `files/jd/` or `files/linds/` unless the file is a shared one (see the
layout above), and the notes are JD's.

| Area | Daemon | Config | Notes |
|---|---|---|---|
| Interfaces, VLANs, WAN DHCP/PD, RA, WireGuard, XFRM | systemd-networkd | `etc/systemd/network/` | `.link` names NICs by MAC (`mgmt0`/`lan0`/`wan0`); the WAN keeps its lease through renews (`KeepConfiguration=dhcp`); PD `/56` → `lan0` (sla 0) and `lan0.52` (sla 1) |
| Firewall + NAT | nftables | `etc/nftables.conf` | One `inet` table, rule comments carry the VyOS rule numbers; the `output` chain has the build-time mgmt guard |
| Static + BGP | FRR (`bgpd`, `staticd`), from deb.frrouting.org | `etc/frr/frr.conf` | Same dialect as VyOS's `protocols`; `systemctl reload frr` diffs |
| Dual-WAN failover | `wan-failover` | `etc/wan-failover.json` | Per-WAN default in tables 1001/1002 for the health check (90/100 are the WireGuard tunnels'); hysteresis; carrier check; SNAT conntrack flush on switch |
| IPsec | strongSwan (swanctl) | `etc/swanctl/swanctl.conf` | `LINDS` site-to-site over `ipsec0`, `LINDS_MOBILE` road-warrior over `ipsec10`; `encap = yes` is a line here, not a template patch |
| DHCP | Kea, from ISC's repository (services `isc-kea-dhcp4-server`, `isc-kea-dhcp-ddns-server`) | `etc/kea/` | DDNS into AD DNS |
| DNS forwarder | pdns-recursor, from repo.powerdns.com | `etc/powerdns/recursor.yml` | Upstream Quad9 (over DNS over TLS at JD), 15-minute cache floor: see below |
| NTP / SNMP / LLDP / DDNS | chrony, snmpd, lldpd (from its author's OBS repository), ddclient | `etc/chrony/`, `etc/snmp/`, `etc/default/` | |
| mDNS reflector | avahi-daemon | `etc/avahi/avahi-daemon.conf` | Repeats mDNS between `lan0`, `lan0.52` and `lan0.58` so devices on one can be found from the others; publishes nothing itself |
| IDS | Suricata 8 + suricata-update, from trixie-backports | `etc/suricata/` | One worker thread on `lan0`; WAN traffic and DNS only (BPF filter); TLS flows bypassed after the handshake; EVE → rsyslog imfile → Alloy → Loki; weekly rule refresh reloads in place |
| Kernel | linux-image-cloud-amd64 from trixie-backports (7.x, `router_kernel_backports`), sysctl, modules, grub, tuned | `etc/sysctl.d/`, `etc/modules-load.d/`, `etc/default/grub.d/` | `ignore_routes_with_linkdown` keeps a link-down build reachable; `ip_nonlocal_bind` lets daemons bind `.1` addresses before the LAN link is up |

## Conventions and sharp edges

* **The role prunes.** `/etc/systemd/network` and the swanctl credential
  directories are made to match the role exactly — delete a file from
  `files/etc/systemd/network/` and the interface is gone on the next run.
* **A changed `.link` file or a kernel package change means a reboot** (the
  run does it). The kernel is the cloud flavour from trixie-backports
  (`router_kernel_backports: true`); stable's 6.12 stays installed as a
  fallback GRUB entry. The kernel package only changes in an upgrade run
  (`-e router_apt_upgrade=true`) or on a first build. Until 2026-10 it was
  `state: latest` on every run, so any run could reboot the router, and
  while backports sat between a `linux` upload and its `linux-signed-amd64`
  one (the meta-package is uninstallable for those days) every run died at
  that task before reaching any config. An upgrade run still fails in that
  window; wait and run it again. Anything else
  reloads in place; a changed `.netdev` is deleted and recreated.
* **Some packages are newer than Debian 13's.** The role takes them from
  two more sources, and it uses Debian 13 for all other packages:

  | Package | Source | Why |
  | --- | --- | --- |
  | `linux-image-cloud-amd64` | trixie-backports (`router_kernel_backports`) | Kernel 7.x, not 6.12 |
  | `suricata`, `suricata-update` | trixie-backports, pinned in `etc/apt/preferences.d/router-backports.pref` | Suricata 8, not 7.0 |
  | `wireguard-tools`, `mtr-tiny` | trixie-backports, same pin | Newer `wg` and `mtr` |
  | `frr`, `frr-pythontools` | `deb.frrouting.org`, component `frr-stable` | The newest FRR release, not 10.3 |
  | `isc-kea-dhcp4`, `isc-kea-dhcp-ddns`, `isc-kea-hooks` | ISC's `kea-3-2` repository on Cloudsmith | Kea 3.2, not 2.6 |
  | `pdns-recursor` | `repo.powerdns.com`, suite `trixie-rec-54` | Recursor 5.4, not 5.2 |
  | `lldpd` | openSUSE Build Service, `home:vbernat` (the lldpd author) | 1.0.22, not 1.0.18 |

  The signing keys are in `files/etc/apt/keyrings/`. A new key needs a
  commit. The `lldpd-obs.asc` key expires on 2027-01-05. `frr-stable`
  moves to the next major release when FRR makes one, and an upgrade run
  then installs it: read the FRR release notes before the run. ISC and
  PowerDNS make one repository for each stable series. To move to the next
  series, change the name in `isc-kea.sources` or
  `powerdns-recursor.sources`. strongSwan, nftables and iproute2 stay on
  Debian 13: no newer package exists for Debian 13.
* **ISC's Kea replaces Debian's.** The packages and the services have
  different names (`isc-kea-dhcp4-server`, not `kea-dhcp4-server`). The
  binaries, `/etc/kea`, `/var/lib/kea` and the `_kea` user are the same.
  The role purges Debian's Kea packages, because their AppArmor profiles
  name the same binaries. Kea 3 accepts control sockets only under
  `/var/run/kea`.
* **`systemctl reload frr` can attach a new route-map before it exists.**
  frr-reload adds the `neighbor ... route-map NAME in` line before the
  `route-map NAME` lines, and FRR denies everything through a route-map that
  does not exist until its route-map timer (5 s) runs. On 2026-10-20 the
  cluster peers showed 0 prefixes for those seconds, and the routes came by
  LINDS. To add an inbound route-map to a live box, make the route-map first
  in `vtysh` (`conf t`), wait 6 s, then attach it. A boot or a restart is
  not affected: the whole file is loaded before the sessions come up.
* **nftables is validated before install** (`nft -c`), as are the kea files.
  FRR and Suricata are validated after the daemons are up, in `validate.yml`.
* **No `ConfigureWithoutCarrier` on the LAN side.** With it, `10.0.53.1` would
  exist on the link-down `lan0.53` during the build, and the kernel would
  discard VyOS's ARP requests on VLAN 53 as martian-source (they come from
  what is then a local address) — the management leg goes dark. Addresses
  appear with carrier; daemons bind ahead of that via `ip_nonlocal_bind`.
* **The firewall replaces its own table, not the ruleset.** `nftables.conf`
  starts with `table inet router` / `delete table inet router`, so a reload
  leaves `table inet miniupnpd` (the UPnP/NAT-PMP pinholes) alone. Do not
  put `flush ruleset` back.
* **miniupnpd runs with our table setup, not Debian's.** Its packaged
  `nft_init.sh` would add a second forward base chain with policy DROP.
  `/etc/default/miniupnpd` points the start/stop hooks at
  `/usr/local/sbin/miniupnpd-nft` instead; the unit is masked while the
  package installs so the first start never sees Debian's defaults. UPnP
  is main-LAN only, `secure_mode` (clients map only to themselves), IPv6
  pinholes off until a v6 forward filter exists.
* **mDNS is repeated between the main LAN, VLAN 52 and VLAN 58** (avahi as
  a reflector, since 2026-10-09). mDNS never crosses a router, so a phone on
  the main LAN could not find the Shield on VLAN 58 (it was missing from the
  YouTube app's cast list) although every cast port on it was reachable from
  there. avahi repeats each question and answer heard on one of `lan0`,
  `lan0.52`, `lan0.58` onto the other two and does nothing else: it publishes
  nothing of its own, `allow-interfaces` keeps it off the WANs and VLAN 53,
  and it is IPv4 only. Input rule 15 admits the multicast group on those
  three interfaces, ahead of rule 2, so mDNS is now the second thing (after
  DHCP) that VLAN 52 may send the router.
  * It makes a device findable, not reachable. Who may connect to whom is
    still the forward chain: VLAN 52 only answers what the LAN started
    (rules 99/100), VLAN 58 is not restricted.
  * It does not carry SSDP (the HEOS app, DLNA): that is 239.255.255.250 and
    would need a relay of its own.
  * A question sent from a port other than 5353 (mDNS calls it legacy
    unicast; one-shot lookup tools do it) is not carried across: its answers
    come back by unicast to a random port on the router, which the input
    chain does not admit. Phones, browsers and the cast and AirPlay stacks
    ask from 5353.
  * Every one of the three networks now sees the service names of the other
    two. `reflect-filters=` in the config can narrow that.
  * The cache is left on: a repeated question is answered from it while the
    device itself stays silent (the config file says how). No recommends at
    install, so libnss-mdns stays out of `/etc/nsswitch.conf`.
  * Check: `journalctl -u avahi-daemon` has "Joining mDNS multicast group"
    for exactly those three interfaces; `tcpdump -ni lan0.58 udp port 5353`
    shows the router's repeats coming from 10.0.58.1; a browse for
    `_googlecast._tcp.local` from a LAN host is answered from 10.0.50.1.
    Proven both ways on 2026-10-09: the Shield found and connected to from
    a LAN host, and a test announcement sent from an access point on VLAN 52
    heard by a LAN host and seen leaving the office access point's Wi-Fi
    interface.
* **The IoT devices live on VLAN 52 with fixed addresses** (reservations in
  `kea-dhcp4.conf`, 10.0.52.230 and up, above the pool; Home Assistant is
  configured with them). VLAN 52 may not open a connection to a private
  address (forward rules 99/100). That suits devices that are only polled:
  Home Assistant, hostNetwork on a cluster node, starts every exchange with
  the inverter, the battery, the IR remote and the vacuum. The aircons are
  the exception and have forward rule 98: they answer ECHONET Lite to port
  3610 from a port of their own, which conntrack counts as a new flow from
  VLAN 52 rather than a reply. A device that has to reach something private
  itself needs a rule of its own next to it. Being found from the main LAN
  is the reflector's job (above).
  * Kea answers a VLAN 52 client once. Kea 2.6 also offered it a 10.0.50.x
    address, because its raw socket on `lan0` saw the tagged frames (ISC
    issue #3792, fixed in Kea 3.1.7). If a 10.0.50.x offer shows up next to
    a 10.0.52.x one again, it went out untagged and never reached the client.
* **Software flowtable, main LAN, VLAN 52 and VLAN 53 <-> WAN.** The last
  six forward rules hand established TCP/UDP flows between `lan0`, `lan0.52`,
  `lan0.53` and `wan0` to `flowtable ft`; later packets skip the ruleset. `conntrack -L |
  grep -c OFFLOAD` shows how many. Tunnels are excluded (xfrm and WireGuard
  cannot be software-offloaded). Capture pitfall: the flowtable's ingress
  hook on the parent `lan0` handles tagged frames itself, so an offloaded
  VLAN flow never appears in a `tcpdump -i lan0.52`; use `tcpdump -i lan0 -e
  vlan 52` instead. A capture on `lan0.52` during the 2026-09-06 UniFi
  console outage was read as "return direction lost", which was this
  artefact. When adding another VLAN, prove both directions the same way.
* **A private destination never leaves through a WAN.** LINDS, the k8s
  VIPs and the pod and service ranges exist only as BGP routes; with a
  session or the tunnel down they fell through to the default route and went
  to the ISP, masqueraded by the catch-all rule (about six minutes at every
  boot, and any port forward whose VIP is not advertised). The `forward` and
  `output` chains now reject RFC 1918 destinations leaving by `wan0`, and by
  `lan0.99` except the modem's own 192.168.0.0/24: LAN hosts get "network
  unreachable" at once, and the router's own daemons retry instead of
  holding a session sourced from the WAN address (rsyslog did, and Loki
  labelled the router's logs with the ISP's reverse DNS name). This is
  deliberately not three reject routes in `frr.conf`: an unreachable route
  also fails the loose reverse-path check for every packet arriving *from*
  those ranges without a more specific route. Check:
  `ping 10.99.99.99` from a LAN host answers "Destination Net Unreachable"
  from 10.0.50.1.
* **The journal carries events, not heartbeats.** Measured 2026-10-05: 424
  entries an hour, nearly all of them routine, and journald writing 2.6 GiB a
  day to store about 2 MB of text. What was turned down:
  `wg-reresolve@.service` has `LogLevelMax=notice` (systemd's
  start/finish lines for a unit that runs every minute); kea-dhcp4 logs at
  WARN except its `leases` logger, so one `DHCP4_LEASE_ALLOC` line per
  lease and no per-packet lines; kea-dhcp-ddns logs at WARN (failed updates
  still show); pdns-recursor's half-hourly statistics report is off
  (`rec_control get-all` has the numbers); the apt timers no longer wait for
  a network-online that cannot arrive and log a timeout as an error; and
  packets addressed to 127/8 from the wire are dropped in `prerouting_raw`
  before the kernel can log each as a martian (`log_martians` stays on for
  the rest). One consequence had to be handled too: Alloy closes a syslog
  session that has been idle for two minutes, which the quieter stream now
  often is, and rsyslog announced every reconnect in five lines.
  `rsyslog.d/50-remote.conf` keeps its own messages to errors
  (`internalmsg.severity`) and logs that one error once per thousand
  (`ConErrSkip`); the reconnect itself loses nothing. To see a DHCP exchange in full, set the `kea-dhcp4` logger back
  to INFO and `config-reload` over the control socket.
* **ECMP hashes the 5-tuple.** `fib_multipath_hash_policy=1` (v4 and v6)
  in sysctl.d, so flows from one client spread across the five Talos
  next-hops of a service VIP instead of all landing on one node.
* **Upstream DNS decides where browsers connect, not just how fast a name
  resolves.** The catch-all forwarder was Cloudflare until 2026-10-07. It
  answers quickly, but it does not pass the client subnet on, and Google's
  and Microsoft's name servers then send clients somewhere 125-160 ms away
  much of the time: 30% of the answers LAN clients got in 30 h for
  Google-hosted names that can be served locally (fonts.gstatic.com,
  fonts.googleapis.com, i.ytimg.com, mail.google.com ...) pointed 128 ms
  away instead of 11 ms, and every connection to one then pays that round
  trip two or three times. Of the 300 names this LAN asks for most,
  Cloudflare's answer was over 50 ms away where Quad9's was under 25 ms for
  25 of 283 on IPv4 and 27 of 200 on IPv6 (the reverse: 1 and 0), the
  Microsoft 365 ones among them. Quad9 `9.9.9.9` (DNSSEC, blocks
  known-malicious names, one shared cache) answers as fast as Cloudflare:
  12 ms median, 28 ms at the 95th percentile, against 11 and 19. The
  isolated VLANs are handed it over DHCP as well.
  * Not the resolvers that pass the client subnet on (Quad9 `9.9.9.11`,
    Google): they map just as well, but cache per subnet, so names this
    network has not asked for lately are slow. `9.9.9.11` was tried first,
    for twenty minutes: 4.5% of lookups took over 100 ms.
  * Not Telstra's own: as fast and as well placed, but they rewrite the
    sites Australian ISPs are ordered to block.
  * If Quad9 refuses a name that is wanted, `9.9.9.10` / `149.112.112.10`
    is the same service without the block list (and without DNSSEC).
  * To re-check after changing upstream, resolve the busiest names in the
    DNS log through each candidate and time a TCP handshake to each answer.
    The measurements are in the comments of `recursor.yml`.
* **JD sends its upstream queries to Quad9 over DNS over TLS (DoT).** The
  forwarders in `jd/etc/powerdns/recursor.yml` use port 853, and the
  recursor uses TLS for port 853 (`dot_to_port_853`, on by default). The
  ISP cannot read the names that the router looks up. Clients do not
  change: they send plain DNS to the router on port 53. The LINDS file
  still uses plain DNS.
  * The recursor checks the certificate of the server
    (`outgoing.tls_configurations`: name `dns.quad9.net`, the system CA
    store). An attacker who intercepts the connection gets SERVFAIL, not
    answers. If Quad9 changes the name on its certificate, every name not in
    the cache fails: look for TLS errors in `journalctl -u pdns-recursor`.
  * On an open connection, a lookup takes the same time as on UDP. A new
    connection adds about 25-30 ms. The recursor and Quad9 both close an
    idle connection after about 10 s.
  * At this query rate, the recursor almost never reuses a connection.
    Each connection is idle for more than 10 s before the next query
    comes. Thus a lookup that misses the cache takes about 17 ms more:
    the median goes from 15 ms to 32 ms. The slow tail and the median
    wait of all lookups do not change.
  * One recursor thread and two forwarders would give more reuse. The
    role does not do this, because the cost above is acceptable.
  * The internal forwarders (`linds.com.au`, `k8s.linds.com.au`) stay on
    plain DNS, port 53.
  * DoT does not apply to VLAN 51 and VLAN 52. DHCP gives them Quad9
    directly, so they do not use the router for DNS.
  * To check: `rec_control get dot-outqueries` increases, and
    `ss -tn '( dport = :853 )'` shows connections to Quad9.
* **Names are cached for at least 15 minutes** (`minimum_ttl_override: 900`)
  and refreshed in the background once half that is used up
  (`refresh_on_ttl_perc: 50`). A lookup that misses the cache costs a client
  14 ms; with the old 60 s floor only 46% of the main LAN's lookups were
  answered from cache, because most names have short TTLs and a forwarder
  hands them over part-used. Replaying 30 h of real lookups: 58% at 900 s,
  68% at an hour. The price is that a site which changes address is followed
  up to 15 minutes late, and so is an internal record: after changing one,
  `rec_control wipe-cache NAME` (or `'linds.com.au$'` for the subtree).
  Answers without data (no AAAA, no HTTPS record, NXDOMAIN) are lifted too
  but stop at `max_negative_ttl`, 300 s. pdns-recursor cannot serve an
  expired answer while it refreshes (its serve-stale is for upstream failure
  only); a resolver that can, such as unbound with `serve-expired`, would
  reach about 92% on the same traffic.
* **IPv6 clients get DNS from the RA.** lan0's RA carries RDNSS =
  `_link_local` (fe80::be24:11ff:fe01:1101, EUI-64 of the pinned MAC);
  pdns-recursor listens on it and input rule 9 admits DNS to fe80::/10 from
  lan0. The GUA is not used because the ISP prefix changes. Recursor 5.x's
  YAML validator rejects `%lan0` (the daemon's own parser would take it),
  so recursor.yml uses `[addr%2]:53` with lan0's ifindex, and validate.yml
  asserts the index is still 2. A wrong index is not an outage: the bind
  succeeds via ip_nonlocal_bind and only IPv6 DNS goes quiet, IPv4 stays.
  `allow_from` must list `fe80::/10`: clients query a link-local listener
  from their link-local, and a source outside the list is dropped silently
  (`rec_control get unauthorized-udp` climbs).
* **Wi-Fi clients' IPv6 depends on which VLANs the access points' switch
  ports carry.** Nothing in this role, but this is where it shows. An
  access point bridges every VLAN its port hands it, tagged or not, through
  one bridge with multicast snooping on. Once that bridge hears an IGMP or
  MLD querier on any of them it stops flooding: an IPv6 group other than
  `ff02::1` reaches Wi-Fi only if a client there reported it in the last
  260 s. Wi-Fi clients report their solicited-node groups once, when they
  form the address, and do not answer queries (four queries, v1 and v2, 0 of
  7 clients). So four minutes after a device joins, lan0's neighbour
  solicitations no longer reach it, and once the router's entry lapses the
  device has no IPv6 until it happens to introduce itself again: every new
  connection tries IPv6, waits about 180 ms and falls back (one Mac went 40
  hours like that).
  The cellular modem on VLAN 99 is such a querier (IGMPv3 and MLDv2 every
  125 s), and the UniFi switches were another while IGMP snooping was on
  for the Default network. Since 2026-10-07 the two access point ports
  (24-port switch port 18, 8-port switch port 7) carry the untagged LAN and
  VLAN 52 only ("Tagged VLAN Management: Custom") and IGMP snooping is off
  on the Default network. Before: the router re-found a forgotten Wi-Fi
  address 0 times in 8. After: 16 in 16.
  It comes back if an access point lands on a port left at "Allow All", or
  IGMP snooping is turned on for the main LAN.
  * Look: `Icmp6OutDestUnreachs` in `/proc/net/dev_snmp6/wan0` (about 16 an
    hour when it works, about 1,600 when it does not).
  * Test, with a Wi-Fi device that is awake:
    `ip -6 neigh del ADDR dev lan0; ping -6 -c1 ADDR; ip -6 neigh show ADDR`
    must end REACHABLE.
  * By hand meanwhile: `ip -6 neigh replace ADDR lladdr MAC dev lan0 nud stale`.
* **Security updates apply unattended.** unattended-upgrades with the two
  Debian-Security origins only, 04:00 local (+0-30 min) via a timer
  drop-in, never an automatic reboot; needrestart restarts touched daemons
  in that run, so an OpenSSL fix costs a BGP and an IPsec reconvergence.
  needrestart's stock config never restarts `frr` or `strongswan` by itself;
  `needrestart/conf.d/50-router.conf` overrides both, and the override keys
  must be spelled exactly like the stock ones (they are regexes used as hash
  keys). The package itself was missing from the role until 2026-10, so
  before that nothing was restarted at all. `needrestart -b` lists what is
  running on replaced libraries. The backports packages and FRR are not
  security origins. They only move through an upgrade run of this role.
  `journalctl -t unattended-upgrade` and
  `/var/log/unattended-upgrades/` show what happened; `unattended-upgrade
  --dry-run -d` previews.
* **Suricata no longer disables offloads on lan0.** The switch is the
  top-level `capture: disable-offloading: false`; the same key inside the
  af-packet interface block is ignored, and with it Suricata turned sg, TSO,
  GSO and GRO off on lan0 every start (after rule loading, so a check a few
  seconds after a restart still shows them on). `nic-tuning.service` sets
  the VF rx ring to 8192, enables UDP GRO forwarding on both NICs and
  re-asserts lan0's offloads (`sg` before `tso`, which needs it). irqbalance
  spreads the queues. All of it is ethtool, none of it is expressible in
  `.link` files. `ethtool -k lan0 | grep -E "^(scatter|tcp-seg|generic)"`
  must show four `on`s.
* **Hardware GRO is on for lan0 at JD** (`GenericReceiveOffloadHardware=yes`
  in `files/jd/etc/systemd/network/10-lan0.link`). The host then gives
  `lan0` TCP packets of up to 64 KB. If it is off, the host cuts each packet
  into 1500-byte frames before the router gets it. One flow between two
  VLANs then gets about 330 MB/s instead of 1.5 GB/s. This matters most for
  SMB between the cluster (VLAN 53) and `jd-fs-01` (main LAN). The kernel
  turns LRO off on a router, but it keeps this offload, because virtio-net
  reports it as `rx-gro-hw`. Check: `ethtool -k lan0 | grep rx-gro-hw` shows
  `on`, and on the host `ethtool -k tap1101i0` shows
  `tcp-segmentation-offload: on`. The Suricata ring (tpacket v3, below)
  captures these packets whole.
* **Suricata runs `workers`, not `autofp`.** tpacket v3 only exists in the
  workers runmode; under autofp it silently fell back to v2, whose fixed
  frame size truncated every GRO super-packet at 1514 bytes
  (`decoder.ipv4.trunc_pkt` climbing, stream gaps). v3 with
  `block-size: 131072` captures them whole. The `bpf-filter` (below) cuts
  each packet to `default-packet-size`, so that is 65600, not the MTU
  default of 1514. `ring-size` counts frames of that size: 8192 frames are
  8193 blocks of 128 KB (1 GB). Do not use the old 65536 with 64 KB frames:
  that is 8 GB, and the ring mmap fails. Suricata raises `ring-size` to at
  least `max-pending-packets` (1024). `detect.profile: high` uses about the
  same memory as `medium` with this ruleset. Check with
  `suricatasc -c dump-counters` → `trunc_pkt` flat, `max_pkt_size` well
  above 1514.
* **Suricata: one worker thread.** The tap is on the trunk parent, so every
  inter-VLAN packet appears twice (untagged and tagged). With two workers
  the fanout hash split the copies across threads (`pkt_on_wrong_thread`
  at 4%) and every LAN<->VLAN flow raised "Applayer Wrong direction first
  Data" and "3way handshake wrong seq" alerts. One worker sees everything
  in order; it idles at a few percent CPU today. If `capture.kernel_drops`
  ever climbs, the fix is not more workers on this capture layout.
* **Suricata inspects WAN traffic and DNS only.** The `bpf-filter` on
  `lan0` keeps a packet if one end is outside the private ranges, or if it
  is DNS. Traffic between two private addresses is not inspected: VLAN to
  VLAN, SMB from the cluster to `jd-fs-01`, and the tunnel to the other
  site. At JD that traffic was most of Suricata's load (2.9 of 3.1 TB in
  one day), and it caused all of the capture drops.
  * The capture stays on `lan0`. On `wan0`, NAT puts the router's address
    on every IPv4 packet, so an alert could not name the device.
  * DNS stays in because the router resolves names for the LAN. Only here
    does a lookup show the device that made it.
  * Each test is written twice in the filter. A frame that the router sends
    on a VLAN has its tag inside the frame, and `vlan` moves the offsets.
  * Limits: IPv6 between two VLANs passes the filter (global addresses look
    like WAN traffic). During a failover to the cellular modem, Suricata
    sees WAN traffic twice: before NAT and after NAT.
  * TLS flows are bypassed after the handshake
    (`encryption-handling: bypass`). In Suricata 7 this needs
    `stream.bypass: yes`, which also bypasses a TCP flow that passes the
    reassembly depth. `flow_bypassed.local_pkts` counts the bypassed
    packets.
  * The reassembly depth is 1 MiB for each direction of a session
    (`stream.reassembly.depth`). Keep the key in the file: without it,
    Suricata 7 has no limit, and a plain HTTP download at line rate keeps
    the worker at 100%. `tcp.stream_depth_reached` counts the sessions
    that reached it.
  * The EVE `tls` log is extended, and `quic` is logged too. Each `tls`
    event, and the `quic` event of each client hello, has the SNI. The
    `tls` events also have the TLS version and the JA3/JA3S hashes. The "Top TLS SNI" panel of the
    Suricata dashboard reads `tls_sni`. Rules that match on the SNI work
    with or without it, because the client hello is inspected before the
    bypass.
  * Check: `capture.kernel_packets` does not move during an SMB copy from
    the cluster, and `eve.json` still has `dns` and `tls` events.
* **Suricata's stream memory is not capped.** With no `stream:` section it
  ran on the compiled-in 256 MiB reassembly cap, which was full within hours
  of every start (`memcap_pressure` 99-100, `tcp.segment_memcap_drop` and
  `tcp.reassembly_gap` climbing): payload the detection engine never saw.
  `stream.memcap` and `stream.reassembly.memcap` are 0 (unlimited); the
  reassembly depth bounds each session, and `MemoryMax=4G` on the unit
  (`suricata.service.d/memory.conf`) is the backstop, so a runaway costs a
  Suricata restart rather than the router. `suricatasc -c 'memcap-show
  stream-reassembly'` says `unlimited`; watch `tcp.reassembly_memuse`.
* **EVE reaches Loki through rsyslog imfile, and logrotate truncates the
  file under it.** Debian's `logrotate.d/suricata` uses `copytruncate`, and
  imfile without `reopenOnTruncate` keeps its old offset: after the first
  weekly rotation (2026-09-13) the reader sat 6 GB into a file that never
  grew that large again, and the Grafana Suricata dashboard was empty for
  three weeks while everything looked healthy on the box. Fixed in
  `rsyslog.d/60-suricata-eve.conf` and proven with a forced rotation. If the
  dashboard is empty: `ss -tn state established '( dport = :1515 )'` should
  show two sessions, and `/var/spool/rsyslog/imfile-state:*` should hold an
  offset just below the size of `eve.json`.
* **IKE listens on IPv6 too.** Input rule 3 is family-agnostic and charon
  binds `[::]:500/4500`; ddclient keeps the AAAA record for
  `jd-pfsense.linds.com.au` current. Inside-tunnel IPv6 is still a future
  step (ULA pool). Because of that AAAA, an IPv4-only service must never be
  published on `dyn_host`: a dual-stack client prefers the AAAA, the router
  answers ICMPv6 on it, and the service traffic dies with nothing to fall
  back from. `dyn_host_v4` (`jd.linds.com.au`) is the A-only name to point
  those at — Valheim was the first, after players resolving
  `valheim.linds.com.au` through a CNAME at `dyn_host` got the AAAA and
  timed out while the owner, on internal DNS with no AAAA, could not
  reproduce it.
* **The site-to-site tunnel dials IPv4 at both ends.** JD dials
  `linds-pfsense.linds.com.au` and LINDS dials `jd.linds.com.au`
  (`dyn_host_v4`); both names have only an A record. LINDS must not dial
  `jd-pfsense.linds.com.au`: charon dials the first address the resolver
  returns, for that name the road warriors' AAAA, and JD's `LINDS`
  connection matches the peer by the address of `linds-pfsense`, which is
  IPv4 only. linds-vyos-01 dialled `jd-pfsense` until 2026-10-15; every
  attempt went over IPv6 and failed, so only JD ever brought the tunnel
  up. `ipsec0`'s MTU (1436) is sized for an IPv4 outer header as well: over
  IPv6 a full-size packet is about 12 bytes too big for the WAN, and TCP
  falls back on path MTU discovery.
* **After a WAN failover the tunnel follows the best path**
  (`prefer_best_path = yes` in jd's `strongswan.d/router.conf`). Without it
  charon keeps an SA on any path that still works: after the failover of
  2026-10-14 the `LINDS` SA stayed bound to the modem's 192.168.0.87 for a
  day and a half, its packets leaving by wan0 only because rule 200
  masqueraded them. The move is a MOBIKE path check, which tries every
  address the peer has advertised and keeps the first that answers, so it
  can land on IPv6 for as long as LINDS answers IKE over IPv6. linds-vyos-01
  does, and the test on 2026-10-15 moved the tunnel to IPv6. After a
  failover, `swanctl --list-sas --ike LINDS` should show IPv4 addresses; if
  it shows IPv6, `swanctl --terminate --ike LINDS` and JD dials again over
  IPv4 within a second.
* **LINDS refuses a new tunnel from the cellular backup.** linds-vyos-01
  accepts IKE only from `jd.linds.com.au` (the fixed line). It answers a
  dial from the cellular address with NO_PROPOSAL_CHOSEN, and charon does
  not retry that answer. An SA that already exists can move to the backup
  (MOBIKE, above), but a new one cannot start there. At boot the backup is
  the default route for the first ~15 s, so the first dial always fails.
  The trap dials again when traffic goes into `ipsec0`: FRR connects to
  10.255.0.2 every 10 s (`timers connect 10`), and after a failed dial the
  kernel waits `xfrm_acq_expires` (60 s, in jd's `strongswan.d/router.conf`;
  the default 165 s kept the tunnel down for 2 min 47 s after the boot on
  2026-10-20). So the tunnel comes back within about a minute of wan0 being
  the active WAN. To dial at once: `swanctl --initiate --child LINDS`.
* **Two `LINDS` SAs at once** happen when both ends dial at the same moment;
  a VyOS IPsec commit does that, since VyOS dials again on reload while JD's
  trap does too. While LINDS is still linds-vyos-01, never terminate one of
  them by id: on 2026-10-15 VyOS kept sending on the deleted one, and
  LINDS→JD traffic was lost for 75 seconds until the whole connection was
  terminated (`swanctl --terminate --ike LINDS`) and JD dialled again.
* **BGP import from the cluster is filtered** (`RM-K8S-IN` in jd's
  `frr.conf`): the pod CIDRs, the service range and the LoadBalancer pool
  (`K8S-PODS`, `K8S-SVC`, `K8S-EXT`), nothing else. The peer group accepts
  any host on 10.0.53.0/24 that speaks BGP as AS 64512, so without the
  filter such a host could announce any route, a default route too. All the
  cluster's routes were inside these lists when the filter went on
  (2026-10-20). If the LoadBalancer pool in LINDS-Terraform
  `proxmox/cilium.tf` changes, change `K8S-EXT` with it.
* **BGP export to LINDS carries the JD LANs** (`JD-LANS`: 10.0.50.0/24,
  10.0.53.0/24, VLAN 58's 10.0.58.0/24, and the road-warrior pool
  10.0.10.0/24 so LINDS can answer remote-access clients). VyOS sent LINDS
  everything: its `RM-EXPORT-IPSEC` was defined but applied to no neighbour.
  A JD network missing from `JD-LANS` gets no answer from LINDS, which sends
  the replies out its WAN. VLAN 58 was missing from 2026-09-06 to
  2026-10-16, and the Shield's Plex fell back to LINDS-Plex-01's public
  address through NordVPN. VLAN 51 (no hosts) is still not sent. FRR does
  not refresh a neighbour when a route-map changes: `vtysh -c 'clear ip bgp
  10.255.0.2 soft out'` after editing the export.
* **k8s export prefix-lists need `le 32`.** The Talos nodes advertise
  specific routes only (/24 pod CIDRs, /32 service and LoadBalancer IPs),
  never the aggregates the prefix-lists name (10.244.0.0/16, 10.96.0.0/12,
  172.16.1.0/24). Exact-match entries never fired, so LINDS learned no route
  back to the JD cluster and replies to JD pods were black-holed (radarr
  "failed to fetch", 2026-09-06). `le 32` makes them match the specifics.
  This bit despite matching VyOS's config verbatim, so the nodes' advertising
  must have changed at some point; verify with `show ip bgp neighbors
  10.255.0.2 advertised-routes`.
* **`DHCP=yes` on `wan0`, not `DHCP=ipv4`.** With `WithoutRA=solicit`
  networkd ignores the RA's request to start DHCPv6 (it assumes the client
  already started at link setup), and that start only happens when `DHCP=`
  includes ipv6. `ipv4` alone left the client created but never running: RA
  default route, no address, no delegated prefix. Found at cutover.
* **`no bgp ebgp-requires-policy` in `frr.conf`.** FRR's RFC 8212 default
  discards every eBGP update on a neighbour without a policy, so the k8s
  peers sat at `(Policy)` with 0 prefixes. VyOS emits the line unconditionally.
  After adding it, existing sessions need `clear ip bgp * soft in`.
* **LAN hosts may ping the router** (input rule 52). VyOS's input
  default-drop with ICMP accepted only on the WAN swallowed LAN pings to
  `10.0.50.1`; this is the one deliberate addition to the input chain.
* **The management NIC is gone.** VM 1101 was built through `mgmt0`
  (VLAN 53, 10.0.53.250); after cutover it was removed from Terraform along
  with the virtio WAN, so the LAN NIC is Proxmox `net0` and the WAN is the
  SR-IOV VF (`hostpci0`). The `output` chain's mgmt-guard rules reference an
  interface that no longer exists and are inert.
* **DHCP hostnames reach DNS via kea DDNS → AD**, not a hostfile: there is no
  `hostfile-update` equivalent, and the forwarder's `linds.com.au` stub asks
  AD anyway.
* **VLAN 52 gets its delegated /64 but no RA** — mirrors VyOS, which had
  `pd interface eth1.52` without a router-advert entry. Set `IPv6SendRA=yes`
  and `Announce=yes` in `30-lan0.52.network` to change that.
* **IPv6 input is drop-by-default** (ICMPv6, DHCPv6-client and IKE are
  allowed). VyOS accepted everything over v6. Forward is accept, as before.
* **Remote access:** `dpd_action = clear` (a responder never re-initiates to
  a road warrior), `unique = replace` (a reconnecting client evicts its own
  stale SA), `fragmentation = yes` (mandatory over v6). To go dual-stack, add
  a ULA pool — never one carved from the delegated prefix — and `::/0` to
  `local_ts`.

## Cutover of jd-router-01 (manual)

Done on 2026-09-06 and kept for reference; linds-router-01's is in its own
section below.

1. `qm shutdown 1100` — VyOS off. Nothing else has changed yet.
2. In LINDS-Terraform `proxmox/vms-jd-router.tf`: `net1`/`net2`
   `disconnected = false`, `net0` `disconnected = true`,
   `prevent_destroy = true`; `terraform apply -target=proxmox_virtual_environment_vm.jd_router`.
   (Or `qm set 1101 -net1 …,link_down=0 -net2 …,link_down=0 -net0 …,link_down=1`.)
3. `inventory/router.yml`: `ansible_host: 10.0.50.1`. Remove `10.0.53.250`
   from `files/etc/ssh/sshd_config.d/10-router.conf`. Run the playbook.
4. Watch: `journalctl -fu wan-failover` (default route installed within
   ~10 s of carrier), `swanctl --list-sas` (LINDS up), `vtysh -c 'show bgp summary'`
   (k8s peers + LINDS), `networkctl status wan0` (lease + PD),
   `ip -6 route` (v6 default from RA), `suricatasc -c dump-counters /var/run/suricata/suricata-command.socket | grep wrong_thread`.

**Rollback:** the reverse — links down, VyOS on. The VyOS VM stays intact
until this has run for a while.

## The WAN is the ConnectX-4 VF

Since 2026-09-06 `wan0` is VF 0 (`0000:c2:00.2`) of the ConnectX-4 Lx port
`ens5f0np0` on jd-proxmox-02, passed through as `hostpci0` (see
`proxmox/vms-jd-router.tf`), driven by `mlx5_core` in the guest. The host's
`sriov-wan-setup.service` creates the VF at boot with wan0's MAC
(`BC:24:11:01:11:02`, so `10-wan0.link` needed no change), `trust on`,
`spoofchk off`, bound to `vfio-pci`. The VyOS VM no longer has a `hostpci`
entry, so it cannot grab the VF if it is ever started.

Consequences: the VM is pinned to this host and vfio locks its memory;
`hostpci` changes need a cold start; the VF's queue count is what the
firmware gives (`ethtool -l wan0`: 4). The move also got a new ISP lease
(different v4 address and /56) despite the unchanged client-id, which is
why `retry_initiate_interval` exists in `strongswan.d/router.conf`: charon
initiated LINDS before the lease landed and would never have tried again.

**Back to virtio if needed:** drop the `hostpci` block, add a `net1`
`network_device` on `vmbr1` with the same MAC, cold start. Nothing in the
guest changes.

## linds-router-01

The router of the LINDS site: VM 114 on linds-proxmox-01
(`LINDS-Terraform/proxmox/vms-linds-router.tf`), replacing linds-vyos-01
(VM 101). Its files are `files/linds/`, its data
`inventory/group_vars/linds_router.yml`, and it gets everything under
`files/etc/` that jd-router-01 gets.

| Interface | What | Address |
|---|---|---|
| `lan0` | LAN trunk, untagged main LAN (VyOS `eth0`) | 192.168.6.1/24, and the first /64 of the delegated /56 |
| `lan0.36` | VLAN 36: leaves by NordVPN | 10.0.36.1/24 |
| `lan0.80` | VLAN 80: management | 10.0.80.1/24 |
| `lan0.110` | VLAN 110: cameras | 10.0.110.1/24 |
| `lan0.300` | VLAN 300: servers (Talos workers, Plex, TrueNAS, the DCs) | 10.3.1.1/24 |
| `wan0` | WAN (VyOS `eth1`) | DHCP, DHCPv6 + prefix delegation |
| `ipsec0` | site-to-site to JD (VyOS `vti0`), BGP to 10.255.0.1 | 10.255.0.2/30 |
| `wg101` | NordVPN, table 100 | 10.5.0.2/32 |

It was built through a fourth NIC, `mgmt0` on VLAN 300 (10.3.1.250), which
has been link-down at the hypervisor since the cutover. Its two networkd
files, its sshd listen address and its entry in `router_expected_interfaces`
were removed afterwards; "Building it" below describes the build as it was
done, and a rebuild beside a live router needs them back (the commit that
removed them shows what they were).

### What it has that linds-vyos-01 did not

Everything jd-router-01 has that does not need hardware this site lacks. The
sections above describe each; what is particular to LINDS:

* **UPnP IGD and NAT-PMP/PCP** for the main LAN (192.168.6.0/24), clients
  mapping ports to themselves only. Plex on VLAN 300 keeps its fixed forward
  (32400 → 10.3.1.20) in `nftables.conf`.
* **mDNS reflector** between the main LAN, VLAN 80 and VLAN 300
  (`avahi-daemon.conf`, input rule 15). Not VLAN 36, which is kept apart, and
  not VLAN 110, which had nothing on it on 2026-10-13. Adding a network is one
  name in each of those two files. The forward chain here accepts everything
  between the VLANs, so a device that is found can also be reached.
* **Suricata** on `lan0`, which as the trunk parent sees every VLAN. Its EVE
  events reach Loki under `job="suricata"` like JD's; the `hostname` label
  tells the two routers apart, and a Grafana panel that does not filter on
  it now shows both sites. The router's other logs arrive with
  `hostname="linds-router-01"`.
* **The flowtable fast path** for the main LAN and VLAN 300, to the WAN and
  to each other: the pairs JD offloads, on the same kernel. Nothing at this
  site needs it for speed; `nftables.conf` says how to switch it off while
  chasing a fault.
* **A private destination never leaves through the WAN**, DNS answers kept
  at least 15 minutes, security updates unattended at 04:00, and the tunnel
  re-initiating on its own (the trap policy), all as at JD.

What it does not have: a second WAN (`router_failover` is off, the default
route is the one in the DHCP lease), remote access for phones and laptops
(that terminates at JD), the SR-IOV WAN (both NICs are virtio), and DNS in
the router advertisement (the RA is as VyOS sent it; clients use the
resolver DHCPv4 hands them).

### Where it deliberately differs from linds-vyos-01

The port was made from the running config (`show configuration commands`,
FRR's and kea's generated files), not from `roles/vyos`, which had drifted
from the box. Everything that VyOS did and this router does differently:

* **The router no longer answers the internet.** VyOS's input chain was
  default-accept (its two rules, IKE and port 32400, therefore did nothing),
  so anything not bound to a LAN address was reachable from the WAN: NTP
  (`allow-client 0.0.0.0/0`) and BGP among them. Input here is default-drop
  with JD's rules. From the WAN it takes IKE, ESP and ping; DNS, NTP, SNMP,
  SSH and BGP are for private source addresses.
* **The default route has a next hop.** VyOS's was `0.0.0.0/0 interface
  eth1`: ARP for every destination, answered by Telstra's gateway for all
  of them (579 and then 764 neighbour entries an hour apart on 2026-10-13,
  every one with the same MAC). The DHCP lease
  carries a router and networkd uses it. If the WAN has a lease and nothing
  gets out: `ip route replace default dev wan0` is the VyOS way back.
* **DNS goes to Quad9, not Cloudflare,** for the reason given under "Upstream
  DNS decides where browsers connect". Measured from this site on
  2026-10-13: of 50 common names, Cloudflare sent 10 somewhere over 50 ms
  away where Quad9 never did (nine of Google's at about 120 ms instead of
  5 ms, and outlook.office365.com); the reverse, none. The numbers are in
  `recursor.yml`.
* **A network with no source NAT rule is stopped at the WAN.** VyOS had no
  rule for VLAN 110 or for VLAN 80 apart from 10.0.80.4, so their packets
  went to Telstra with a private source address and were lost there. They
  have no internet here either; `postrouting_filter` drops them instead.
  There is no catch-all masquerade as at JD, on purpose.
* **VLAN 36 cannot reach Telstra's own network directly.** The policy
  routing lists the private ranges as VyOS's did. JD's two tunnel VLANs use
  "whatever the main table has a route for" instead, which includes the
  WAN's connected /17: traffic from them to another Telstra customer in it
  leaves by the WAN, not the tunnel. That is still so at JD.
* **Conntrack helpers:** ftp and tftp, as at JD. VyOS also loaded h323,
  nfs, pptp, sip and sqlnet; the only flows the sip helper held were the
  torrent client's peers on port 5060 and scans of the WAN address.
* **Dynamic DNS updates and the `linds.com.au` forwarders** go to the two
  DCs here and then JD's. VyOS listed 10.0.50.1 for both, which is JD's
  router: a forwarder that could never take an update and asks the same DCs.
* **BGP** no longer listens for 10.0.53.0/24 (JD's nodes; they peer with
  JD's router), and the prefix-lists and `RM-EXPORT-IPSEC` that VyOS defined
  but applied to nothing are gone. LINDS sends JD everything it has, as
  before. The router-id is pinned to the value VyOS picked.
* **kea is authoritative,** as at JD: a client asking for an address the
  server has no record of is told no at once instead of waiting.
* **sysctls are JD's file.** Reverse-path filtering is loose where VyOS had
  it off (with a default route present that passes everything VyOS passed);
  VyOS's `tcp_timestamps=0`, `tcp_low_latency` and 26 MB default socket
  buffer, which only touched the router's own connections, are not carried.
* **The tunnel asks for IPv4 only** inside it. VyOS offered both families
  and JD only ever agreed to IPv4.
* **New MAC addresses.** The WAN lease, and so the public address and the
  delegated prefix, may change at cutover. ddclient updates
  `linds-pfsense.linds.com.au` within minutes and JD's end follows the name.
  JD also accepts this end only from the address that name has, so
  whichever end dials, the tunnel waits for the record.

### Building it

The build touches nothing that is live: the VM's LAN and WAN NICs are
link-down at the hypervisor, and it is reached through `mgmt0` on VLAN 300
with linds-vyos-01 still the gateway. It can be done days ahead and from
anywhere, and the router then sits idle until the swap.

1. The VM (LINDS-Terraform, `proxmox/`):

       terraform apply \
         -target=proxmox_storage_directory.linds_local \
         -target=proxmox_virtual_environment_vm.linds_router

   The plan on 2026-10-13 was 1 to import, 3 to add, 1 to change: the
   hypervisor's `local` storage gains the `import` and `snippets` content
   types, then the Debian image, the cloud-init snippet and VM 114. First
   boot installs the guest agent and upgrades the image; allow five minutes
   before the next step.
2. The router:

       ansible-playbook playbooks/router.yml --limit linds-router-01

   One reboot on the way (interface names, backports kernel); the test
   build took six minutes. A green run has passed `validate.yml`. It can be
   run from jd-jump-01: the route back
   to JD's LAN is a static into the tunnel, which is down on a router being
   built, and `30-mgmt0.network` keeps the management address's answers out
   of the main table for exactly that reason.
3. Look at it while it is idle:

   | Check | Expect |
   |---|---|
   | `systemctl --failed` | nothing |
   | `networkctl` | `lan0`, `wan0` and the VLANs `no-carrier`; `ipsec0` configured; `wg101` *configuring*, because its policy rules name `lan0.36` and networkd holds them until that interface is up |
   | `swanctl --list-conns` | `LINDS` |
   | `wg show wg101` | no handshake, ever, while wan0 is down |
   | `nft list chain inet router output` | the three "only by the WAN" counters climbing: charon and WireGuard keep trying, the packets go nowhere |
   | `journalctl -u isc-kea-dhcp4-server` | `the interface lan0 is not running`, five times every five seconds for five minutes after each start, then silence. It has stopped trying, which is why the cutover reboots the router |

   Nothing the idle router does reaches the live network: kea, the RA
   sender, avahi and miniupnpd are bound to `lan0` and its VLANs, charon may
   only use `wan0`, and the output chain keeps WireGuard and IKE off
   `mgmt0`. It does log to Loki, and ddclient does run: it sees the site's
   public address through VyOS and so publishes what is already there.

Re-run step 2 on the day, with `--check --diff` first; it should change
nothing.

**Getting in when the network is the problem.** The router accepts one SSH
key, the fleet key that jd-jump-01 holds, and the cloud image's user has no
password, so the serial console (`qm terminal 114`) offers a login nobody
can use. From the hypervisor the guest agent works whatever state the
network is in:

    qm guest exec 114 -- networkctl status wan0
    qm guest exec 114 -- journalctl -b -p warning --no-pager

A machine on the LAN that holds the fleet key can also `ssh
jayden@192.168.6.1`. Without the tunnel, jd-jump-01 is not such a machine.

### Cutover

On linds-proxmox-01, with `cutover/linds-router-cutover` copied to `/root`.
`status` changes nothing and shows both VMs and the three links.

1. Optional, and worth the two minutes: carry the DHCP leases over, so every
   client keeps its address and nothing is handed an address still in use.
   VyOS runs kea too and the subnet ids here are the same. kea keeps its
   leases in two files, the last compacted set (`.2`) and what has changed
   since; both are needed, in that order. With VyOS still up, minutes before
   the swap:

       # on jd-jump-01, or anywhere that reaches both
       ssh vyos@192.168.6.1 "sudo awk 'FNR==1 && NR!=1 {next} {print}' \
         /config/dhcp/dhcp4-leases.csv.2 /config/dhcp/dhcp4-leases.csv" > leases.csv
       scp leases.csv jayden@10.3.1.250:/tmp/
       ssh jayden@10.3.1.250 'sudo systemctl stop isc-kea-dhcp4-server &&
         sudo install -o _kea -g _kea -m 0640 /tmp/leases.csv /var/lib/kea/kea-leases4.csv &&
         sudo systemctl start isc-kea-dhcp4-server'

   (If there is no `.2` file at that moment, awk says so and the one file is
   the whole set.)
2. The swap:

       ./linds-router-cutover cutover

   It sets VM 101 not to start with the host, shuts it down, takes the new
   router's management NIC link-down, brings its LAN and WAN up and reboots
   it. The reboot is not a courtesy: a router built with its links down has
   daemons that gave up on them, kea first of all, and a boot with the
   links up is what every later boot will be. The site is offline from the
   shutdown until the new router has booted and its WAN has a lease; on the
   test VM the links and the reboot together took about half a minute.
   `./linds-router-cutover cutover --revert-after 15` does the same and
   rolls back by itself unless `confirm` is run within 15 minutes; that is
   the form to use if this is ever done from the other end of the tunnel.

   By hand it is five commands, in this order:

       qm set 101 --onboot 0
       qm shutdown 101
       qm set 114 --net0 'virtio=BC:24:11:06:01:00,bridge=vmbr0,firewall=0,tag=300,link_down=1'
       qm set 114 --net1 'virtio=BC:24:11:06:01:01,bridge=vmbr0,firewall=0,queues=4' \
                  --net2 'virtio=BC:24:11:06:01:02,bridge=vmbr1,firewall=0,queues=4'
       qm reboot 114

   Copy each `netN` value from `qm config 114` and change only `link_down`:
   Proxmox applies that to the running guest, but a line that differs in
   anything else (queues, MAC, model) unplugs the NIC and plugs in a new
   one.
3. Watch it come up (prefix each with `qm guest exec 114 --` from the
   hypervisor, or ssh to 192.168.6.1 from a machine with the key):

   | Check | Expect |
   |---|---|
   | `networkctl status wan0` | a lease, and a delegated prefix on `lan0` |
   | `ip route show default` | `default via … dev wan0 proto dhcp`; `ip -6 route show default` has the RA's |
   | `swanctl --list-sas` | `LINDS` ESTABLISHED. If the public address changed, the tunnel waits for the DNS record of `linds-pfsense.linds.com.au` (ddclient checks every five minutes, and the record's TTL is five minutes): JD dials that name and accepts this end only from its address |
   | `vtysh -c 'show bgp summary'` | 10.3.1.100, 10.3.1.101 and 10.255.0.1 established with prefixes |
   | `wg show wg101` | a recent handshake; from 10.0.36.2, `curl ifconfig.me` is NordVPN's address |
   | a LAN client | renews its lease, resolves an outside name and `linds-dc.linds.com.au`, has IPv6 |
   | from outside | Plex on port 32400 |
   | `systemctl --failed` | nothing |

4. From jd-jump-01, once the tunnel is back, check the other direction:
   `ssh jayden@192.168.6.1`, and on jd-router-01 `vtysh -c 'show ip bgp
   neighbors 10.255.0.2 routes'` has LINDS's five networks.

**Rollback** is `./linds-router-cutover rollback`: the new router's LAN and
WAN go link-down, its management NIC comes back, VM 101 starts (and starts
with the host again). VyOS routes again once it has booted, with the leases
it had. Nothing on the new router needs undoing; it is back to being built.

### What was tested before it ever saw LINDS, and what was not

On 2026-10-13 the whole build was run on a scratch VM on jd-proxmox-02: the
same Debian image and cloud-init, the same three MAC addresses, the LAN and
WAN NICs link-down in VLANs the bridge's uplink does not carry, the
management NIC on JD's VLAN 53 instead of LINDS's VLAN 300, and a random
WireGuard key and an invalid DDNS token so the test box could not speak for
linds-vyos-01 anywhere. The VMs were deleted afterwards. (Those VLANs were
not as private as intended: on a VLAN-aware Proxmox bridge every guest NIC
without a tag carries all of them, so six other guests on that host were
handed the test LAN's frames, tagged, for the thirteen minutes its link was
up. Checked afterwards on the two Windows servers and the jump box: none had
taken an address, a route or a neighbour from it. A test segment that is
really private is a bridge of its own with no ports.)

* **The build**: one run from a fresh image to a green `validate.yml`
  (152 tasks ok, none failed), a second run that changed nothing,
  `--check --diff` clean.
* **Two faults it found**, both fixed before this was committed. FRR's
  static route for JD's LAN sent the answers to Ansible's own SSH session
  into the tunnel, which is down during a build (hence table 250 in
  `30-mgmt0.network`). And DHCP stayed dead when the LAN link came up,
  because kea had long stopped trying to open its sockets (hence the reboot
  in the cutover).
* **The idle router keeps to itself**: with the links down, charon and
  WireGuard tried every few minutes and a 200-second capture on the
  management NIC saw no IKE, ESP or WireGuard packet leave.
* **The swap script**, against that VM and a stand-in for the old router:
  cutover, rollback, the timed rollback firing by itself, `confirm`
  cancelling it. Link changes were applied to the running guest without
  replacing the NIC. After the scripted swap a client VM on the isolated LAN
  got its lease from kea (192.168.6.2); before the reboot was added it got
  nothing.
* **The lease file**: linds-vyos-01's two lease files, merged as in step 1
  of the cutover, loaded into this kea: 27 leases in subnets 1, 2 and 4,
  the same 27 VyOS listed.
* **The ruleset**, in network namespaces
  (`tests/linds-ruleset-netns.sh`, 36 checks): source NAT for the main LAN,
  VLAN 300 and 10.0.80.4 and nothing leaving for VLAN 110 or the rest of
  VLAN 80; unreachable private destinations answered by the router and kept
  off the WAN; the Plex forward; what the input chain takes from the WAN and
  from the LAN side; where VLAN 36 is routed, the WAN's own network
  included; the tunnel guards; and 40 MiB transfers through the flowtable on
  every offloaded pair, of which the forward chain saw 3 packets (1,042
  with the offload rules removed).
* **The Terraform**: `plan` against linds-proxmox-01, not `apply`.

Not tested, because only the site can: the WAN against Telstra (the lease,
its router, the delegated prefix, the RA), the tunnel to jd-router-01 and
BGP over it, BGP with the two Talos workers, the NordVPN handshake, the Plex
forward from outside, UPnP and the mDNS reflector with real devices, kea's
updates into AD DNS, and Suricata on real traffic. The cutover table above
is that list as checks.

### After the cutover

Once it has run for as long as it takes to trust it:

1. **LINDS-Ansible**: `ansible_host` set to 192.168.6.1, and the management
   NIC's files, its sshd listen address and its entry in
   `router_expected_interfaces` removed. Done by the commit that wrote this
   sentence; run the playbook once after merging it.
2. **LINDS-Terraform**, branch `proxmox/linds-router-after-cutover`: the three
   `disconnected` flags written as the cutover left them, and
   `prevent_destroy`. Terraform ignores the link states of this VM once it
   has created it, so nothing is at risk before this is merged and its plan
   changes nothing on the VM.
3. **Delete linds-vyos-01**: `qm destroy 101 --purge` on linds-proxmox-01. It
   was made by hand and is in no Terraform state.
4. **LINDS-Ansible**, branch `router/remove-vyos`: `roles/vyos`, its playbook
   and inventory, and the `vyos.vyos` collection, which nothing uses once
   both routers are Debian.

## IPsec certificate rotation

Three credentials live under `/etc/swanctl/`, all issued by the AD CS CA
`linds-CA` on linds-dc. `swanctl --list-certs | grep -E 'subject|not after'`
shows what is loaded and when it expires.

| File | Vault var(s) | Subject | Used by | Expires |
|---|---|---|---|---|
| `x509ca/LINDS-CA.pem` | `files/linds-ca.cer` (vault-encrypted file) | `CN=linds-CA` | both connections verify peers against it; every host trusts it via `roles/common` | 2029-12-01 |
| `x509/IPSEC.pem` + `private/IPSEC.pem` | `pub_key`, `priv_key` | `C=AU, ST=Victoria, L=Langwarrin, O=LINDS-IPSEC, CN=LINDS-IPSEC` | `LINDS` site-to-site. **One cert, both ends**: LINDS VyOS carries the same vault values | 2053-08-26 |
| `x509/ipsec_remote.pem` + `private/ipsec_remote.pem` | `ipsec_remote_pub`, `ipsec_remote_priv` | `CN=jd-pfsense.linds.com.au`, SAN `jd-pfsense.linds.com.au`, `thezneaks.duckdns.org` | `LINDS_MOBILE` road warriors | **2027-08-21** |

The vault values are VyOS PKI blobs (bare base64 DER, one line). `to_pem`
also accepts PEM verbatim, so either shape works in the vault.

**Rotating a server cert** (`ipsec_remote` shown; `IPSEC` is the same with
its own subject):

1. Key + CSR, on the router or anywhere with openssl. The SAN list must keep
   every name clients use as the remote identifier; `serverAuth` is what
   iOS checks, the IKE-intermediate EKU is what Windows checks:

       openssl req -new -newkey rsa:3072 -nodes \
         -keyout ipsec_remote.key -out ipsec_remote.csr \
         -subj '/C=AU/ST=VIC/L=Moorabbin/O=LINDS/CN=jd-pfsense.linds.com.au' \
         -addext 'subjectAltName=DNS:jd-pfsense.linds.com.au,DNS:thezneaks.duckdns.org' \
         -addext 'extendedKeyUsage=serverAuth,1.3.6.1.5.5.8.2.2'

2. Sign it with `linds-CA`. From a domain member:
   `certreq -submit -attrib "CertificateTemplate:WebServer" ipsec_remote.csr ipsec_remote.cer`
   (any template that takes the subject from the request works), or the CA
   web enrollment page. `openssl x509 -in ipsec_remote.cer -noout -text`
   to confirm the SAN and EKU survived the template.
3. Into the vault, in the shape the role inherits:

       openssl x509 -in ipsec_remote.cer -outform DER | base64 -w0   # -> ipsec_remote_pub
       openssl pkey -in ipsec_remote.key -outform DER | base64 -w0   # -> ipsec_remote_priv
       ansible-vault encrypt_string --name ipsec_remote_pub "$(...)"

   Replace the values in `inventory/router.yml` (`router` group vars). The
   VyOS groups carry copies of the same variables; update them too if VyOS
   is still a rollback target, otherwise let them go.
4. `ansible-playbook playbooks/router.yml`. The role writes the PEMs, prunes
   anything else in the credential directories, and the handler runs
   `swanctl --load-all --clear` so the old key is gone from charon.
5. Established SAs keep the cert they authenticated with (rekeying does not
   re-authenticate). To put the new one to work now: road warriors
   `swanctl --terminate --ike LINDS_MOBILE` (they reconnect); site-to-site
   `swanctl --terminate --ike LINDS` then `swanctl --initiate --child LINDS`.
6. Check: `swanctl --list-certs` shows the new serial and `not after`, a
   phone connects, `journalctl -u strongswan --since -10min` is quiet.

**Site-to-site specifics.** `remote.id` on both ends pins the DN, so the
subject must not change. Authentication is "signed by LINDS-CA with that DN",
not "this exact cert", so the two ends can rotate one at a time: rotate here,
LINDS keeps presenting its old (still valid) cert until its own `set pki
certificate IPSEC …` is updated from the same vault values.

**CA rotation (2029).** A new CA breaks every client that only trusts the old
one, so order matters: install the new CA everywhere first (client profiles,
`roles/common` `files/LINDS-CA.enc`, this role's `files/linds-ca.cer`), run
both CAs side by side in `x509ca/` for the overlap (add the second file to
the "LINDS CA" task and to the prune `excludes` in `tasks/ipsec.yml`), then
re-issue the two server certs under the new CA, then drop the old one.
Renewing the AD CS CA with the *same* key pair avoids all of that: existing
certs stay valid and only the CA file needs replacing.

## Status: VyOS op-mode to here

`vtysh` is the interactive equivalent of VyOS op-mode for anything routing
(`show ip route`, `show bgp …`); everything else is the daemon's own tool.
The "commit" is `ansible-playbook playbooks/router.yml`.

| VyOS | Here |
|---|---|
| `show interfaces` | `networkctl list`, `networkctl status wan0`, `ip -br addr` |
| `show interfaces ethernet eth2 … dhcpv6` | `networkctl status wan0` (DHCPv4 + DHCPv6 lease, DUID), `ip -6 addr` |
| `show interfaces wireguard` | `wg show`; `systemctl list-timers 'wg-reresolve*'` |
| `show ip route` / `show ipv6 route` | `ip route`, `ip -6 route` (or `vtysh -c 'show ip route'` for FRR's view) |
| `show ip route table 1001` | `ip route show table 1001` (wan0 check), `table 1002` (lan0.99), `table 90`/`100` (WireGuard) |
| failover state | `ip route` (metric 1 = primary, 10 = backup), `journalctl -fu wan-failover` |
| `show ip bgp summary` | `vtysh -c 'show bgp summary'` |
| `show ip bgp neighbors X received-routes` | `vtysh -c 'show ip bgp neighbors X routes'` (accepted routes; `received-routes` needs soft-reconfiguration inbound) |
| `show ip bgp neighbors X advertised-routes` | `vtysh -c 'show ip bgp neighbors X advertised-routes'` |
| `reset ip bgp X soft` | `vtysh -c 'clear ip bgp X soft'` (`*` for all) |
| `show vpn ike sa` / `show vpn ipsec sa` | `swanctl --list-sas` (add `--ike LINDS`) |
| `show vpn ipsec remote-access` | `swanctl --list-sas --ike LINDS_MOBILE`; `swanctl --list-pools --leases` |
| `show vpn ipsec connections` | `swanctl --list-conns` |
| `show vpn ipsec policy` / `state` | `ip xfrm policy`, `ip xfrm state` |
| `show vpn ipsec … certificate` | `swanctl --list-certs` |
| `reset vpn ipsec site-to-site peer LINDS` | `swanctl --terminate --ike LINDS; swanctl --initiate --child LINDS` |
| `show dhcp server leases` | `echo '{"command":"lease4-get-all","service":["dhcp4"]}' \| socat - UNIX-CONNECT:/var/run/kea/kea4-ctrl-socket \| jq -r '.arguments.leases[] \| [."ip-address", ."hw-address", .hostname] \| @tsv'` |
| `show dhcp server statistics` | same socket, `"command":"statistic-get-all"` |
| `show dns forwarding statistics` | `rec_control get-all`, `rec_control get cache-entries` |
| `reset dns forwarding cache` | `rec_control wipe-cache '.$'` (everything) or `'linds.com.au$'` |
| `show firewall` | `nft list ruleset`; one chain: `nft list chain inet router input` |
| `show nat source rules` | `nft list chain inet router postrouting_nat` (`prerouting_nat` for port forwards) |
| UPnP / NAT-PMP mappings | `nft list table inet miniupnpd`; `cat /var/lib/miniupnpd/upnp.leases`; `journalctl -u miniupnpd` |
| mDNS reflector | `journalctl -u avahi-daemon`; `tcpdump -ni lan0.58 udp port 5353` (the router's repeats come from 10.0.58.1, on VLAN 52 from 10.0.52.1) |
| flowtable fast path | `conntrack -L \| grep -c OFFLOAD`; `nft list flowtable inet router ft` |
| live traffic (TUI) | `iftop -i wan0 -nP` (top flows), `bmon -p wan0,lan0` (per-NIC graphs), `iptraf-ng` (LAN stations, protocol breakdown), `vnstat -l -i wan0` live and `vnstat -d` history |
| `show conntrack table ipv4` | `conntrack -L`; count `conntrack -C`; NATed only `conntrack -L --src-nat` |
| `show ntp` | `chronyc tracking`, `chronyc sources` |
| `show lldp neighbors` | `lldpcli show neighbors` |
| `show log` | `journalctl -f`; per daemon `journalctl -u strongswan -u frr -u isc-kea-dhcp4-server -u wan-failover --since -1h` |
| `monitor traffic interface wan0` | `tcpdump -ni wan0` |
| IDS | `suricatasc -c uptime /var/run/suricata/suricata-command.socket`, `-c 'iface-stat wan0'`, `tail -f /var/log/suricata/eve.json \| jq -c 'select(.event_type=="alert")'` |
| `show system uptime` / `show version` | `uptime`, `uname -r`, `hostnamectl` |
| `restart dhcp server` etc. | `systemctl restart isc-kea-dhcp4-server` / `pdns-recursor` / `frr` / `strongswan` / `suricata` |
| `show configuration` | the files under `/etc` are the config; the role's `files/etc/` mirrors them |
