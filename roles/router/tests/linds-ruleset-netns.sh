#!/bin/bash
# What files/linds/etc/nftables.conf does to packets, and where VLAN 36 is
# routed, tested in throwaway network namespaces: a router with the site's
# interfaces, a client on the LAN and on each VLAN, "the internet" beyond the
# WAN and the build's management network. Nothing outside those namespaces
# is touched and nothing is left behind.
#
#   sudo unshare -n bash roles/router/tests/linds-ruleset-netns.sh \
#        roles/router/files/linds/etc/nftables.conf
#
# Needs root (for the namespaces), nft, iproute2 and python3. It exits with
# the number of failed checks. The policy rules are added here by hand as
# 30-wg101.network states them; change both together.
#
# Run it after editing the ruleset, before the router sees it. It is how the
# flowtable was proven on a VLAN that shares the trunk with the untagged LAN:
# each transfer reports how many of its packets the forward chain saw, which
# is a handful when the flow was offloaded and every one when it was not.
set -u
set -u
RULES=${1:?usage: sudo unshare -n bash $0 path/to/nftables.conf}
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check() { local want=$1; shift; local desc=$1; shift; if "$@" >/dev/null 2>&1; then got=yes; else got=no; fi; [ "$got" = "$want" ] && ok "$desc" || bad "$desc (wanted $want, got $got)"; }
mkns() { unshare -n sleep 600 >/dev/null 2>&1 & echo $!; }
in_() { local pid=$1; shift; nsenter -t "$pid" -n "$@"; }

TRUNK=$(mkns); C300=$(mkns); C80=$(mkns); C110=$(mkns); C36=$(mkns); INET=$(mkns); MGMT=$(mkns)
trap 'kill $TRUNK $C300 $C80 $C110 $C36 $INET $MGMT 2>/dev/null' EXIT
sleep 0.3
ip link set lo up
# --- LAN trunk: lan0 (R) <-> lanc0 (TRUNK = the untagged LAN client 192.168.6.50)
ip link add lan0 type veth peer name lanc0; ip link set lanc0 netns $TRUNK
for v in 36 80 110 300; do ip link add link lan0 name lan0.$v type vlan id $v; done
ip addr add 192.168.6.1/24 dev lan0; ip addr add 10.0.36.1/24 dev lan0.36; ip addr add 10.0.80.1/24 dev lan0.80
ip addr add 10.0.110.1/24 dev lan0.110; ip addr add 10.3.1.1/24 dev lan0.300
for i in lan0 lan0.36 lan0.80 lan0.110 lan0.300; do ip link set $i up; done
in_ $TRUNK ip link set lo up; in_ $TRUNK ip link set lanc0 up
in_ $TRUNK ip addr add 192.168.6.50/24 dev lanc0; in_ $TRUNK ip route add default via 192.168.6.1
client() { # pid vlan addr gw
  in_ $TRUNK ip link add link lanc0 name v$1 type vlan id $2; in_ $TRUNK ip link set v$1 netns $1
  in_ $1 ip link set lo up; in_ $1 ip link set v$1 up; in_ $1 ip addr add $3 dev v$1; in_ $1 ip route add default via $4
}
client $C300 300 10.3.1.20/24 10.3.1.1
client $C80 80 10.0.80.4/24 10.0.80.1
in_ $C80 ip addr add 10.0.80.7/24 dev v$C80
client $C110 110 10.0.110.9/24 10.0.110.1
client $C36 36 10.0.36.2/24 10.0.36.1
# --- WAN: wan0 (R, 203.0.113.2/24) <-> INET (gateway 203.0.113.1, "the internet" 198.51.100.10)
ip link add wan0 type veth peer name wanp; ip link set wanp netns $INET
ip addr add 203.0.113.2/24 dev wan0; ip link set wan0 up
in_ $INET ip link set lo up; in_ $INET ip link set wanp up; in_ $INET ip addr add 203.0.113.1/24 dev wanp
in_ $INET ip link add inet0 type dummy; in_ $INET ip link set inet0 up; in_ $INET ip addr add 198.51.100.10/32 dev inet0
in_ $INET sysctl -qw net.ipv4.ip_forward=1
# --- tunnels as dummies, the build's management NIC as a veth
ip link add wg101 type dummy; ip link set wg101 up; ip addr add 10.5.0.2/32 dev wg101
ip link add ipsec0 type dummy; ip link set ipsec0 up; ip addr add 10.255.0.2/30 dev ipsec0
ip link add mgmt0 type veth peer name mgmtp; ip link set mgmtp netns $MGMT
ip addr add 10.9.9.250/24 dev mgmt0; ip link set mgmt0 up
in_ $MGMT ip link set lo up; in_ $MGMT ip link set mgmtp up; in_ $MGMT ip addr add 10.9.9.1/24 dev mgmtp
in_ $MGMT ip link add far0 type dummy; in_ $MGMT ip link set far0 up; in_ $MGMT ip addr add 198.51.100.20/32 dev far0
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2
ip route add default via 203.0.113.1 dev wan0 metric 1024
# VLAN 36 policy routing, as 30-wg101.network renders it
for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do ip rule add iif lan0.36 to $n lookup main pref 1010; done
ip rule add iif lan0.36 lookup 100 pref 1011; ip route add default dev wg101 table 100

