#!/bin/bash
# The inline Suricata of jd-router-01, tested with a real Suricata in
# throwaway network namespaces: the firewall of files/jd/etc/nftables.conf,
# Suricata on NFQUEUE 0 with files/etc/suricata/suricata.yaml, a client on the
# LAN, the torrent host, a published service and "the internet" beyond the
# WAN. Nothing outside the namespaces is touched: the live Suricata, its
# queue and its log are in a different network namespace. One thing shows on
# the router: the watchdog check writes a line to the journal ("Suricata does
# not answer ... It is killed"). That line is about the Suricata of the test.
#
# Run it on a router (it needs Suricata 8, nft, python3 and openssl), from a
# copy of the role's files:
#
#   sudo unshare -n bash jd-suricata-inline-netns.sh FILES_DIR
#
# FILES_DIR is roles/router/files. The script exits with the number of failed
# checks. It makes /var/tmp/suricata-lab and deletes it at the end
# (KEEP=1 keeps it, for the logs).
set -u
SRC=${1:?usage: sudo unshare -n bash $0 path/to/roles/router/files}
LAB=/var/tmp/suricata-lab
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
mkns() { unshare -n sleep 900 >/dev/null 2>&1 </dev/null & echo $!; }
in_() { local pid=$1; shift; nsenter -t "$pid" -n "$@"; }

TRUNK=$(mkns); C53=$(mkns); INET=$(mkns)
SURI=""
cleanup() {
  [ -n "$SURI" ] && kill -CONT "$SURI" 2>/dev/null; [ -n "$SURI" ] && kill "$SURI" 2>/dev/null
  kill $TRUNK $C53 $INET $(jobs -p) 2>/dev/null
  [ "${KEEP:-0}" = 1 ] || rm -rf "$LAB"
}
trap cleanup EXIT
sleep 0.3
rm -rf "$LAB"; install -d -o suricata -g suricata "$LAB" "$LAB/log" "$LAB/rules" "$LAB/run" "$LAB/cache"

# ---------------------------------------------------------------- network
ip link set lo up
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 \
       net.netfilter.nf_conntrack_acct=1 net.ipv6.conf.all.forwarding=1
# LAN: lan0 (router 10.0.50.1) <-> lanc0 (TRUNK: a client 10.0.50.20 and the torrent host 10.0.50.24)
ip link add lan0 type veth peer name lanc0; ip link set lanc0 netns $TRUNK
ip link add link lan0 name lan0.53 type vlan id 53
ip addr add 10.0.50.1/24 dev lan0; ip addr add 10.0.53.1/24 dev lan0.53
ip link set lan0 up; ip link set lan0.53 up
in_ $TRUNK ip link set lo up; in_ $TRUNK ip link set lanc0 up
in_ $TRUNK ip addr add 10.0.50.20/24 dev lanc0; in_ $TRUNK ip addr add 10.0.50.24/24 dev lanc0
in_ $TRUNK ip route add default via 10.0.50.1
# VLAN 53: the published service 10.0.53.9
in_ $TRUNK ip link add link lanc0 name v53 type vlan id 53; in_ $TRUNK ip link set v53 netns $C53
in_ $C53 ip link set lo up; in_ $C53 ip link set v53 up; in_ $C53 ip addr add 10.0.53.9/24 dev v53
in_ $C53 ip route add default via 10.0.53.1
# WAN: wan0 (203.0.113.2) <-> INET (gateway 203.0.113.1; servers 198.51.100.10 and, on the lists, 198.51.100.66)
ip link add wan0 type veth peer name wanp; ip link set wanp netns $INET
ip addr add 203.0.113.2/24 dev wan0; ip link set wan0 up
in_ $INET ip link set lo up; in_ $INET ip link set wanp up; in_ $INET ip addr add 203.0.113.1/24 dev wanp
in_ $INET ip link add inet0 type dummy; in_ $INET ip link set inet0 up
in_ $INET ip addr add 198.51.100.10/32 dev inet0; in_ $INET ip addr add 198.51.100.66/32 dev inet0
ip route add default via 203.0.113.1 dev wan0
# IPv6, for the exemption of the torrent host by its interface identifier
ip -6 addr add 2001:db8:50::1/64 dev lan0 nodad; ip -6 addr add 2001:db8:fe::2/64 dev wan0 nodad
in_ $TRUNK ip -6 addr add 2001:db8:50::20/64 dev lanc0 nodad
in_ $TRUNK ip -6 addr add 2001:db8:50:0:be24:11ff:fe98:9dfc/64 dev lanc0 nodad
in_ $TRUNK ip -6 route add default via 2001:db8:50::1
in_ $INET ip -6 addr add 2001:db8:fe::1/64 dev wanp nodad; in_ $INET ip -6 addr add 2001:db8:ffff::66/128 dev inet0 nodad
in_ $INET ip -6 route add 2001:db8:50::/64 via 2001:db8:fe::2
ip -6 route add default via 2001:db8:fe::1 dev wan0

