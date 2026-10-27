# Replace a domain controller

Use this runbook to rebuild a domain controller with the same name and
address. Nothing that refers to the server changes: DNS forwarders, LDAP URLs
and the inventory stay the same.

Done for `linds-dc2` on 11 October 2026 (31 minutes) and for `linds-dc` on 12
October 2026 (2 hours 17 minutes, with the CA and the NAS).

## Before you start

**CAUTION:** Pause the deploy of `windows.yml` on `jd-jump-01` before step 1:
`touch ~/.local/state/linds-ansible-deploy/paused.windows`. Otherwise a merge
can change a server that is not complete. After the last step, remove the
file and run `linds-ansible-deploy --retry`. See [deploy/README.md](../../../deploy/README.md).

1. Make sure that `repadmin /replsummary` shows no errors.
2. Run `netdom query fsmo`. The retirement moves the FSMO roles of the server
   to its partner.
3. Make sure that every DNS zone of the server is AD-integrated:
   `Get-DnsServerZone | Where-Object { -not $_.IsDsIntegrated -and -not $_.IsAutoCreated }`
   must show nothing.
4. Make a list of what is on the server and not in code: shares other than
   SYSVOL and NETLOGON, scheduled tasks, software, certificates with private
   keys. The rebuild does not keep them.
5. Run `ansible-playbook playbooks/windows-capture.yml` and commit, so that
   you can compare after.
6. Make the new VM, then run `windows-prepare.yml` and `windows-edition.yml`
   for it (see [build-a-server.md](../build-a-server.md), steps 1 to 4). The
   old server stays in service.
7. For a replication member, run the file check:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn> --tags unique-files
   ```

## Procedure

1. Retire the old server, and keep its bridgehead for the new one:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn> -e windows_dc_retire_keep_bridgehead=true
   ```

2. On the Proxmox host: `qm set <old vmid> --onboot 0 --name <name>-old`.
3. For a file server with a data disk, attach the disk:

   ```shell
   ansible-playbook playbooks/windows-data-disk.yml -e target=<fqdn>
   ```

4. Join the new server to the domain:

   ```shell
   ansible-playbook playbooks/windows-join.yml -e target=<fqdn> -e bootstrap_address=<DHCP address>
   ```

5. Promote it:
   `ansible-playbook playbooks/windows-promote.yml -e target=<fqdn>`.
6. Run `ansible-playbook playbooks/windows.yml`. For a replication member, this
   adds it to the replication group again.
7. Record the state, and commit `windows-state/`. For the CA, also back it up:

   ```shell
   ansible-playbook playbooks/windows-ca-backup.yml
   ansible-playbook playbooks/windows-capture.yml
   ```

**WARNING:** Do not start the old VM again. It would come up at the address of
the new server.

**NOTE:** If a step fails, correct the cause and run the same command again.

## What to check after

- `dcdiag` shows no failures. `repadmin /replsummary` shows no errors.
- `repadmin /showrepl` on each domain controller shows no failing link.
- `netdom query fsmo` shows the roles at the correct servers.
  `ansible-playbook playbooks/windows.yml` puts them back.
- For the CA: `certutil -ping` answers, and the CA certificate has the same
  thumbprint as before.
- For a file server: the volume, the shares and the NFS exports are there.
  Remount the NFS clients.
- For a replication member: the folders go to "normal". This can take more
  than a day (see [replication.md](replication.md)).

## Data disks

A data disk outlives its server. It belongs to the old VM, and the new VM uses
it by reference. Proxmox deletes only the volumes that carry the ID of the VM
that it deletes. Thus:

**WARNING:** Keep the old VM that owns the data disk. On the LINDS host, VM 102
owns `NAS:vm-102-disk-0`, and VM 113 uses it. Never delete VM 102 and never
start it.

**WARNING:** The LINDS-Backup VM (104) uses the same disk for its Backblaze
runs. Stop VM 113 before you start VM 104, and the reverse.

**CAUTION:** Change the options of the shared disk on VM 104 or VM 113 only
while that VM is stopped. On a running VM, Proxmox can unplug the disk.

## Other machines

Other machines with their own Kerberos ticket cache keep a ticket for the old
server. Their connections to the new server fail until the ticket expires.
Run `kinit -R` (Linux) or `klist purge` (Windows) on them.

## Known problems

- The first convergence after a promotion can run out of time ("JD-DC-01
  reachable=False ... no inbound replication partner"). The partner did not
  yet resolve the new server, whose DNS record the retirement had removed. If
  `repadmin /showrepl` on the new server shows successful inbound
  replication, run `windows-promote.yml` again. Each step that is complete
  does nothing.
- A zone transfer setting belongs to each DNS server and does not replicate.
  A new domain controller refuses transfers until `windows.yml` (tag `dc`)
  sets `windows_dc_dns_zone_transfers`. external-dns needs it on `jd-dc-01`.
- A domain controller with the CA role installed cannot be demoted, also when
  no CA is configured. The retirement removes such a role first.
