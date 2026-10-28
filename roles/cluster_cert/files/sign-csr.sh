#!/usr/bin/env bash
# Sign a certificate signing request that a device made itself, so the device
# keeps its own private key. Reads a PEM request, asks cert-manager to sign it,
# writes the signed certificate and the issuer certificate.
#
# Usage: sign-csr.sh <csr-file> <out-dir> <duration> <issuer> <namespace>
set -euo pipefail
CSR=$1 OUT=$2 DUR=$3 ISSUER=$4 NS=$5
mkdir -p "$OUT"; chmod 700 "$OUT"
name="sign-$(date +%s)-$RANDOM"
cat > "$OUT/cr.yaml" <<YAML
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  request: $(base64 -w0 "$CSR")
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
echo "SIGNED $name"