nft -f "$RULES" || { echo "RULESET DID NOT LOAD"; exit 1; }
nft insert rule inet router forward meta l4proto tcp tcp dport 9100 counter comment '"test: forward-chain packets"'
nft insert rule inet router forward meta l4proto tcp tcp sport 9100 counter comment '"test: forward-chain packets"'
fwd_seen() { nft list chain inet router forward | awk '/test: forward-chain packets/ {for(i=1;i<=NF;i++) if($i=="packets") n+=$(i+1)} END{print n+0}'; }
echo "ruleset loaded: $(nft list ruleset | grep -c .) lines"

# helpers: a UDP sink that records the source address it saw; a TCP server
udpsink() { in_ $1 python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',$2)); s.settimeout($3)
try:
    d,a=s.recvfrom(100); print(a[0])
except Exception: print('nothing')
"; }
udpsend() { in_ $1 python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('${4:-0.0.0.0}',0)); s.sendto(b'x',('$2',$3))"; }
seen_from() { # client-pid dst port sink-pid [source address to send from] -> source address the sink saw
  udpsink $4 $3 2 > /tmp/nstest.$$ & local p=$!; sleep 0.4; udpsend $1 $2 $3 ${5:-}; wait $p; cat /tmp/nstest.$$; rm -f /tmp/nstest.$$; }

echo "== source NAT"
r=$(seen_from $TRUNK 198.51.100.10 9001 $INET); [ "$r" = 203.0.113.2 ] && ok "LAN -> internet leaves as the WAN address ($r)" || bad "LAN -> internet: saw $r"
r=$(seen_from $C300 198.51.100.10 9002 $INET); [ "$r" = 203.0.113.2 ] && ok "VLAN 300 -> internet leaves as the WAN address" || bad "VLAN 300 -> internet: saw $r"
r=$(seen_from $C80 198.51.100.10 9003 $INET 10.0.80.4); [ "$r" = 203.0.113.2 ] && ok "10.0.80.4 -> internet leaves as the WAN address" || bad "10.0.80.4 -> internet: saw $r"
r=$(seen_from $C80 198.51.100.10 9004 $INET 10.0.80.7); [ "$r" = nothing ] && ok "10.0.80.7 (VLAN 80, no NAT rule) -> internet: nothing leaves" || bad "10.0.80.7 -> internet: saw $r"
r=$(seen_from $C80 192.168.6.50 9009 $TRUNK 10.0.80.7); [ "$r" = 10.0.80.7 ] && ok "10.0.80.7 -> LAN still works (the test client is real)" || bad "10.0.80.7 -> LAN: saw $r"
r=$(seen_from $C110 198.51.100.10 9005 $INET); [ "$r" = nothing ] && ok "VLAN 110 (no NAT rule) -> internet: nothing leaves" || bad "VLAN 110 -> internet: saw $r"
echo "== between the VLANs (forward is accept, no NAT)"
r=$(seen_from $TRUNK 10.3.1.20 9006 $C300); [ "$r" = 192.168.6.50 ] && ok "LAN -> VLAN 300 arrives with its own address" || bad "LAN -> VLAN 300: saw $r"
r=$(seen_from $C110 192.168.6.50 9007 $TRUNK); [ "$r" = 10.0.110.9 ] && ok "VLAN 110 -> LAN arrives with its own address" || bad "VLAN 110 -> LAN: saw $r"
echo "== a private destination with no route"
out=$(in_ $TRUNK ping -c1 -W2 10.99.99.99 2>&1); echo "$out" | grep -q "Net Unreachable" && ok "LAN -> 10.99.99.99: Destination Net Unreachable from the router" || bad "LAN -> 10.99.99.99: $(echo "$out" | sed -n 2p)"
r=$(seen_from $TRUNK 10.99.99.99 9008 $INET); [ "$r" = nothing ] && ok "and nothing for 10.99.99.99 reaches the WAN" || bad "10.99.99.99 leaked to the WAN from $r"
echo "== port forward"
in_ $C300 python3 -c "
import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',32400)); s.listen(1); s.settimeout(4)
try:
    c,a=s.accept(); c.send(b'plex:'+a[0].encode()); c.close()
except Exception: pass" & sleep 0.4
r=$(in_ $INET python3 -c "
import socket; s=socket.socket(); s.settimeout(3)
try:
    s.connect(('203.0.113.2',32400)); print(s.recv(100).decode())
except Exception as e: print('failed',e)"); wait
[ "$r" = "plex:203.0.113.1" ] && ok "WAN:32400 -> 10.3.1.20, client address kept ($r)" || bad "port forward: $r"
echo "== input from the WAN"
check yes "ping the WAN address" in_ $INET ping -c1 -W2 203.0.113.2
tcp() { in_ $1 python3 -c "
import socket,sys; s=socket.socket(); s.settimeout(2)
try:
    s.connect(('$2',$3)); print('open')
except ConnectionRefusedError: print('refused')
except Exception: print('silent')"; }
r=$(tcp $INET 203.0.113.2 22); [ "$r" = silent ] && ok "SSH from the WAN: no answer" || bad "SSH from the WAN: $r"
r=$(tcp $INET 203.0.113.2 179); [ "$r" = silent ] && ok "BGP from the WAN: no answer" || bad "BGP from the WAN: $r"
r=$(tcp $INET 203.0.113.2 53); [ "$r" = silent ] && ok "DNS from the WAN: no answer" || bad "DNS from the WAN: $r"
r=$(tcp $INET 203.0.113.2 500); [ "$r" = refused ] && ok "IKE port from the WAN: let in (refused only because nothing listens here)" || bad "IKE from the WAN: $r"
udpprobe() { in_ $1 python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.connect(('$2',$3)); s.send(b'x')
try:
    s.recv(10); print('answer')
except ConnectionRefusedError: print('refused')
except Exception: print('silent')"; }
r=$(udpprobe $INET 203.0.113.2 123); [ "$r" = silent ] && ok "NTP from the WAN: no answer" || bad "NTP from the WAN: $r"
echo "== input from the LAN side"
r=$(tcp $TRUNK 192.168.6.1 22); [ "$r" = refused ] && ok "SSH from the LAN: let in" || bad "SSH from the LAN: $r"
r=$(tcp $C300 10.3.1.1 179); [ "$r" = refused ] && ok "BGP from VLAN 300: let in" || bad "BGP from VLAN 300: $r"
r=$(udpprobe $C110 10.0.110.1 53); [ "$r" = refused ] && ok "DNS from VLAN 110: let in" || bad "DNS from VLAN 110: $r"
r=$(udpprobe $TRUNK 192.168.6.1 1900); [ "$r" = refused ] && ok "UPnP SSDP from the main LAN: let in" || bad "SSDP from LAN: $r"
r=$(udpprobe $C300 10.3.1.1 1900); [ "$r" = silent ] && ok "UPnP SSDP from VLAN 300: no answer" || bad "SSDP from VLAN 300: $r"
check yes "ping the router from the LAN" in_ $TRUNK ping -c1 -W2 192.168.6.1
echo "== VLAN 36 policy routing"
g() { ip route get "$1" from 10.0.36.2 iif lan0.36 2>&1 | grep -o "dev [a-z0-9.]*" | head -1; }
[ "$(g 198.51.100.10)" = "dev wg101" ] && ok "VLAN 36 -> internet: $(g 198.51.100.10)" || bad "VLAN 36 -> internet: $(g 198.51.100.10)"
[ "$(g 203.0.113.77)" = "dev wg101" ] && ok "VLAN 36 -> the WAN's own network: $(g 203.0.113.77) (not the WAN)" || bad "VLAN 36 -> WAN subnet: $(g 203.0.113.77)"
[ "$(g 10.3.1.20)" = "dev lan0.300" ] && ok "VLAN 36 -> VLAN 300: $(g 10.3.1.20)" || bad "VLAN 36 -> VLAN 300: $(g 10.3.1.20)"
[ "$(g 192.168.6.50)" = "dev lan0" ] && ok "VLAN 36 -> LAN: $(g 192.168.6.50)" || bad "VLAN 36 -> LAN: $(g 192.168.6.50)"
echo "== the tunnels' own packets while only the management NIC has a route (the build)"
ip route del default; ip link set wan0 down; ip route add default via 10.9.9.1 dev mgmt0 metric 4096
gsend() { python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b'x',('$1',$2))" 2>/dev/null; }
gseen() { udpsink $MGMT $2 2 > /tmp/nstest.$$ & local p=$!; sleep 0.4; gsend $1 $2; wait $p; cat /tmp/nstest.$$; rm -f /tmp/nstest.$$; }
r=$(gseen 198.51.100.20 51820); [ "$r" = nothing ] && ok "WireGuard to a public address by mgmt0: dropped" || bad "WireGuard by mgmt0: reached the far end from $r"
r=$(gseen 198.51.100.20 4500); [ "$r" = nothing ] && ok "IKE to a public address by mgmt0: dropped" || bad "IKE by mgmt0: reached the far end from $r"
r=$(gseen 198.51.100.20 443); [ "$r" = 10.9.9.250 ] && ok "anything else by mgmt0 (apt, rules): passes" || bad "port 443 by mgmt0: $r"
r=$(gseen 10.9.9.1 51820); [ "$r" = 10.9.9.250 ] && ok "a reply to a private client that asked from port 51820: passes" || bad "private dst :51820: $r"
ip route del default; ip link set wan0 up; ip route add default via 203.0.113.1 dev wan0 metric 1024
echo "== bulk transfers through the flowtable"
xfer() { # server-pid server-ip client-pid label
  in_ $1 python3 -c "
import socket,hashlib; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',9100)); s.listen(1); s.settimeout(8)
c,a=s.accept(); h=hashlib.sha256(); n=0
while True:
    d=c.recv(65536)
    if not d: break
    h.update(d); n+=len(d)
c2=None
print(n,h.hexdigest())" > /tmp/nstest.srv.$$ & local p=$!; sleep 0.4
  local sent; sent=$(in_ $3 python3 -c "
import socket,hashlib,os; d=os.urandom(1<<20); h=hashlib.sha256(); s=socket.socket(); s.settimeout(8); s.connect(('$2',9100))
for i in range(40): s.sendall(d); h.update(d)
s.close(); print(40<<20,h.hexdigest())"); wait $p
  local after; after=$(fwd_seen)
  [ "$sent" = "$(cat /tmp/nstest.srv.$$)" ] && ok "$4: 40 MiB arrived intact; the forward chain saw $((after - FWD_BEFORE)) of its packets" || bad "$4: sent [$sent] got [$(cat /tmp/nstest.srv.$$)]"; rm -f /tmp/nstest.srv.$$; FWD_BEFORE=$after; }
FWD_BEFORE=$(fwd_seen)
xfer $INET 198.51.100.10 $TRUNK "LAN -> WAN"
xfer $INET 198.51.100.10 $C300 "VLAN 300 -> WAN"
xfer $C300 10.3.1.20 $TRUNK "LAN -> VLAN 300 (both on the trunk)"
xfer $TRUNK 192.168.6.50 $C300 "VLAN 300 -> LAN"
echo "  (a transfer that was not offloaded shows the forward chain every packet: thousands)"
# the same LAN -> WAN transfer with the six flow-add rules removed, for comparison
for h in $(nft -a list chain inet router forward | awk '/flow add @ft/ {print $NF}'); do nft delete rule inet router forward handle $h; done
xfer $INET 198.51.100.10 $TRUNK "LAN -> WAN with the flow-add rules removed"
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
