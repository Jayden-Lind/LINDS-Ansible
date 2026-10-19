# Replace a file server

Use this runbook to rebuild a file server that is not a domain controller,
with the same name and address. The data disk moves from the old VM to the new
one. Clients use the same names after the swap.

`jd-fs-01` is the example in this runbook: VM 1103 (old) and VM 1113 (new) on
`jd-proxmox-02`, data disk on `D:`.

There are two ways to move the data disk:

- **Reassign** (used for `jd-fs-01`): Proxmox renames the volume to the new VM.
  The old VM then owns nothing and can be deleted later.
- **Attach by reference** (used for `linds-dc`): the old VM keeps the volume,
  and the new VM uses it. The old VM must stay, and must never run.

## Before you start

**CAUTION:** Pause the deploy on `jd-jump-01` before step 1:
`touch ~/.local/state/linds-ansible-deploy/paused`. A deploy of `windows.yml`
can change a server that is not complete. Remove the file after the last
step of the procedure. See [deploy/README.md](../../../deploy/README.md).

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
4. Move the data disk to the new VM.
   - To reassign: stop the new VM, then move the disk. Set the new volume name
     (`qm config <new vmid>`) in `windows_vm.data_disks` of the inventory, and
     start the new VM:

     ```shell
     qm shutdown <new vmid>
     qm disk move <old vmid> scsi1 --target-vmid <new vmid> --target-disk scsi1
     qm start <new vmid>
     ```

   - To attach by reference: run the playbook. Then start the new VM if it is
     stopped:

     ```shell
     ansible-playbook playbooks/windows-data-disk.yml -e target=<fqdn>
     ```

   **CAUTION:** Both VMs must be stopped for a reassign. Proxmox refuses it
   while one of them runs.

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

**WARNING:** Do not start the old VM again. It would come up with the name
and the address of the new server. After an attach by reference it also owns
the data disk, and two machines that write to one volume destroy it.

**NOTE:** If a step fails, correct the cause and run the same command again.

## What to check after

- The shares answer, and the clients can read and write.
- The SMB settings are the same as before: for `jd-fs-01`, signing is not
  required (`Get-SmbServerConfiguration | Select RequireSecuritySignature`).
- Each replicated folder goes to "normal". The member checks every file again,
  which takes more than a day for 5 TiB (see [replication.md](replication.md)).
- The cluster volumes reconnect by themselves. For `jd-fs-01` they log on as
  the local `Administrator`: give it the password of the Vault secret
  `smb-immich-creds` first (see the known problems of
  `roles/windows_fileserver/README.md`). Check with a write from the Immich
  pod and a listing from the Plex pod.
- Remount the NFS clients and restart the programs that keep a connection
  open.
