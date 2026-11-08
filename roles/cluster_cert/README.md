# cluster_cert

The role gives a device a TLS certificate signed by the cluster certificate
authority.

## What it does

1. Reads the certificate the device serves now.
2. Stops, if the certificate is already from `linds-CA` and is not near expiry.
3. Makes a private key and a signing request on the control node. An iDRAC8
   makes its own key and signing request.
4. Asks cert-manager in the cluster to sign the request.
5. Installs the certificate on the device, the way that device needs, with
   the key if the control node made it.
6. Reads the device again until it serves the new certificate. The check
   compares the SHA-256 fingerprint, so a renewal is proved too.

The private key stays on the control node, or on the iDRAC8. Only the signing
request, which holds the public key, goes to the cluster.

## Requirements

- `kubectl` on the control node, set to the homelab cluster, with rights to
  create a `CertificateRequest` in the `device-certs` namespace.
- `openssl`, `base64`, `curl` and `python3` on the control node.
- For a `proxmox`, `truenas` or `unifi` device: SSH to the device as a user
  that can install the certificate.
- For an `ami` or `idrac8` device: the controller login in the vault, in
  `host_vars`. The device is skipped until it is set.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `cluster_cert_kind` | `proxmox` | The device type: `proxmox`, `truenas`, `unifi`, `ami` or `idrac8`. |
| `cluster_cert_common_name` | `{{ inventory_hostname }}` | The name in the certificate. |
| `cluster_cert_dns_names` | `[{{ cluster_cert_common_name }}]` | The DNS names in the certificate. |
| `cluster_cert_ip_addresses` | `[]` | The IP addresses in the certificate. |
| `cluster_cert_device_subject` | LINDS values | The rest of the subject (organization, unit, locality, state, country, email), for an `idrac8` signing request. |
| `cluster_cert_issuer` | `linds-ca` | The cluster issuer that signs. |
| `cluster_cert_namespace` | `device-certs` | The namespace for the signing request. |
| `cluster_cert_duration` | `8760h` | How long the certificate is valid. |
| `cluster_cert_renew_before_days` | `30` | Replace the certificate inside this window. |
| `cluster_cert_endpoint_host` | `{{ ansible_host }}` | The address read to check and prove the certificate. |
| `cluster_cert_endpoint_port` | per kind | The TLS port read. |
| `cluster_cert_verify_retries` | per kind | How many times, 3 seconds apart, the new certificate is looked for: 20, or 100 for `idrac8`. |
| `cluster_cert_bmc_user` | `""` | The baseboard controller login name. |
| `cluster_cert_bmc_password` | `""` | The baseboard controller login password. |

## Device kinds

| Kind | Device | How the certificate is installed |
| --- | --- | --- |
| `proxmox` | Proxmox VE node | `pvenode cert set`, which restarts the web proxy. |
| `truenas` | TrueNAS SCALE | `midclt`: import, set as the web interface certificate, restart the interface. |
| `unifi` | UniFi OS console | Copies the files to `/data/unifi-core/config`, restarts `unifi-core`. |
| `ami` | SR635/SR655 baseboard controller (AMI MegaRAC) | The controller web API, the same call as its "Upload SSL" page (`files/ami-upload.sh`). |
| `idrac8` | Dell iDRAC8 | The calls of its web GUI (`files/idrac8.sh`): "Generate CSR", then "Upload Server Certificate", then an iDRAC reset. |

## How to use it

Run `playbooks/certificates.yml`. The play applies this role to the hosts in
the `cluster_cert` group.

## Safety

- **CAUTION:** The install restarts the device web service. The web interface
  drops for a few seconds. SSH, IPMI, API tokens and running guests are not
  touched.
- **CAUTION:** An iDRAC8 resets as a whole. Its web interface is away for
  about 3 minutes, and Redfish for about 7. SSH and IPMI to the iDRAC also stop
  during the reset. The host and its guests are not touched.
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

- The role uses the calls of the iDRAC web GUI. Do not use WS-Man: its
  `ImportSSLCertificate` method refuses every certificate with "Certificate
  import operation failed" (`LC011`). The SSH `racadm` cannot upload a
  certificate, and Redfish on the iDRAC8 has no certificate service.
- The iDRAC signing request asks for no extended key usage, so the certificate
  has none. Apple devices (Safari on macOS and iOS) refuse such a server
  certificate. Other browsers, `curl` and Redfish clients accept it.
- The iDRAC takes at most 4 names and addresses in the signing request.
- To go back to the Dell certificate, run `racadm sslresetcfg` over SSH on the
  iDRAC.

## Files

| File | What it does |
| --- | --- |
| `files/vend.sh` | Makes a key and a signing request, and gets the cluster to sign it. |
| `files/sign-csr.sh` | Gets the cluster to sign a request that a device made itself. Takes the usages from the request. |
| `files/ami-upload.sh` | Uploads a certificate chain and key to an `ami` controller. |
| `files/idrac8.sh` | Gets a signing request from an `idrac8`, and uploads the signed certificate to it. |
| `files/read-served.sh` | Prints the certificate a TLS endpoint serves, with its fingerprint. |
