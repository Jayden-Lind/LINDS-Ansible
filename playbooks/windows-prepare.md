# windows-prepare.yml

The playbook applies the baseline and all Windows updates to a new clone of
the template, at its DHCP address. It is the first step to build a server.

## Before you start

- The VM exists. LINDS-Terraform makes it from the template.
- The host is in `inventory/windows.yml` with its `windows_*` variables.
- You know the DHCP address of the clone
  (`terraform output windows_bootstrap_addresses`, or the Proxmox summary).

## Procedure

1. Run the playbook:

   ```shell
   ansible-playbook playbooks/windows-prepare.yml -e target=<fqdn> -e bootstrap_address=<DHCP address>
   ```

2. Wait. The updates take about one hour.

**NOTE:** The playbook connects as the local Administrator with NTLM. It does
not need a Kerberos ticket. It does not change the domain, so you can run it
while the old server with the same name is in service.

## What it changes

- The clone only: the baseline settings and the updates.

## If it fails

- "credentials were rejected": wait. Windows setup refuses logons until it is
  complete. Server 2025 also locks the account for 10 minutes after 10 bad
  logons.
- The update step fails with a loop: see "Known problems" in
  `roles/windows_baseline/README.md`.

## Next step

`playbooks/windows-edition.md`.
