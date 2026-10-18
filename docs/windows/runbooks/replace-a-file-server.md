# Replace a file server

Use this runbook to rebuild a file server that is not a domain controller,
with the same name and address. The data disk moves from the old VM to the new
one. Clients use the same names after the swap.

`jd-fs-01` is the example in this runbook: VM 1103 (old) and VM 1113 (new) on
`jd-proxmox-02`, data disk `NAS-SSD:vm-1103-disk-0` on `D:`.

## Before you start

1. Build the new VM and prepare it while the old server is in service (see
   [build-a-server.md](../build-a-server.md), steps 1 to 4: Terraform,
   `windows-prepare.yml`, `windows-edition.yml`).
2. Make sure that each replicated folder has no backlog in both directions:

   ```shell
   dfsrdiag backlog /rgname:NAS /rfname:<folder> /smem:<member> /rmem:<partner>
   ```

3. Run `ansible-playbook playbooks/windows-capture.yml` and commit, so that you
   can compare after.
4. Make sure that the inventory has the settings of the server:
   `windows_vm` with the data disk in `inventory/windows.yml`, and the shares
   in `inventory/host_vars/<fqdn>/`.
5. Tell the users of the shares. The shares stop for about one hour.

**CAUTION:** After the swap the server joins its replication group again. Its
partner is then the reference: where a file is different, the partner's copy
wins. Do the swap only when the backlog in step 2 is 0 in both directions.

## Procedure

1. Run the file check. It stops if the server has files that its partner does
   not have:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn> --tags unique-files
   ```

2. Retire the old server. It leaves its replication group and stops, and its
   computer account and DNS records are removed. **The shares stop here.**

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn>
   ```

3. On the Proxmox host: `qm set <old vmid> --onboot 0 --name <name>-old`.
4. Attach the data disk to the new VM. Then start the new VM if it is stopped:

   ```shell
   ansible-playbook playbooks/windows-data-disk.yml -e target=<fqdn>
   ```

5. Join the new server to the domain:

   ```shell
   ansible-playbook playbooks/windows-join.yml -e target=<fqdn> -e bootstrap_address=<DHCP address>
   ```

6. Make it the file server. This brings `D:` online and makes the shares:

   ```shell
   ansible-playbook playbooks/windows-promote.yml -e target=<fqdn>
   ```

   **The shares are back here.**
7. Add the server to the group `windows_managed` in `inventory/windows.yml`.
   Then run `ansible-playbook playbooks/windows.yml`. This adds the server to
   its replication group again, and applies the baseline GPO.
8. Run `ansible-playbook playbooks/windows-capture.yml`, and commit the
   inventory and `windows-state/`.

**WARNING:** Do not start the old VM again. It owns the data disk, and two
machines that write to one volume destroy it.

**NOTE:** If a step fails, correct the cause and run the same command again.

## What to check after

- The shares answer, and the clients can read and write.
- The SMB settings are the same as before: for `jd-fs-01`, signing is not
  required (`Get-SmbServerConfiguration | Select RequireSecuritySignature`).
- Each replicated folder goes to "normal". The member checks every file again,
  which takes more than a day for 5 TiB (see [replication.md](replication.md)).
- Remount the NFS clients and restart the programs that keep a connection
  open, for example the cluster workloads that use the share.
