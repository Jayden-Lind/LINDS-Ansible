#!/bin/bash
# What files/jd/etc/nftables.conf does to packets, tested in throwaway network
# namespaces: a router with the site's interfaces, a client on the LAN and on
# each VLAN, "the internet" beyond the WAN and a stand-in for the NordVPN
# tunnel. Nothing outside those namespaces is touched and nothing is left
# behind.
#
#   sudo unshare -n bash roles/router/tests/jd-ruleset-netns.sh \
#        roles/router/files/jd/etc/nftables.conf
#
# Needs root (for the namespaces), nft, iproute2 and python3. It exits with
# the number of failed checks. Run it after you edit the ruleset, before the
# router sees it.
#
# The flowtable checks count the packets of each transfer that the forward
# chain saw. That is a handful when the flow was offloaded and thousands when
# it was not.
set -u
RULES=${1:?usage: sudo unshare -n bash $0 path/to/nftables.conf}
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
mkns() { unshare -n sleep 120 >/dev/null 2>&1 & echo $!; }
in_() { local pid=$1; shift; nsenter -t "$pid" -n "$@"; }

TRUNK=$(mkns); C52=$(mkns); C53=$(mkns); C58=$(mkns); INET=$(mkns); WG=$(mkns)
trap 'kill $TRUNK $C52 $C53 $C58 $INET $WG 2>/dev/null; rm -f /tmp/nstest.*.$$' EXIT
sleep 0.3
ip link set lo up
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2

# LAN trunk: lan0 (router) <-> lanc0 (TRUNK, the untagged LAN client 10.0.50.20)
ip link add lan0 type veth peer name lanc0; ip link set lanc0 netns $TRUNK
for v in 52 53 58; do ip link add link lan0 name lan0.$v type vlan id $v; done
ip addr add 10.0.50.1/24 dev lan0; ip addr add 10.0.52.1/24 dev lan0.52
ip addr add 10.0.53.1/24 dev lan0.53; ip addr add 10.0.58.1/24 dev lan0.58
for i in lan0 lan0.52 lan0.53 lan0.58; do ip link set $i up; done
in_ $TRUNK ip link set lo up; in_ $TRUNK ip link set lanc0 up
in_ $TRUNK ip addr add 10.0.50.20/24 dev lanc0; in_ $TRUNK ip route add default via 10.0.50.1
client() { # pid vlan addr gw
  in_ $TRUNK ip link add link lanc0 name v$1 type vlan id $2; in_ $TRUNK ip link set v$1 netns $1
  in_ $1 ip link set lo up; in_ $1 ip link set v$1 up; in_ $1 ip addr add $3 dev v$1; in_ $1 ip route add default via $4
}
client $C52 52 10.0.52.9/24 10.0.52.1
client $C53 53 10.0.53.9/24 10.0.53.1
client $C58 58 10.0.58.2/24 10.0.58.1
# WAN: wan0 (router, 203.0.113.2) <-> INET (gateway 203.0.113.1, "the internet" 198.51.100.10)
ip link add wan0 type veth peer name wanp; ip link set wanp netns $INET
ip addr add 203.0.113.2/24 dev wan0; ip link set wan0 up
in_ $INET ip link set lo up; in_ $INET ip link set wanp up; in_ $INET ip addr add 203.0.113.1/24 dev wanp
in_ $INET ip link add inet0 type dummy; in_ $INET ip link set inet0 up; in_ $INET ip addr add 198.51.100.10/32 dev inet0
in_ $INET ip route add 10.0.0.0/8 via 203.0.113.2
ip route add default via 203.0.113.1 dev wan0 metric 1024
# wg10: a veth to WG, with VLAN 58's policy routing as 30-wg10.network renders it
ip link add wg10 type veth peer name wgp; ip link set wgp netns $WG
ip addr add 10.5.0.2/16 dev wg10; ip link set wg10 up
in_ $WG ip link set lo up; in_ $WG ip link set wgp up; in_ $WG ip addr add 10.5.0.1/16 dev wgp
in_ $WG ip link add far0 type dummy; in_ $WG ip link set far0 up; in_ $WG ip addr add 192.0.2.10/32 dev far0
in_ $WG ip route add 10.0.0.0/8 via 10.5.0.2
ip route add default via 10.5.0.1 dev wg10 table 90
ip rule add from 10.0.58.0/24 iif lan0.58 lookup main suppress_prefixlength 0 pref 1000
ip rule add from 10.0.58.0/24 iif lan0.58 lookup 90 pref 1001

