# router role

Builds **jd-router-01**, the Debian 13 replacement for jd-vyos-01, from plain
config files. The VM itself comes from LINDS-Terraform
(`proxmox/vms-jd-router.tf`: Debian genericcloud image, a management NIC on
VLAN 53, LAN and WAN NICs created link-down); this role turns it into the
router.

## Layout — where things live

| What | Where |
|---|---|
| Every daemon config, as the file it is on the box | `files/etc/…` (same path as on the box: `files/etc/nftables.conf` → `/etc/nftables.conf`) |
| The failover daemon and the WireGuard endpoint re-resolver | `files/usr/local/sbin/`, unit files in `files/etc/systemd/system/` |
| The few rendered files (they carry vault secrets) | `templates/`: WireGuard `.netdev` (peer endpoint + key), `swanctl/conf.d/secrets.conf` (EAP users), `ddclient.conf` (Cloudflare token), `wg-reresolve/*.conf` |
| Certificates / keys | rendered from the vault by `tasks/ipsec.yml` (VyOS's bare-base64 PKI blobs, wrapped as PEM by `filter_plugins/router_filters.py`) |
| Secrets | `inventory/router.yml` (copied from `inventory/vyos.yml`, same vault password) |
| The little data the templates need | `inventory/group_vars/jd_router.yml` |
| Task flow | `tasks/main.yml` → one task file per area, in dependency order |
| Failover daemon tests | `tests/` — `python3 -m unittest discover -s roles/router/tests` |

To change something, **edit the file under `files/etc/` and run the playbook**.
Hand edits on the box are fine for experiments; `--check --diff` shows exactly
what the role would put back.

## Running it

```sh
ansible-playbook playbooks/router.yml --check --diff   # what would change
ansible-playbook playbooks/router.yml                  # apply
```

A run ends in `tasks/validate.yml`: every daemon's own config checker
(`nft -c`, `vtysh -C`, `kea-dhcp4 -t`, `suricata -T`, `sshd -t`,
`swanctl --list-conns`, `rec_control ping`), an interface check against
`router_expected_interfaces`, and `systemctl --failed` must be empty. A green
run is a box that would route the moment its links come up.

## What each piece is

| Area | Daemon | Config | Notes |
|---|---|---|---|
| Interfaces, VLANs, WAN DHCP/PD, RA, WireGuard, XFRM | systemd-networkd | `etc/systemd/network/` | `.link` names NICs by MAC (`mgmt0`/`lan0`/`wan0`); the WAN keeps its lease through renews (`KeepConfiguration=dhcp`); PD `/56` → `lan0` (sla 0) and `lan0.52` (sla 1) |
| Firewall + NAT | nftables | `etc/nftables.conf` | One `inet` table, rule comments carry the VyOS rule numbers; the `output` chain has the build-time mgmt guard |
| Static + BGP | FRR (`bgpd`, `staticd`) | `etc/frr/frr.conf` | Same dialect as VyOS's `protocols`; `systemctl reload frr` diffs |
| Dual-WAN failover | `wan-failover` | `etc/wan-failover.json` | Per-WAN default in tables 1001/1002 for the health check (90/100 are the WireGuard tunnels'); hysteresis; carrier check; SNAT conntrack flush on switch |
| IPsec | strongSwan (swanctl) | `etc/swanctl/swanctl.conf` | `LINDS` site-to-site over `ipsec0`, `LINDS_MOBILE` road-warrior over `ipsec10`; `encap = yes` is a line here, not a template patch |
| DHCP | kea | `etc/kea/` | DDNS into AD DNS |
| DNS forwarder | pdns-recursor | `etc/powerdns/recursor.yml` | The 2026-08-22 cache tuning carried across |
| NTP / SNMP / LLDP / DDNS | chrony, snmpd, lldpd, ddclient | `etc/chrony/`, `etc/snmp/`, `etc/default/` | |
| IDS | Suricata 7 + suricata-update | `etc/suricata/` | One capture thread + autofp; EVE → rsyslog imfile → Alloy → Loki; weekly rule refresh reloads in place |
| Kernel | linux-image-cloud-amd64 from trixie-backports (7.x, `router_kernel_backports`), sysctl, modules, grub, tuned | `etc/sysctl.d/`, `etc/modules-load.d/`, `etc/default/grub.d/` | `ignore_routes_with_linkdown` keeps a link-down build reachable; `ip_nonlocal_bind` lets daemons bind `.1` addresses before the LAN link is up |

## Conventions and sharp edges

* **The role prunes.** `/etc/systemd/network` and the swanctl credential
  directories are made to match the role exactly — delete a file from
  `files/etc/systemd/network/` and the interface is gone on the next run.
* **A changed `.link` file or a kernel package change means a reboot** (the
  run does it). The kernel is the cloud flavour from trixie-backports
  (`router_kernel_backports: true`); stable's 6.12 stays installed as a
  fallback GRUB entry. Anything else
  reloads in place; a changed `.netdev` is deleted and recreated.
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
* **Software flowtable.** The last forward rule hands established TCP/UDP
  flows to `flowtable ft` (`wan0`, `lan0*`); later packets skip the
  ruleset. `conntrack -L | grep -c OFFLOAD` shows how many. Rules that must
  see every packet of a flow have to sit above it (none do today).
* **Suricata no longer disables offloads on lan0**, and
  `nic-tuning.service` turns them back on (`sg` before `tso`, which needs
  it), sets the VF rx ring to 8192 and enables UDP GRO forwarding on both
  NICs. irqbalance spreads the queues. All of it is ethtool, none of it is
  expressible in `.link` files.
* **Suricata runs `workers`, not `autofp`.** tpacket v3 only exists in the
  workers runmode; under autofp it silently fell back to v2, whose fixed
  frame size truncated every GRO super-packet at 1514 bytes
  (`decoder.ipv4.trunc_pkt` climbing, stream gaps). v3 with
  `block-size: 131072` captures them whole. Do not "fix" truncation with
  `default-packet-size: 65535`: under v2 that makes the ring mmap fail and
  Suricata crash-loops. Check with `suricatasc -c dump-counters` →
  `trunc_pkt` flat, `max_pkt_size` well above 1514.
* **IKE listens on IPv6 too.** Input rule 3 is family-agnostic and charon
  binds `[::]:500/4500`; ddclient keeps the AAAA record for
  `jd-pfsense.linds.com.au` current. Inside-tunnel IPv6 is still a future
  step (ULA pool).
* **BGP export to LINDS carries the JD LANs** (`JD-LANS`: 10.0.50.0/24,
  10.0.53.0/24), which VyOS did not. FRR does not refresh a neighbour when a
  route-map changes: `vtysh -c 'clear ip bgp 10.255.0.2 soft out'` after
  editing the export.
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

## Cutover (manual)

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
   `ip -6 route` (v6 default from RA), `suricatasc -c dump-counters /var/run/suricata-command.socket | grep wrong_thread`.

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
| `show dhcp server leases` | `echo '{"command":"lease4-get-all","service":["dhcp4"]}' \| socat - UNIX-CONNECT:/run/kea/kea4-ctrl-socket \| jq -r '.arguments.leases[] \| [."ip-address", ."hw-address", .hostname] \| @tsv'` |
| `show dhcp server statistics` | same socket, `"command":"statistic-get-all"` |
| `show dns forwarding statistics` | `rec_control get-all`, `rec_control get cache-entries` |
| `reset dns forwarding cache` | `rec_control wipe-cache '.$'` (everything) or `'linds.com.au$'` |
| `show firewall` | `nft list ruleset`; one chain: `nft list chain inet router input` |
| `show nat source rules` | `nft list chain inet router postrouting_nat` (`prerouting_nat` for port forwards) |
| UPnP / NAT-PMP mappings | `nft list table inet miniupnpd`; `cat /var/lib/miniupnpd/upnp.leases`; `journalctl -u miniupnpd` |
| flowtable fast path | `conntrack -L \| grep -c OFFLOAD`; `nft list flowtable inet router ft` |
| live traffic (TUI) | `iftop -i wan0 -nP` (top flows), `bmon -p wan0,lan0` (per-NIC graphs), `iptraf-ng` (LAN stations, protocol breakdown), `vnstat -l -i wan0` live and `vnstat -d` history |
| `show conntrack table ipv4` | `conntrack -L`; count `conntrack -C`; NATed only `conntrack -L --src-nat` |
| `show ntp` | `chronyc tracking`, `chronyc sources` |
| `show lldp neighbors` | `lldpcli show neighbors` |
| `show log` | `journalctl -f`; per daemon `journalctl -u strongswan -u frr -u kea-dhcp4-server -u wan-failover --since -1h` |
| `monitor traffic interface wan0` | `tcpdump -ni wan0` |
| IDS | `suricatasc -c uptime /var/run/suricata-command.socket`, `-c 'iface-stat wan0'`, `tail -f /var/log/suricata/eve.json \| jq -c 'select(.event_type=="alert")'` |
| `show system uptime` / `show version` | `uptime`, `uname -r`, `hostnamectl` |
| `restart dhcp server` etc. | `systemctl restart kea-dhcp4-server` / `pdns-recursor` / `frr` / `strongswan` / `suricata` |
| `show configuration` | the files under `/etc` are the config; the role's `files/etc/` mirrors them |
