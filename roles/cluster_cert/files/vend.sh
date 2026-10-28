#!/usr/bin/env bash
# Vend a server certificate from the cluster certificate authority.
#
# The cluster runs cert-manager with the "linds-ca" ClusterIssuer. This script
# makes a private key and a certificate signing request, asks cert-manager to
# sign the request, and writes the key and the signed certificate to a
# directory. The private key stays on this machine; only the request, which
# holds the public key, goes to the cluster.
#
# Usage:
#   vend.sh <out-dir> <common-name> <dns-names> <ip-addresses> <duration> \
#           <issuer> <namespace> <renew-before-days> <endpoint>
#
#   dns-names, ip-addresses  Comma separated. Either may be empty ("").
#   endpoint                 host:port that already serves TLS, or "" for none.
#                            If it serves a certificate from <issuer> that is
#                            not due to renew, the script stops with RC 10 and
#                            vends nothing.
#
# Output files in <out-dir>: tls.key, tls.crt (leaf), ca.crt (issuer),
# serve.crt (leaf plus any issuer that is not a self-signed root).
set -euo pipefail

OUT=$1 CN=$2 DNS=$3 IPS=$4 DUR=$5 ISSUER=$6 NS=$7 RENEW_DAYS=$8 ENDPOINT=${9:-}
RENEW_SECS=$(( RENEW_DAYS * 86400 ))

# Is the certificate already good? Keeps re-runs from re-issuing needlessly.
if [ -n "$ENDPOINT" ]; then
  served=$(echo | openssl s_client -connect "$ENDPOINT" -servername "${CN}" 2>/dev/null </dev/null || true)
  if [ -n "$served" ]; then
    leaf=$(printf '%s' "$served" | openssl x509 2>/dev/null || true)
    if [ -n "$leaf" ] \
       && printf '%s' "$leaf" | openssl x509 -noout -issuer 2>/dev/null | grep -q 'CN *= *linds-CA' \
       && printf '%s' "$leaf" | openssl x509 -noout -checkend "$RENEW_SECS" >/dev/null 2>&1; then
      echo "CURRENT"
      exit 10
    fi
  fi
fi

mkdir -p "$OUT"; chmod 700 "$OUT"

# Build the request with its subject alternative names and key usages.
{
  echo '[req]'; echo 'distinguished_name=dn'; echo 'req_extensions=v3'; echo 'prompt=no'
  echo '[dn]'; echo "CN=${CN}"
  echo '[v3]'
  echo 'keyUsage=critical,digitalSignature,keyEncipherment'
  echo 'extendedKeyUsage=serverAuth'
  printf 'subjectAltName='
  sep=''
  IFS=','; for d in $DNS; do [ -n "$d" ] && printf '%sDNS:%s' "$sep" "$d" && sep=','; done
  for i in $IPS; do [ -n "$i" ] && printf '%sIP:%s' "$sep" "$i" && sep=','; done
  echo
} > "$OUT/csr.cnf"

openssl req -new -newkey rsa:2048 -nodes -keyout "$OUT/tls.key" \
  -config "$OUT/csr.cnf" -out "$OUT/req.csr" 2>/dev/null
chmod 600 "$OUT/tls.key"

name="vend-$(echo "$CN" | tr '.@*' '---')-$(date +%s)"
cat > "$OUT/cr.yaml" <<YAML
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  request: $(base64 -w0 "$OUT/req.csr")
  issuerRef: {name: ${ISSUER}, kind: ClusterIssuer, group: cert-manager.io}
  duration: ${DUR}
  usages: [digital signature, key encipherment, server auth]
YAML

cleanup() { kubectl -n "$NS" delete certificaterequest "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl create -f "$OUT/cr.yaml" >/dev/null
if ! kubectl -n "$NS" wait --for=condition=Ready "certificaterequest/$name" --timeout=60s >/dev/null 2>&1; then
  echo "NOT SIGNED: $(kubectl -n "$NS" get certificaterequest "$name" -o jsonpath='{.status.conditions}' 2>/dev/null)"
  exit 1
fi

kubectl -n "$NS" get certificaterequest "$name" -o jsonpath='{.status.certificate}' | base64 -d > "$OUT/tls.crt"
kubectl -n "$NS" get certificaterequest "$name" -o jsonpath='{.status.ca}'          | base64 -d > "$OUT/ca.crt"

# serve.crt is what a server presents: the leaf, then any issuer certificate
# that is not a self-signed root (the root is the trust anchor clients already
# hold, so it is not sent). Today the issuer is the root itself, so serve.crt
# is the leaf alone; once an intermediate is in place it becomes leaf+intermediate.
cp "$OUT/tls.crt" "$OUT/serve.crt"
if [ -s "$OUT/ca.crt" ]; then
  subj=$(openssl x509 -in "$OUT/ca.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
  iss=$(openssl x509 -in "$OUT/ca.crt" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  if [ "$subj" != "$iss" ]; then
    cat "$OUT/ca.crt" >> "$OUT/serve.crt"
  fi
fi

echo "VENDED $name"
