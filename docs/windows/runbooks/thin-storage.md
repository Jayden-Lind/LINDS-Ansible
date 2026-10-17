# Thin storage: a data disk uses more space on the host than Windows shows

The data disks are thin: a ZFS zvol at JD (`NAS-SSD/vm-1103-disk-0`) and an
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

Compare what the host has with what Windows uses:

```shell
lvs -o lv_name,lv_size,data_percent NAS/vm-102-disk-0      # LINDS
zfs get used,logicalreferenced NAS-SSD/vm-1103-disk-0      # JD
```

On 17 October 2026 the LINDS volume held about 1.4 TiB more than NTFS used.
The shadow copies from before the 12 October rebuild kept the old replication
data. That space comes back when those copies age out, at the end of November
2026.

## Procedure: free the space that missed its TRIM

This procedure frees space that no shadow copy needs.

1. Make sure that nobody copies large amounts of data to the volume for the
   next 30 minutes.
2. On the server, as `SYSTEM` (a scheduled task), run:

   ```powershell
   $dir = 'E:\_trimfill'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
   $keep = 300GB; $chunk = 128GB; $i = 0
   while (((Get-PSDrive E).Free - $keep) -gt 16GB) {
     $size = [Math]::Min($chunk, (Get-PSDrive E).Free - $keep)
     $fs = [IO.File]::Open((Join-Path $dir ("fill{0:D3}.bin" -f $i)), 'CreateNew', 'Write', 'None')
     $fs.SetLength($size); $fs.Close(); $i++
   }
   foreach ($f in (Get-ChildItem $dir -File | Sort-Object Name)) { Remove-Item $f.FullName -Force; Start-Sleep -Seconds 30 }
   Remove-Item $dir -Force
   ```

   `SetLength` reserves the free space without a write. The delete then sends
   TRIM for it.
3. Compare the host and Windows again. If the difference stays large, the
   shadow copies hold it (cause 2).

**CAUTION:** While the script runs, the volume has only 300 GB free.

## Procedure: free the space that shadow copies keep

**WARNING:** This deletes Previous Versions. Do it only if you do not need the
old versions.

1. List the shadow copies: `vssadmin list shadows /for=E:`.
2. Delete the oldest: `vssadmin delete shadows /for=E: /oldest`. Repeat for
   each copy that you do not need.
3. Compare the host and Windows again.
