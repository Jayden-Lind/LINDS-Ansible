#!/usr/bin/env bash
# Print the issuer, subject, alternative names and expiry of the certificate a
# TLS endpoint serves.
#   read-served.sh <host:port> <servername>
# openssl s_client exits non-zero when it cannot verify the chain, which is
# expected here (the control node need not trust the issuer), so that exit is
# dropped; the result is openssl x509's.
set -euo pipefail
EP=$1 SRV=$2
{ echo | openssl s_client -connect "$EP" -servername "$SRV" 2>/dev/null || true; } \
  | openssl x509 -noout -issuer -subject -ext subjectAltName -enddate