nft -f "$SRC/jd/etc/nftables.conf" || { echo "RULESET DID NOT LOAD"; exit 1; }
# A port forward, as k8s-port-forward makes them: WAN 8443 -> the published service.
nft add table ip lab; nft add chain ip lab pre '{ type nat hook prerouting priority dstnat - 10; }'
nft add rule ip lab pre iifname wan0 tcp dport 8443 dnat to 10.0.53.9:8443
# Count what the forward chain sees of the bulk transfer (port 9100).
nft insert rule inet router forward meta l4proto tcp tcp dport 9100 counter comment '"test: forward-chain packets"'
nft insert rule inet router forward meta l4proto tcp tcp sport 9100 counter comment '"test: forward-chain packets"'
fwd_seen() { nft list chain inet router forward | awk '/test: forward-chain packets/ {for(i=1;i<=NF;i++) if($i=="packets") n+=$(i+1)} END{print n+0}'; }

# ---------------------------------------------------------------- Suricata
# The role's suricata.yaml, with the paths of the lab. The rules are a few
# of the kinds that drop.conf makes drop rules on the router: a list of
# addresses and the lists of names (the rule text of /etc/suricata/blocklist.rules).
sed -e "s|^default-log-dir: .*|default-log-dir: $LAB/log/|" \
    -e "s|filename: /var/run/suricata/suricata-command.socket|filename: $LAB/run/command.socket|" \
    -e "s|^default-rule-path: .*|default-rule-path: $LAB/rules|" \
    -e "s|- /etc/suricata/unblock.rules|- $LAB/rules/unblock.rules|" \
    -e "s|^threshold-file: .*|threshold-file: /dev/null|" \
    -e "s|sgh-mpm-caching-path: .*|sgh-mpm-caching-path: $LAB/cache|" \
    "$SRC/etc/suricata/suricata.yaml" > "$LAB/suricata.yaml"
cp "$SRC/jd/etc/suricata/site-address-groups.yaml" "$LAB/"
b64() { printf '%s' "$1" | base64 -w0; }
{ b64 bad.example; echo; b64 evil.test; echo; } > "$LAB/rules/names.lst"
cat > "$LAB/rules/suricata.rules" <<EOF
drop ip [198.51.100.66,2001:db8:ffff::66] any -> any any (msg:"ET DROP lab: listed source"; sid:2400001; rev:1;)
drop dns any any -> any any (msg:"Threat list (malware, phishing) Blocked DNS Query"; dns.query; domain; dataset:isset,labnames,type string,load $LAB/rules/names.lst; sid:12001201; rev:1;)
drop http any any -> any any (msg:"Threat list (malware, phishing) Blocked HTTP Request"; http.host; domain; dataset:isset,labnames,type string,load $LAB/rules/names.lst; sid:12001202; rev:1;)
drop tls any any -> any any (msg:"Threat list (malware, phishing) Blocked TLS Connection"; tls.sni; domain; dataset:isset,labnames,type string,load $LAB/rules/names.lst; sid:12001203; rev:1;)
alert http any any -> any any (msg:"lab: a rule that only reports"; http.uri; content:"/report-me"; sid:9000001; rev:1;)
EOF
: > "$LAB/rules/unblock.rules"
chown -R suricata:suricata "$LAB"
suricata -q 0 -c "$LAB/suricata.yaml" --pidfile "$LAB/run/suricata.pid" > "$LAB/log/stdout" 2>&1 &
SURI=$!
for i in $(seq 1 60); do [ -S "$LAB/run/command.socket" ] && grep -q "^ *0 " /proc/net/netfilter/nfnetlink_queue 2>/dev/null && break; sleep 0.5; done
sc() { suricatasc -c "$1" "$LAB/run/command.socket" 2>/dev/null; }
if ! grep -q "^ *0 " /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
  echo "SURICATA DID NOT TAKE THE QUEUE"; tail -20 "$LAB/log/stdout" "$LAB/log/suricata.log" 2>/dev/null; exit 1
