# Update the VirtIO drivers

Use this runbook to update the VirtIO drivers and the QEMU guest agent on a
Windows server. The update needs one restart of the server.

The template build uses the version in LINDS-Terraform
`packer/windows/variables.pkr.hcl` (`virtio_iso_file`). A server that is
cloned from an older template keeps the drivers of that template. Use this
runbook to update it.

**WARNING:** Do not install virtio-win 0.1.285, or 0.1.215 to 0.1.262. The
[Proxmox known issues](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers#Known_Issues)
list them. On Windows Server 2025 the 0.1.285 storage drivers can return the
wrong data under load.

## Before you start

- Get a Kerberos ticket on `jd-jump-01`: `kinit -f Administrator@LINDS.COM.AU`.
  Then run the PowerShell steps with `scripts/winrun.py <fqdn> <script>`.
- Update one server at a time. Update the file server last: its shares stop
  for about one minute.
- If the deploy of `windows.yml` is on, pause it:
  `touch ~/.local/state/linds-ansible-deploy/paused.windows`.
- Make sure that no long job uses the server. A restart stops it.

## Procedure

1. Find the newest version. `latest-virtio` in
   `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/` points
   to it. Make sure that the Proxmox known issues do not list it.
2. Put the ISO on the `local` storage of both hosts, in
   `/var/lib/vz/template/iso/`.
3. On the host, get the SHA-256 of the installer in the ISO:

   ```shell
   d=$(mktemp -d) && mount -o loop,ro /var/lib/vz/template/iso/virtio-win-<version>.iso $d
   sha256sum $d/virtio-win-guest-tools.exe; umount $d; rmdir $d
   ```

4. On the server, download `virtio-win-guest-tools.exe` from the folder of the
   version into `C:\Windows\Temp\virtio-<version>\`. Compare its SHA-256 with
   the value from step 3.

   **NOTE:** Fedora People sends a browser check page (about 4 KB) to a
   browser user agent. Give a different one:
   `Invoke-WebRequest -UseBasicParsing -UserAgent 'curl/8.14.1' ...`.

5. On the host, make a snapshot of the EFI disk and the system disk of the VM.
   Do not make a snapshot of a data disk.
   - ZFS (`jd-proxmox-02`): `zfs snapshot VM/vm-<vmid>-disk-<n>@pre-virtio`.
   - LVM thin (`linds-proxmox-01`):
     `lvcreate -s -n pre-virtio-<vmid>-disk-<n> pve/vm-<vmid>-disk-<n>`. Do not
     start the name with `vm-<vmid>-`: Proxmox then shows it as a disk of the
     VM.

   **WARNING:** Before you start a domain controller from this snapshot, give
   the VM a new generation ID: `qm set <vmid> --vmgenid 1`. Otherwise the
   directory on that server rolls back (USN rollback).

6. Run the installer as `SYSTEM` in a scheduled task, not in the WinRM
   session. The network adapter and the guest agent restart during the
   install, and a WinRM session stops. Give the task this command, then
   restart Windows if the exit code is 0 or 3010:

   ```powershell
   virtio-win-guest-tools.exe /install /quiet /norestart /log C:\Windows\Temp\virtio-<version>\bundle.log
   ```

7. After the restart, make sure that:
   - `Get-CimInstance Win32_PnPSignedDriver` shows the new version for the
     SCSI controller, the network adapter, the serial driver and FwCfg.
   - `Get-NetAdapterAdvancedProperty` shows the same values as before. A new
     version can add a property, for example `MergeableBuffers`.
   - `Get-NetIPAddress -AddressFamily IPv4` shows only the static address.
   - The disks are healthy, and the System log has no new storage errors.
8. On a domain controller, run `repadmin /replsummary` and
   `dcdiag /q /skip:SystemLog`.

   **NOTE:** For 24 hours `dcdiag` shows `DFSREvent` as failed, because the
   partners logged warnings during the restart. DFS Replication event 2213
   (stop after a dirty shutdown) is a real fault.

9. On a domain controller, look for the DHCP address in DNS:
   `Resolve-DnsName linds.com.au -Type A`. Remove each address that is not
   the static address of a domain controller.

   **CAUTION:** While the network adapter is installed again, the server gets
   a DHCP address for a short time. A domain controller registers it at `@`,
   `DomainDnsZones`, `ForestDnsZones` and `gc._msdcs`. Scavenging is off, so
   the record stays, and clients can get an address that does not answer.

10. Delete the scheduled task, the folder in `C:\Windows\Temp` and the
    snapshots.
11. If you paused the deploy, remove the file and run
    `linds-ansible-deploy --retry`.

## Known problems

- `qm guest exec` stops with "guest-exec-status ... got timeout" when the
  command runs for some time with no output (QEMU guest agent 110.0.2). Use
  WinRM or a scheduled task for long commands.
- `wmic` is not on Windows Server 2025. Use `Get-CimInstance`.
