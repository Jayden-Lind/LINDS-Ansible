#!/usr/bin/env bash
# Talk to a Dell iDRAC8 through the calls its own web GUI makes.
#
# Usage:
#   idrac8.sh csr <address> <user> <out-file> <cn> <o> <ou> <l> <st> <c> <email> <san>
#       The iDRAC makes a new key and a signing request ("Generate CSR"). The
#       key stays on the iDRAC. <san> holds up to 4 names and addresses,
#       comma separated. The iDRAC needs every field.
#   idrac8.sh install <address> <user> <certificate-file>
#       Uploads the signed certificate ("Upload Server Certificate"), then
#       resets the iDRAC so that its web server loads it. The iDRAC answers
#       again after about 3 minutes, and its Redfish service some minutes later.
#
# The password is read from the environment variable CLUSTER_CERT_BMC_PASSWORD.
# Prints the iDRAC's replies, then "CSR MADE" or "UPLOADED" when they show
# success.
#
# Use these calls, not WS-Man: on iDRAC8 2.86 the WS-Man ImportSSLCertificate
# method refuses every certificate ("Certificate import operation failed",
# LC011).
set -euo pipefail
cmd=$1 BMC=$2 BMC_USER=$3; shift 3
: "${CLUSTER_CERT_BMC_PASSWORD:?set CLUSTER_CERT_BMC_PASSWORD}"
G="https://$BMC"
W=$(mktemp -d); chmod 700 "$W"; J=$W/jar
ST1='' ST2=''
logout() { if [ -n "$ST2" ]; then curl -sk -m 20 --compressed -b "$J" -H "ST2: $ST2" -o /dev/null "$G/data/logout" || true; fi; }
trap 'logout; rm -rf "$W"' EXIT

# Log in as the login page does: /data/logout, then /data/login. The session
# is the cookie plus the ST1 and ST2 tokens from the forward URL.
python3 -I -c '
import os, sys, urllib.parse as u
sys.stdout.write("user=" + u.quote(sys.argv[1], safe="") + "&password=" + u.quote(os.environ["CLUSTER_CERT_BMC_PASSWORD"], safe=""))
' "$BMC_USER" > "$W/login"
curl -sk -m 20 --compressed -c "$J" -b "$J" -o /dev/null "$G/data/logout" || true
curl -sk -m 30 --compressed -c "$J" -b "$J" -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary @"$W/login" -o "$W/login.xml" "$G/data/login"
rm -f "$W/login"
fwd=$(grep -o '<forwardUrl>[^<]*' "$W/login.xml" | cut -d'>' -f2 || true)
ST1=$(printf '%s' "$fwd" | grep -o 'ST1=[^,&]*' | cut -d= -f2 || true)
ST2=$(printf '%s' "$fwd" | grep -o 'ST2=[^,&]*' | cut -d= -f2 || true)
if [ -z "$ST1" ] || [ -z "$ST2" ]; then
  echo "LOGIN FAILED: authResult $(grep -o '<authResult>[^<]*' "$W/login.xml" | cut -d'>' -f2 || true)"
  exit 1
fi

case $cmd in
csr)
  out=$1; shift
  # The fields are escaped as the page's escapeStr() does (@ ( ) , : ? = &
  # become "@0" and the hex code), then URL-encoded. The country is sent as is.
  q=$(python3 -I -c '
import sys, urllib.parse as u
def esc(s):
    s = s.replace("\\", "\\\\")
    return u.quote("".join("@0%x" % ord(c) if c in "@(),:?=&" else c for c in s), safe="-_.!~*()\x27")
cn, o, ou, l, st, c, email, san = sys.argv[1:9]
print(",".join([esc(cn), esc(o), esc(ou), esc(l), esc(st), c, esc(email), esc(san)]))
' "$@")
  code=$(curl -sk -m 120 --compressed -b "$J" -c "$J" -H "ST2: $ST2" -o "$W/csr" -w '%{http_code}' \
    "$G/bindata?set=serverCSR($q)")
  echo "csr: http=$code"
  if [ "$code" = 200 ] && grep -q 'BEGIN CERTIFICATE REQUEST' "$W/csr"; then
    tr -d '\r' < "$W/csr" > "$out"
    echo "CSR MADE"
  else
    echo "reply: $(head -c 300 "$W/csr")"
    exit 1
  fi
  ;;
install)
  crt=$1
  # A plain form post to the GUI file store: ST1 in the query, no ST2 header.
  code=$(curl -sk -m 60 --compressed -b "$J" -c "$J" -o "$W/store.json" -w '%{http_code}' \
    -F "serverSSLCertificate=@$crt;filename=server.cer;type=application/x-x509-ca-cert" -F "CertType=2" \
    "$G/sysmgmt/2012/server/transient/filestore?fileupload=true&ST1=$ST1")
  echo "file store: http=$code reply=$(head -c 300 "$W/store.json")"
  uri=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["File"]["ResourceURI"])' "$W/store.json" 2>/dev/null || true)
  [ -n "$uri" ] || { echo "UPLOAD FAILED"; exit 1; }

  code=$(curl -sk -m 90 --compressed -b "$J" -c "$J" -H "ST2: $ST2" \
    -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
    --data-binary "{\"ResourceURI\":\"$uri\"}" -o "$W/cert.json" -w '%{http_code}' \
    "$G/sysmgmt/2012/server/network/ssl/cert")
  echo "certificate: http=$code reply=$(head -c 300 "$W/cert.json")"
  case $code in 2??) ;; *) echo "APPLY FAILED"; exit 1 ;; esac

  # "Reset iDRAC now". The reset ends the session, so there is no logout.
  code=$(curl -sk -m 60 --compressed -b "$J" -c "$J" -H "ST2: $ST2" -X POST -o "$W/reset.xml" -w '%{http_code}' \
    "$G/data?set=iDracReset:1")
  echo "reset: http=$code reply=$(tr -d '\n' < "$W/reset.xml" | head -c 200)"
  grep -q '<status>ok</status>' "$W/reset.xml" || { echo "RESET FAILED"; exit 1; }
  ST2=''
  echo "UPLOADED"
  ;;
*)
  echo "unknown command: $cmd"; exit 2 ;;
esac