fi
sleep 1
echo "== Suricata runs inline as $(ps -o user= -p $(cat $LAB/run/suricata.pid)) on queue 0"
# How many packets the firewall has given to the queue so far.
queued() { awk '$1 == 0 { print $8 }' /proc/net/netfilter/nfnetlink_queue; }
# events KEY VALUE [TYPE] -> how many EVE events have that text
events() { sleep 0.6; grep -c "$1" "$LAB/log/eve.json" 2>/dev/null; }

# ---------------------------------------------------------------- helpers
# tcp CLIENT SRC DST PORT -> open, refused or silent
tcp() { in_ $1 python3 -c "
import socket; s=socket.socket(socket.AF_INET6 if ':' in '$3' else socket.AF_INET); s.settimeout(2.5); s.bind(('$2',0))
try:
    s.connect(('$3',$4)); print('open')
except ConnectionRefusedError: print('refused')
except Exception: print('silent')"; }
# http CLIENT SRC DST HOST PATH -> the status line, or nothing
http() { in_ $1 python3 -c "
import socket; s=socket.socket(); s.settimeout(3); s.bind(('$2',0))
try:
    s.connect(('$3',80)); s.sendall(b'GET $5 HTTP/1.1\r\nHost: $4\r\nUser-Agent: lab\r\nConnection: close\r\n\r\n'); print(s.recv(100).split(b'\r\n')[0].decode())
except Exception: print('nothing')"; }
# tls CLIENT SRC DST SNI -> ok or failed
tls() { in_ $1 python3 -c "
import socket,ssl; c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
s=socket.socket(); s.settimeout(3); s.bind(('$2',0))
try:
    s.connect(('$3',443)); t=c.wrap_socket(s,server_hostname='$4'); t.sendall(b'hi'); print('ok' if t.recv(10)==b'hello' else 'failed')
except Exception: print('failed')"; }
# dns CLIENT SRC NAME -> answered or nothing (a question to the router, 10.0.50.1 or its link-local name is not needed)
dns() { in_ $1 python3 -c "
import socket,struct
q=struct.pack('>HHHHHH',0x1234,0x0100,1,0,0,0)+b''.join(bytes([len(p)])+p.encode() for p in '$3'.split('.'))+b'\0'+struct.pack('>HH',1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.bind(('$2',0)); s.sendto(q,('10.0.50.1',53))
try:
    s.recvfrom(512); print('answered')
except Exception: print('nothing')"; }

# The servers. In INET: HTTP on 80, TLS on 443, a sink on 9100, all addresses.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$LAB/key.pem" -out "$LAB/cert.pem" -days 2 -subj /CN=lab >/dev/null 2>&1
chmod 644 "$LAB/key.pem"
nsenter -t $INET -n python3 -c "
import socket,ssl,threading,hashlib
def serve(port, fam, handler):
    s=socket.socket(fam); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('::' if fam==socket.AF_INET6 else '0.0.0.0',port)); s.listen(50)
    while True:
        c,_=s.accept(); threading.Thread(target=handler,args=(c,),daemon=True).start()
def h_http(c):
    try: c.settimeout(5); c.recv(2000); c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'); c.close()
    except Exception: pass
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('$LAB/cert.pem','$LAB/key.pem')
def h_tls(c):
    try: c.settimeout(5); t=ctx.wrap_socket(c,server_side=True); t.recv(10); t.sendall(b'hello'); t.close()
    except Exception: pass
def h_sink(c):
    h=hashlib.sha256(); n=0
    while True:
        d=c.recv(65536)
        if not d: break
        h.update(d); n+=len(d)
    open('$LAB/sink.out','w').write('%d %s' % (n,h.hexdigest())); c.close()
def h_open(c): c.close()
for port,fam,h in ((80,socket.AF_INET,h_http),(443,socket.AF_INET,h_tls),(9100,socket.AF_INET,h_sink),(8080,socket.AF_INET6,h_open)):
    threading.Thread(target=serve,args=(port,fam,h),daemon=True).start()
threading.Event().wait()" >/dev/null 2>&1 &
# The published service on VLAN 53.
nsenter -t $C53 -n python3 -c "
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',8443)); s.listen(50)
while True: s.accept()[0].close()" >/dev/null 2>&1 &
# The router's DNS: answers each question (Unbound's place).
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('10.0.50.1',53))
while True:
    d,a=s.recvfrom(512); s.sendto(d[:2]+b'\x81\x80'+d[4:6]+b'\0\0\0\0\0\0'+d[12:],a)" >/dev/null 2>&1 &
sleep 1

# ---------------------------------------------------------------- checks
echo "== ordinary traffic passes, and Suricata logs it"
r=$(http $TRUNK 10.0.50.20 198.51.100.10 www.good.example /); [ "$r" = "HTTP/1.1 200 OK" ] && ok "HTTP from the LAN: answered" || bad "HTTP from the LAN: $r"
[ "$(events '"hostname":"www.good.example"')" -ge 1 ] && ok "  logged: an http event with the host name" || bad "  no http event"
r=$(tls $TRUNK 10.0.50.20 198.51.100.10 www.good.example); [ "$r" = ok ] && ok "TLS from the LAN: handshake and data" || bad "TLS from the LAN: $r"
[ "$(events '"sni":"www.good.example"')" -ge 1 ] && ok "  logged: a tls event with the server name" || bad "  no tls event"
r=$(dns $TRUNK 10.0.50.20 www.good.example); [ "$r" = answered ] && ok "DNS question to the router: answered" || bad "DNS question to the router: $r"
[ "$(events '"rrname":"www.good.example"')" -ge 1 ] && ok "  logged: a dns event with the name" || bad "  no dns event"
r=$(tcp $INET 198.51.100.10 203.0.113.2 8443); [ "$r" = open ] && ok "the published port from the internet: opens" || bad "the published port from the internet: $r"
r=$(http $TRUNK 10.0.50.20 198.51.100.10 www.good.example /report-me); [ "$r" = "HTTP/1.1 200 OK" ] && [ "$(events '"signature_id":9000001')" -ge 1 ] && ok "a rule that only reports: the request passes, the alert is logged" || bad "a rule that only reports: $r"

echo "== a long connection: Suricata gets its start, the flowtable gets the rest"
b_acc=$(queued); b_fwd=$(fwd_seen); t0=$(date +%s.%N)
sent=$(in_ $TRUNK python3 -c "
import socket,hashlib,os; d=os.urandom(1<<20); h=hashlib.sha256(); s=socket.socket(); s.settimeout(15); s.bind(('10.0.50.20',0)); s.connect(('198.51.100.10',9100))
for i in range(40): s.sendall(d); h.update(d)
s.close(); print(40<<20,h.hexdigest())"); t1=$(date +%s.%N); sleep 1
a_acc=$(queued); a_fwd=$(fwd_seen)
[ "$sent" = "$(cat $LAB/sink.out 2>/dev/null)" ] && ok "40 MiB from the LAN to the internet: intact, $(python3 -c "print(round(40*8/($t1-$t0)))") Mbit/s" || bad "40 MiB transfer failed"
# The firewall counts 60 packets as the kernel has them. A large packet (the
# kernel joins up to 64 KB of one connection) is given to Suricata in pieces
# of the size of the MTU, so Suricata gets more than 60, and a small part of
# the 28,000 that the transfer has.
n=$((a_acc-b_acc)); [ $n -ge 3 ] && [ $n -le 3000 ] && ok "Suricata got the start of it: $n packets of about 28,000" || bad "Suricata got $n packets of the transfer"
n=$((a_fwd-b_fwd)); [ $n -le 200 ] && ok "the forward chain saw $n packets: the rest went by the flowtable" || bad "not offloaded: the forward chain saw $n packets"

echo "== blocked: an address on a list"
r=$(tcp $INET 198.51.100.66 203.0.113.2 8443); [ "$r" = silent ] && ok "listed address -> the published port: no answer" || bad "listed address -> the published port: $r"
r=$(tcp $TRUNK 10.0.50.20 198.51.100.66 80); [ "$r" = silent ] && ok "LAN -> listed address: no connection" || bad "LAN -> listed address: $r"
echo "== blocked: a name on a list"
r=$(dns $TRUNK 10.0.50.20 bad.example); [ "$r" = nothing ] && ok "DNS question for a listed name: no answer" || bad "DNS question for a listed name: $r"
r=$(dns $TRUNK 10.0.50.20 cdn.bad.example); [ "$r" = nothing ] && ok "DNS question for a subdomain of it: no answer" || bad "DNS for a subdomain of a listed name: $r"
r=$(tls $TRUNK 10.0.50.20 198.51.100.10 evil.test); [ "$r" = failed ] && ok "TLS to a listed name: fails" || bad "TLS to a listed name: $r"
r=$(http $TRUNK 10.0.50.20 198.51.100.10 bad.example /); [ "$r" = nothing ] && ok "HTTP to a listed name: no answer" || bad "HTTP to a listed name: $r"
r=$(tls $TRUNK 10.0.50.20 198.51.100.10 www.good.example); [ "$r" = ok ] && ok "TLS to another name on the same server: still works" || bad "TLS to another name: $r"
n=$(events '"action":"blocked"'); [ "$n" -ge 5 ] && ok "logged: $n alerts with \"action\": \"blocked\"" || bad "only $n blocked alerts in the log"

echo "== the torrent host is exempt: not blocked, not logged"
r=$(tcp $TRUNK 10.0.50.24 198.51.100.66 80); [ "$r" = open ] && ok "torrent host -> listed address: connects" || bad "torrent host -> listed address: $r"
r=$(dns $TRUNK 10.0.50.24 bad.example); [ "$r" = answered ] && ok "torrent host, DNS question for a listed name: answered" || bad "torrent host DNS: $r"
r=$(http $TRUNK 10.0.50.24 198.51.100.10 bad.example /); [ "$r" = "HTTP/1.1 200 OK" ] && ok "torrent host, HTTP to a listed name: answered" || bad "torrent host HTTP: $r"
r=$(tcp $TRUNK 2001:db8:50:0:be24:11ff:fe98:9dfc 2001:db8:ffff::66 8080); [ "$r" = open ] && ok "torrent host over IPv6 -> listed address: connects" || bad "torrent host over IPv6: $r"
r=$(tcp $TRUNK 2001:db8:50::20 2001:db8:ffff::66 8080); [ "$r" = silent ] && ok "another LAN host over IPv6 -> listed address: no connection" || bad "LAN host over IPv6 -> listed address: $r"
n=$(events '10\.0\.50\.24\|be24:11ff:fe98:9dfc'); [ "$n" = 0 ] && ok "no event in the log has the torrent host's addresses" || bad "$n events have the torrent host's addresses"

echo "== unblock: the pass rules of \`router unblock\`"
python3 - "$SRC/usr/local/sbin/router" > "$LAB/rules/unblock.rules" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("router", sys.argv[1]); spec = importlib.util.spec_from_loader("router", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.stdout.write(m.unblock_rules(["bad.example", "198.51.100.66"]))
PY
t0=$(date +%s.%N); sc reload-rules >/dev/null; t1=$(date +%s.%N)
echo "  (rules loaded again in $(python3 -c "print(round($t1-$t0,1))") s with this small rule set)"
r=$(dns $TRUNK 10.0.50.20 cdn.bad.example); [ "$r" = answered ] && ok "DNS question for the unblocked name: answered" || bad "DNS for the unblocked name: $r"
r=$(http $TRUNK 10.0.50.20 198.51.100.10 bad.example /); [ "$r" = "HTTP/1.1 200 OK" ] && ok "HTTP to the unblocked name: answered" || bad "HTTP to the unblocked name: $r"
r=$(tcp $TRUNK 10.0.50.20 198.51.100.66 80); [ "$r" = open ] && ok "LAN -> the unblocked address: connects" || bad "LAN -> the unblocked address: $r"
r=$(tls $TRUNK 10.0.50.20 198.51.100.10 evil.test); [ "$r" = failed ] && ok "a name that is still listed: still blocked" || bad "a name that is still listed: $r"
[ "$(events '"hostname":"bad.example"')" -ge 1 ] && ok "the unblocked name is still logged" || bad "the unblocked name is not logged"

echo "== Suricata does not answer: the watchdog"
# Without the watchdog, new connections wait until 4,096 packets are in the queue.
kill -STOP $SURI
r=$(tcp $TRUNK 10.0.50.20 198.51.100.10 80); w=$(awk '$1==0{print $3}' /proc/net/netfilter/nfnetlink_queue)
[ "$r" = silent ] && echo "  (Suricata frozen, no watchdog: a new connection waits; $w packets in the queue)" || echo "  (Suricata frozen, no watchdog: $r)"
kill -CONT $SURI; sleep 1
r=$(tcp $TRUNK 10.0.50.20 198.51.100.10 80); [ "$r" = open ] && ok "after a short freeze: connections open again" || bad "after a short freeze: $r"
# With it: files/usr/local/sbin/suricata-watchdog, which here kills the lab's Suricata.
INTERVAL=1 KILL="kill -9 $SURI" sh "$SRC/usr/local/sbin/suricata-watchdog" >/dev/null 2>&1 &
WD=$!
kill -STOP $SURI; t0=$(date +%s.%N)
# Traffic that piles up in the queue, as a house makes it.
for i in $(seq 1 30); do in_ $TRUNK python3 -c "
import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for p in range(20000,20003): s.sendto(b'x',('198.51.100.10',p+$i))"; done
n=0; for i in $(seq 1 12); do [ "$(tcp $TRUNK 10.0.50.20 198.51.100.10 80)" = open ] && { n=$i; break; }; done; t1=$(date +%s.%N)
[ $n -gt 0 ] && ok "Suricata frozen: the watchdog killed it, and a connection opened after $(python3 -c "print(round($t1-$t0))") s" || bad "Suricata frozen: no connection opened in $(python3 -c "print(round($t1-$t0))") s"
kill $WD 2>/dev/null
echo "== Suricata does not run: the internet stays"
kill -9 $SURI 2>/dev/null; sleep 0.5
r=$(tcp $TRUNK 10.0.50.20 198.51.100.10 80); [ "$r" = open ] && ok "Suricata killed: a new connection opens at once" || bad "Suricata killed: $r"
r=$(tcp $TRUNK 10.0.50.20 198.51.100.66 80); [ "$r" = open ] && ok "Suricata killed: nothing is blocked (the listed address connects)" || bad "Suricata killed, listed address: $r"
r=$(dns $TRUNK 10.0.50.20 www.good.example); [ "$r" = answered ] && ok "Suricata killed: DNS is answered" || bad "Suricata killed, DNS: $r"
SURI=""
echo "RESULT: $PASS passed, $FAIL failed"
exit $FAIL
