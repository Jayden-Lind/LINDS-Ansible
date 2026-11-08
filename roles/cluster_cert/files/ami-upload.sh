#!/usr/bin/env bash
# Upload a certificate chain and its private key to an AMI MegaRAC controller
# (the baseboard controller of an SR635 or SR655) through the controller's own
# web API. This is the call its web page makes for "Upload SSL": log in, send
# the two files, then send certificate-info back, which applies them.
#
# Usage: ami-upload.sh <address> <user> <chain-file> <key-file>
# The password is read from the environment variable CLUSTER_CERT_BMC_PASSWORD.
#
# The chain file must hold the certificate followed by the issuing CA
# certificate. With the certificate alone the controller's web server cannot
# start TLS, and every HTTPS connection fails until the controller is reset to
# defaults (see the role README).
#
# Prints the controller's replies and "UPLOADED" when they show success.
set -euo pipefail
BMC=$1 BMC_USER=$2 CHAIN=$3 KEY=$4
: "${CLUSTER_CERT_BMC_PASSWORD:?set CLUSTER_CERT_BMC_PASSWORD}"
W=$(mktemp -d); chmod 700 "$W"; trap 'rm -rf "$W"' EXIT
A="https://$BMC/api"
printf '%s' "$CLUSTER_CERT_BMC_PASSWORD" > "$W/pw"; chmod 600 "$W/pw"

field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null; }

curl -sk -m 30 -c "$W/jar" -o "$W/login.json" \
  --data-urlencode "username=$BMC_USER" --data-urlencode "password@$W/pw" "$A/session"
T=$(field "$W/login.json" CSRFToken)
[ -n "$T" ] || { echo "LOGIN FAILED"; exit 1; }
H=(-b "$W/jar" -c "$W/jar" -H "X-CSRFTOKEN: $T")

curl -sk -m 30 "${H[@]}" -o "$W/info.json" "$A/settings/ssl/certificate-info"
curl -sk -m 90 "${H[@]}" -o "$W/up.json" \
  -F "new_certificate=@$CHAIN;type=application/x-x509-ca-cert" \
  -F "new_private_key=@$KEY;type=application/octet-stream" "$A/settings/ssl/certificate"
echo "upload: $(cat "$W/up.json")"
[ "$(field "$W/up.json" cc)" = 0 ] || { echo "UPLOAD FAILED"; exit 1; }

# The web server restarts after this, which also ends the session.
curl -sk -m 60 "${H[@]}" -X PUT -H 'Content-Type: application/json' \
  --data-binary @"$W/info.json" -o "$W/put.json" "$A/settings/ssl/certificate-info"
echo "apply: $(cat "$W/put.json")"
[ "$(field "$W/put.json" certificate_available)" = 1 ] || { echo "APPLY FAILED"; exit 1; }
echo "UPLOADED"
