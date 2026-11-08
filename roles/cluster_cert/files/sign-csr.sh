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

# cert-manager refuses a request whose usages differ from the usages it is
# asked for, and devices ask for different ones (an iDRAC8 adds Non
# Repudiation). So take the usages from the request itself. Once a request has
# a key usage extension, cert-manager compares the extended key usages too, so
# such a request gets exactly what it asked for (an iDRAC8 asks for no extended
# key usage). Only a request with no usage extensions at all gets the defaults:
# digital signature, key encipherment, server auth.
USAGES=$(openssl req -in "$CSR" -noout -text | python3 -I -c '
import sys
text = sys.stdin.read().splitlines()
def ext(name):
    for i, line in enumerate(text):
        if line.strip().startswith(name):
            return [p.strip() for p in text[i + 1].split(",") if p.strip()]
    return None
ku_map = {"Digital Signature": "digital signature", "Non Repudiation": "content commitment",
          "Key Encipherment": "key encipherment", "Data Encipherment": "data encipherment",
          "Key Agreement": "key agreement", "Certificate Sign": "cert sign", "CRL Sign": "crl sign",
          "Encipher Only": "encipher only", "Decipher Only": "decipher only"}
eku_map = {"TLS Web Server Authentication": "server auth", "TLS Web Client Authentication": "client auth"}
ku = ext("X509v3 Key Usage")
eku = ext("X509v3 Extended Key Usage")
if ku is None and eku is None:
    u = ["digital signature", "key encipherment", "server auth"]
else:
    u = [ku_map[k] for k in (ku or []) if k in ku_map] + [eku_map[k] for k in (eku or []) if k in eku_map]
print(", ".join(u))
')
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
  usages: [${USAGES}]
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
