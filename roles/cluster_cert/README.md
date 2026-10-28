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
6. Reads the device again, to prove it serves the new certificate.

The private key stays on the control node. Only the signing request, which
holds the public key, goes to the cluster.

## Requirements

- `kubectl` on the control node, set to the homelab cluster, with rights to
  create a `CertificateRequest` in the `device-certs` namespace.
- `openssl` and `base64` on the control node.
- For a `proxmox`, `truenas` or `unifi` device: SSH to the device as a user
  that can install the certificate.
- For a `redfish` device: a login, set in the vault (the device is skipped
  until then).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `cluster_cert_kind` | `proxmox` | The device type: `proxmox`, `truenas`, `unifi` or `redfish`. |
| `cluster_cert_common_name` | `{{ inventory_hostname }}` | The name in the certificate. |
| `cluster_cert_dns_names` | `[{{ cluster_cert_common_name }}]` | The DNS names in the certificate. |
| `cluster_cert_ip_addresses` | `[]` | The IP addresses in the certificate. |
| `cluster_cert_issuer` | `linds-ca` | The cluster issuer that signs. |
| `cluster_cert_namespace` | `device-certs` | The namespace for the signing request. |
| `cluster_cert_duration` | `8760h` | How long the certificate is valid. |
| `cluster_cert_renew_before_days` | `30` | Replace the certificate inside this window. |
| `cluster_cert_endpoint_host` | `{{ ansible_host }}` | The address read to check and prove the certificate. |
| `cluster_cert_endpoint_port` | per kind | The TLS port read. |
| `cluster_cert_redfish_user` | `""` | The Redfish login name. |
| `cluster_cert_redfish_password` | `""` | The Redfish login password. |

## How to use it

Run `playbooks/certificates.yml`. The play applies this role to the hosts in
the `cluster_cert` group.

## Safety

- **CAUTION:** The install restarts the device web service. The web interface
  drops for a few seconds. SSH, API tokens and running guests are not touched.
- **NOTE:** The role is safe to re-run. A device with a current certificate is
  left alone.
