# Thin storage: a data disk uses more space on the host than Windows shows

The data disks are thin: a ZFS zvol at JD (`NAS-SSD/vm-1113-disk-0`) and an
LVM thin volume at LINDS (`NAS/vm-102-disk-0`). The host frees space only when
Windows sends TRIM.

## Causes

1. **Retrim fails.** `Optimize-Volume -ReTrim` (and the weekly defrag task)
   fails with event 264, `0x80070001`, on all servers. Thus space that missed
   its TRIM is not freed.
2. **Shadow copies keep deleted data.** Windows does not send TRIM for space
   that a shadow copy still needs. Deleted data stays on the host until the
   oldest shadow copy that has it is deleted. The volumes keep 64 shadow copies,
   two each weekday, so about six weeks.

## Find the difference

Compare what the host has with what Windows uses (`Get-Volume`, size minus
free):

```shell
lvs -o lv_name,lv_size,data_percent NAS/vm-102-disk-0      # LINDS
zfs get logicalreferenced NAS-SSD/vm-1113-disk-0           # JD
```

**NOTE:** At JD, compare `logicalreferenced`, not `used`. The pool is a
5-wide raidz1 and the zvol has 16 KiB blocks, so `used` includes parity and
padding: about 1.2 times the data. That difference cannot be freed.

On 17 October 2026 the LINDS volume held about 1.4 TiB more than NTFS used.
The shadow copies kept the replication data that the 12 October rebuild
deleted. The owner had all shadow copies on both NAS volumes deleted that day,
then the procedure below ran two times:

| Step | LINDS thin pool `NAS` |
| --- | --- |
| Before | 62.2% |
| Shadow copies deleted | 61.6% |
| First pass (128 GiB files, 30 s apart) | 55.5% |
| Second pass (64 GiB files, 20 s apart) | 55.2% |

About 780 GiB came back. About 600 GiB stays mapped although NTFS shows it as
free. TRIM can free only whole 64 KiB chunks of the pool, so a chunk that is
only partly free stays.

## Find which cause holds the space (JD)

The host counts the TRIM that gets to the zvol. While the procedure below
deletes its files, read the counter on `jd-proxmox-02`:

```shell
dev=$(basename "$(readlink -f /dev/zvol/NAS-SSD/vm-1113-disk-0)")
awk '{printf "%.1f GiB\n", $14 * 512 / 2^30}' /sys/block/$dev/stat
```

Each delete of a 128 GiB file adds 128 GiB to the counter. If a delete adds
less, a shadow copy holds that space (cause 2). If a delete adds 128 GiB but
`logicalreferenced` does not decrease, the host had freed that space already.

## Procedure: free the space that missed its TRIM

This procedure frees space that no shadow copy needs. The drive is `D` on
`jd-fs-01` and `E` on `linds-dc`.

1. Make sure that nobody copies large amounts of data to the volume for the
   next 30 minutes.
2. **NOTE:** A shadow copy that starts while the files exist keeps all of
   their space. Then the procedure frees nothing.

   Make sure that no shadow copy is due in the next hour:
   `(Get-ScheduledTask shadow-copy-E | Get-ScheduledTaskInfo).NextRunTime`.

3. **CAUTION:** While the script runs, the volume has only 300 GB free. For
   less than one second, it has only 40 GB free.

   On the server, as `SYSTEM` (a scheduled task), run:

   ```powershell
   $drive = 'E'; $dir = "${drive}:\_trimfill"
   New-Item -ItemType Directory -Path $dir -Force | Out-Null
   function Free { ([IO.DriveInfo]::new($drive)).AvailableFreeSpace }
   function FillTo([string]$prefix, [long]$leave) {
     $i = 0
     while (((Free) - $leave) -gt 4GB) {
       $size = [Math]::Min(128GB, (Free) - $leave)
       $fs = [IO.File]::Open((Join-Path $dir ('{0}{1:D3}.bin' -f $prefix, $i)), 'CreateNew', 'Write', 'None')
       $fs.SetLength($size); $fs.Close(); $i++
     }
   }
   FillTo 'fill' 300GB
   FillTo 'tail' 40GB
   Get-ChildItem $dir -Filter 'tail*' | Remove-Item -Force
   foreach ($f in (Get-ChildItem $dir -File | Sort-Object Name)) { Remove-Item $f.FullName -Force; Start-Sleep -Seconds 30 }
   Remove-Item $dir -Force
   ```

   `SetLength` reserves the free space without a write. The delete then sends
   TRIM for it. The `tail` files cover the last part of the free space, where
   the old data often is.
4. Compare the host and Windows again. If the difference stays large, the
   shadow copies hold it (cause 2).

## Procedure: free the space that shadow copies keep

**WARNING:** This deletes Previous Versions. Do it only if you do not need the
old versions.

1. List the shadow copies: `vssadmin list shadows /for=E:`.
2. **NOTE:** `vssadmin delete shadows /shadow={<id>}` fails with "Snapshots
   were found, but they were outside of your allowed context". Use `/oldest`.

   Delete the oldest: `vssadmin delete shadows /for=E: /oldest /quiet`. Repeat
   for each copy that you do not need. To delete all of them, use
   `vssadmin delete shadows /for=E: /all /quiet`. For 64 copies this takes
   more than five minutes, longer than one WinRM call can wait; the command
   continues on the server.
3. Do the procedure above. Deleting a shadow copy does not send TRIM for the
   space that it kept.
4. Start the shadow copy scheduled task of the volume once, so that there is a
   current copy before the next scheduled one.
5. Compare the host and Windows again.
