"""Jinja filters for roles/router.

One job: VyOS's PKI store keeps certificates and keys as bare base64 DER, and
those are the vault values this role inherits. strongSwan wants files, so
they are wrapped as PEM on the way in (a key gets the label its DER structure
needs).
"""
import base64
import re


def _der_key_label(der):
    """PEM label for a DER private key: PKCS#8, PKCS#1 RSA or SEC1 EC."""
    # SEQUENCE header: 0x30, then a length (short form or 0x8N + N bytes).
    if len(der) < 8 or der[0] != 0x30:
        return 'PRIVATE KEY'
    i = 2 + (der[1] - 0x80 if der[1] & 0x80 else 0)
    # First element is always INTEGER version: 02 01 <v>
    if der[i] != 0x02:
        return 'PRIVATE KEY'
    version = der[i + 2]
    nxt = der[i + 3]
    if version == 0 and nxt == 0x30:
        return 'PRIVATE KEY'          # PKCS#8: version, AlgorithmIdentifier SEQUENCE
    if version == 0 and nxt == 0x02:
        return 'RSA PRIVATE KEY'      # PKCS#1: version, modulus INTEGER
    if version == 1 and nxt == 0x04:
        return 'EC PRIVATE KEY'       # SEC1: version 1, privateKey OCTET STRING
    return 'PRIVATE KEY'


def to_pem(value, kind='certificate'):
    """Wrap a VyOS PKI blob (bare base64 DER) as PEM. PEM input passes through.

    kind: 'certificate' or 'key'.
    """
    value = value.strip()
    if '-----BEGIN' in value:
        return value if value.endswith('\n') else value + '\n'
    b64 = re.sub(r'\s+', '', value)
    der = base64.b64decode(b64, validate=True)
    label = _der_key_label(der) if kind == 'key' else 'CERTIFICATE'
    body = '\n'.join(b64[i:i + 64] for i in range(0, len(b64), 64))
    return f"-----BEGIN {label}-----\n{body}\n-----END {label}-----\n"


class FilterModule:
    def filters(self):
        return {'to_pem': to_pem}
