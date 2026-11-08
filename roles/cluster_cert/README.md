# cluster_cert

The role gives a device a TLS certificate signed by the cluster certificate
authority.

## What it does

1. Reads the certificate the device serves now.
2. Stops, if the certificate is already from `linds-CA` and is not near expiry.
3. Makes a private key and a signing request on the control node.
4. Asks cert-manager in the cluster to sign the request.
5. Installs the key and the certificate on the device, the way that device
   needs.
6. Reads the device again until it serves the new certificate. The check
   compares the SHA-256 fingerprint, so a renewal is proved too.

The private key stays on the control node. Only the signing request, which
holds the public key, goes to the cluster.

## Requirements

- `kubectl` on the control node, set to the homelab cluster, with rights to
  create a `CertificateRequest` in the `device-certs` namespace.
- `openssl`, `base64`, `curl` and `python3` on the control node.
- For a `proxmox`, `truenas` or `unifi` device: SSH to the device as a user
  that can install the certificate.
- For an `ami` device: the controller login in the vault, in `host_vars`. The
  device is skipped until it is set.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `cluster_cert_kind` | `proxmox` | The device type: `proxmox`, `truenas`, `unifi`, `ami` or `idrac8`. |
| `cluster_cert_common_name` | `{{ inventory_hostname }}` | The name in the certificate. |
| `cluster_cert_dns_names` | `[{{ cluster_cert_common_name }}]` | The DNS names in the certificate. |
| `cluster_cert_ip_addresses` | `[]` | The IP addresses in the certificate. |
| `cluster_cert_issuer` | `linds-ca` | The cluster issuer that signs. |
| `cluster_cert_namespace` | `device-certs` | The namespace for the signing request. |
| `cluster_cert_duration` | `8760h` | How long the certificate is valid. |
| `cluster_cert_renew_before_days` | `30` | Replace the certificate inside this window. |
| `cluster_cert_endpoint_host` | `{{ ansible_host }}` | The address read to check and prove the certificate. |
| `cluster_cert_endpoint_port` | per kind | The TLS port read. |
| `cluster_cert_verify_retries` | `20` | How many times, 3 seconds apart, the new certificate is looked for. |
| `cluster_cert_bmc_user` | `""` | The baseboard controller login name. |
| `cluster_cert_bmc_password` | `""` | The baseboard controller login password. |

## Device kinds

| Kind | Device | How the certificate is installed |
| --- | --- | --- |
| `proxmox` | Proxmox VE node | `pvenode cert set`, which restarts the web proxy. |
| `truenas` | TrueNAS SCALE | `midclt`: import, set as the web interface certificate, restart the interface. |
| `unifi` | UniFi OS console | Copies the files to `/data/unifi-core/config`, restarts `unifi-core`. |
| `ami` | SR635/SR655 baseboard controller (AMI MegaRAC) | The controller web API, the same call as its "Upload SSL" page (`files/ami-upload.sh`). |
| `idrac8` | Dell iDRAC8 | None. The host is skipped. |

## How to use it

Run `playbooks/certificates.yml`. The play applies this role to the hosts in
the `cluster_cert` group.

## Safety

- **CAUTION:** The install restarts the device web service. The web interface
  drops for a few seconds. SSH, IPMI, API tokens and running guests are not
  touched.
- **NOTE:** The role is safe to re-run. A device with a current certificate is
  left alone.

## Known problems

### SR635/SR655 baseboard controller (`ami`)

- The upload must hold the certificate and then the CA certificate. With the
  certificate alone, the web server cannot start TLS. Every HTTPS connection
  then fails with the TLS alert "internal error", and Redfish stops too.
- Do not use the Redfish `GenerateCSR` and `ReplaceCertificate` actions on this
  controller. They cause the same failure.
- To recover from that failure, run these two commands on the host. The
  controller then makes a new self-signed certificate. It keeps its network and
  user settings.

      ipmitool raw 0x32 0x66
      ipmitool mc reset cold

  HTTPS answers again after about 4 minutes, and Redfish after about 5.
- **CAUTION:** The recovery also resets the controller's date and time
  settings. Set them again: NTP server `10.0.50.1`, "automatic". Use the web
  page (Settings, Date & Time) or `PUT /api/settings/date-time` with
  `ntp_auto_date` set to `1`. Use the address, not a name: the controller has
  no DNS server. Its NTP client does not correct a large error, so set the
  time by hand first.

### Dell iDRAC8 (`idrac8`)

- No install method works yet, so the role skips the host.
- The WS-Man method `GenerateSSLCSR` makes a good signing request, from the
  `iDRAC.Security.Csr*` settings. It needs `CsrEmailAddr` set. Write
  `CsrSubjectAltName` as `name,address`, without `DNS:` or `IP:`.
- The WS-Man method `ImportSSLCertificate` refuses every certificate with
  "Certificate import operation failed" (`LC011`). The SSH `racadm` cannot
  upload a certificate. Dell's remote `racadm` can, but the role does not use
  it.
- The iDRAC8 signing request asks for no extended key usage. A certificate made
  from it has none, and Apple devices refuse such a server certificate.

## Files

| File | What it does |
| --- | --- |
| `files/vend.sh` | Makes a key and a signing request, and gets the cluster to sign it. |
| `files/sign-csr.sh` | Gets the cluster to sign a request that a device made itself. Takes the usages from the request. |
| `files/ami-upload.sh` | Uploads a certificate chain and key to an `ami` controller. |
| `files/read-served.sh` | Prints the certificate a TLS endpoint serves, with its fingerprint. |
