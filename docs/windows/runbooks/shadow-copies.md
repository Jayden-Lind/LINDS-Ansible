# Restore files from shadow copies

The file servers take shadow copies of their data volume two times each
weekday (`windows_fileserver_shadow_copies`). Users see them as Previous
Versions.

## Procedure

1. Find the shadow copy: `vssadmin list shadows /for=D:`.
2. Copy the files from the shadow copy path
   (`\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\...`) or from Previous
   Versions in Explorer.
3. After the copy, set the attributes and the dates of the files.

## Notes

**CAUTION:** Shadow storage is limited. A large change on the volume (for
example a replication sync) can delete the old copies that you need. Before a
large change, increase the limit with `vssadmin resize shadowstorage`.

**NOTE:** `[IO.File]::Copy` copies the read-only attribute. Then a change to
the date fails with "access denied". Set the attributes last.

**NOTE:** Many large files from an old shadow copy restore very slowly. Use a
live copy (the other site) for large data, if there is one.