nft -f "$RULES" || { echo "RULESET DID NOT LOAD"; exit 1; }
nft insert rule inet router forward meta l4proto tcp tcp dport 9100 counter comment '"test: forward-chain packets"'
nft insert rule inet router forward meta l4proto tcp tcp sport 9100 counter comment '"test: forward-chain packets"'
fwd_seen() { nft list chain inet router forward | awk '/test: forward-chain packets/ {for(i=1;i<=NF;i++) if($i=="packets") n+=$(i+1)} END{print n+0}'; }

# seen_from client-pid dst port sink-pid -> the source address the sink saw
seen_from() {
  in_ $4 python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',$3)); s.settimeout(1.5)
try:
    print(s.recvfrom(100)[1][0])
except Exception: print('nothing')" > /tmp/nstest.sink.$$ & local p=$!; sleep 0.3
  in_ $1 python3 -c "
import socket; socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b'x',('$2',$3))"
  wait $p; cat /tmp/nstest.sink.$$; }
# connects client-pid dst port server-pid -> open or silent
connects() {
  in_ $4 python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',$3)); s.listen(1); s.settimeout(1.5)
try:
    s.accept()
except Exception: pass" & local p=$!; sleep 0.3
  in_ $1 python3 -c "
import socket; s=socket.socket(); s.settimeout(1)
try:
    s.connect(('$2',$3)); print('open')
except ConnectionRefusedError: print('refused')
except Exception: print('silent')"; wait $p; }
# synfin client-pid src dst sink-pid -> how many crafted SYN+FIN packets the
# sink saw. Conntrack calls these flags invalid.
synfin() {
  in_ $4 nft add table ip t; in_ $4 nft add chain ip t c '{ type filter hook prerouting priority -300; }'
  in_ $4 nft add rule ip t c tcp dport 9999 counter
  in_ $1 python3 -c "
import socket,struct
def csum(b):
    t=sum(struct.unpack('!%dH'%(len(b)//2),b))
    while t>>16: t=(t&0xffff)+(t>>16)
    return ~t&0xffff
src,dst='$2','$3'
h=struct.pack('!HHIIBBHHH',40000,9999,1000,0,5<<4,0x03,64240,0,0)
c=csum(socket.inet_aton(src)+socket.inet_aton(dst)+struct.pack('!BBH',0,6,len(h))+h)
h=h[:16]+struct.pack('!H',c)+h[18:]
s=socket.socket(socket.AF_INET,socket.SOCK_RAW,socket.IPPROTO_TCP)
for _ in range(3): s.sendto(h,(dst,0))"
  sleep 0.2
  in_ $4 nft list chain ip t c | grep -oE 'packets [0-9]+' | awk '{print $2}'
  in_ $4 nft delete table ip t; }

echo "== source NAT"
r=$(seen_from $TRUNK 198.51.100.10 9001 $INET); [ "$r" = 203.0.113.2 ] && ok "LAN -> internet leaves as the WAN address" || bad "LAN -> internet: saw $r"
r=$(seen_from $C52 198.51.100.10 9002 $INET); [ "$r" = 203.0.113.2 ] && ok "VLAN 52 -> internet leaves as the WAN address" || bad "VLAN 52 -> internet: saw $r"
r=$(seen_from $C53 198.51.100.10 9003 $INET); [ "$r" = 203.0.113.2 ] && ok "VLAN 53 -> internet leaves as the WAN address" || bad "VLAN 53 -> internet: saw $r"
r=$(seen_from $C58 192.0.2.10 9004 $WG); [ "$r" = 10.5.0.2 ] && ok "VLAN 58 -> internet leaves by wg10 as its address" || bad "VLAN 58 -> internet: saw $r"
echo "== between the VLANs (no NAT)"
r=$(seen_from $TRUNK 10.0.53.9 9005 $C53); [ "$r" = 10.0.50.20 ] && ok "LAN -> VLAN 53 arrives with its own address" || bad "LAN -> VLAN 53: saw $r"
echo "== VLAN 52 isolation"
r=$(connects $TRUNK 10.0.52.9 9006 $C52); [ "$r" = open ] && ok "LAN -> VLAN 52: opens" || bad "LAN -> VLAN 52: $r"
r=$(connects $C52 10.0.50.20 9007 $TRUNK); [ "$r" = silent ] && ok "VLAN 52 -> LAN: no answer" || bad "VLAN 52 -> LAN: $r"
r=$(in_ $C52 python3 -c "
import socket; s=socket.socket(); s.settimeout(1)
try:
    s.connect(('10.0.52.1',22)); print('open')
except ConnectionRefusedError: print('refused')
except Exception: print('silent')"); [ "$r" = silent ] && ok "VLAN 52 -> router SSH: no answer" || bad "VLAN 52 -> router SSH: $r"
echo "== a private destination with no route"
out=$(in_ $TRUNK ping -c1 -W2 10.99.99.99 2>&1); echo "$out" | grep -q "Net Unreachable" && ok "LAN -> 10.99.99.99: Destination Net Unreachable" || bad "LAN -> 10.99.99.99: $out"
echo "== invalid packets"
n=$(synfin $INET 203.0.113.1 10.0.50.20 $TRUNK); [ "${n:-0}" = 0 ] && ok "from the WAN: dropped" || bad "from the WAN: $n reached the LAN"
n=$(synfin $TRUNK 10.0.50.20 198.51.100.10 $INET); [ "${n:-0}" = 0 ] && ok "to the WAN: dropped, no private source leaves" || bad "to the WAN: $n reached the internet"
n=$(synfin $C53 10.0.53.9 10.0.50.20 $TRUNK); [ "${n:-0}" -gt 0 ] && ok "between the LANs: passes (one-way flows are legitimate there)" || bad "between the LANs: dropped"
echo "== bulk transfers through the flowtable"
xfer() { # server-pid server-ip client-pid label
  in_ $1 python3 -c "
import socket,hashlib; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',9100)); s.listen(1); s.settimeout(8)
c,a=s.accept(); h=hashlib.sha256(); n=0
while True:
    d=c.recv(65536)
    if not d: break
    h.update(d); n+=len(d)
print(n,h.hexdigest())" > /tmp/nstest.srv.$$ & local p=$!; sleep 0.3
  local before sent after; before=$(fwd_seen)
  sent=$(in_ $3 python3 -c "
import socket,hashlib,os; d=os.urandom(1<<20); h=hashlib.sha256(); s=socket.socket(); s.settimeout(8); s.connect(('$2',9100))
for i in range(40): s.sendall(d); h.update(d)
s.close(); print(40<<20,h.hexdigest())"); wait $p
  after=$(fwd_seen)
  if [ "$sent" != "$(cat /tmp/nstest.srv.$$)" ]; then bad "$4: transfer failed"
  elif [ $((after - before)) -lt 200 ]; then ok "$4: 40 MiB intact, the forward chain saw $((after - before)) packets"
  else bad "$4: not offloaded, the forward chain saw $((after - before)) packets"; fi; }
xfer $INET 198.51.100.10 $TRUNK "LAN -> WAN"
xfer $INET 198.51.100.10 $C52 "VLAN 52 -> WAN"
xfer $INET 198.51.100.10 $C53 "VLAN 53 -> WAN"
xfer $TRUNK 10.0.50.20 $C53 "VLAN 53 -> LAN (both on the trunk)"
xfer $C53 10.0.53.9 $TRUNK "LAN -> VLAN 53 (both on the trunk)"
xfer $C52 10.0.52.9 $TRUNK "LAN -> VLAN 52 (both on the trunk)"
xfer $C52 10.0.52.9 $C53 "VLAN 53 -> VLAN 52 (both on the trunk)"
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
