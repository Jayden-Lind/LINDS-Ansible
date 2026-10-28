# certificates.yml

The playbook gives each device a TLS certificate signed by the cluster
certificate authority.

## What it does

The play applies the `cluster_cert` role to the hosts in the `cluster_cert`
group (`inventory/certificates.yml`). For each device it keeps the current
certificate, or replaces it with a new one from the cluster. See
`roles/cluster_cert/README.md`.

## Requirements

1. `kubectl` on the control node, set to the homelab cluster.
2. The `device-certs` namespace in the cluster, with the `linds-ca` issuer.
3. SSH to each `proxmox`, `truenas` and `unifi` device.
4. A vault login for each `redfish` device (a baseboard controller), or the
   device is skipped.

## How to use it

1. Run the playbook:

       ansible-playbook playbooks/certificates.yml

2. To do one device, add `--limit <host>`.
3. To see what would change, read the output: a device with a current
   certificate reports "certificate current, nothing to do".

## Safety

- **CAUTION:** Each install restarts the device web service, which drops the
  web interface for a few seconds.
- **NOTE:** This playbook is not part of the merge-to-deploy set. A renewal is
  a change the deploy would read as drift. Run it by hand, or from its own
  timer.
- **NOTE:** The playbook is safe to re-run and to run on a timer.
