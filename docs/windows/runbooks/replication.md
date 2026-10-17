# DFS Replication (the NAS)

The replication group `NAS` replicates the folders in
`inventory/group_vars/windows/replication.yml` in both directions between
`jd-fs-01` (`D:`) and `linds-dc` (`E:`). A folder that is not in the list
stays on its server.

**WARNING:** Replication copies damage and deletions too. It is not a backup.

## Add a replicated folder

Use this procedure for a folder that is on one member only.

1. Make sure that the folder does not exist on the other member.
2. Add the name to `dfsr_folders`. Add the member that has the data to
   `dfsr_initial_primary`.
3. Set a staging quota in `dfsr_staging_quota_overrides_mb` that is at least
   the total size of the 32 largest files in the folder.
4. Run `make windows TAGS=dfsr`.
5. Wait for the change to reach the other site (up to 15 minutes), or run
   `dfsrdiag pollad` on both members.
6. Look for event 4112 on the primary member, then 4102 and 4104 on the other.

**NOTE:** The role sets the primary member only when it gives the folder its
first content path. This is the only correct use of the primary flag.

`immich` and `server` were added this way on 17 October 2026.

## Join a member again (after a rebuild)

1. The retirement removes the member from the group.
2. `windows_fileserver` removes the old replication data from the volume.
3. `make windows` adds the member again. It is not primary.
4. The member stages and hashes every file, and compares it with the partner.
   It copies only files that are different.

**CAUTION:** This takes a long time and uses space. For 4.7 TiB at LINDS it
took 33 hours. The staging copies grew the LINDS thin pool from 52.6% to
60.9%.

To see the progress:

- A folder shows "uninitialised" until its turn, with no event. The debug log
  (`C:\Windows\debug\Dfsr*.log`, lines `DirWalkerTask`) shows the walk.
- Run `dfsrdiag backlog /rgname:NAS /rfname:<folder> /smem:<partner> /rmem:<member>`
  two times, some minutes apart, to get files per minute.

**NOTE:** Do not estimate the end from bytes read. Folders finish one after
another. One large file can hold its folder for hours.

**NOTE:** Event 4412 during this sync means that a file was different. Read
it. On 14 October 2026 it found a 39 GiB file whose LINDS copy had 3.4 GiB of
zeros. Replication replaced it with the good copy from JD.

## Never make a member that replicates the primary member

**Symptom:** After you set a member as primary, many files go to
`ConflictAndDeleted` and event 4412 shows many conflicts.

**Cause:** The primary member publishes its files as new objects. The other
member already has objects for the same paths, so each file is a conflict. In
August 2026 this moved about 380,000 files aside.

**Procedure to rebuild a member correctly:**

1. Run `Remove-DfsrMember` for the member.
2. Delete `<data volume>\System Volume Information\DFSR` on it. Do not delete
   the database on `C:` (SYSVOL).
3. Move files that only this member has out of the replicated folders.
4. Add the member again, with its content paths, and with `PrimaryMember`
   false.
5. After the initial sync, move the files back.

**NOTE:** `Add-DfsrConnection` makes both directions. A second command for the
other direction fails with "already exists".

**NOTE:** `rmdir` cannot delete a file with a space at the end of its name. Use
`[IO.File]::Delete('\\?\<full path>')`.

## Stale DfsrPrivate links after a data move

**Symptom:** Event 6404 says the local path is not valid, but the path is
correct. The service registers no volume.

**Cause:** `<root>\DfsrPrivate` is a junction to `System Volume
Information\DFSR\Private\...` on the volume of the server where it was made.
A copy of the data takes the junction with it.

**Procedure:** On the new server, delete `<root>\DfsrPrivate`. Do not delete
it recursively: it is a link. The service makes it again.

## IPv6 records that do not route

**Symptom:** The connection stops every few minutes (events 5014, 5008, 5004).

**Cause:** A member had public IPv6 AAAA records that do not route through the
tunnel. Windows prefers IPv6.

**Procedure:** Remove the AAAA records, and stop the server from registering
them.

## A backlog that is only old deletion records

**Symptom:** `dfsrdiag backlog` shows files, but the files are on both
members, with the same size and date.

**Cause:** DFS-R keeps a record of each deleted file for 60 days. When it
removes old records, the backlog counts them.

**Check:** The debug log shows `GcTask::GcIdRecord` lines, and the receiver
shows `Meet::InstallTombstone`. It clears by itself.

## Prove that the two sites have the same files

On each member, list each folder, then compare the lists:

```powershell
robocopy 'D:\Photos' NULL /L /S /NJH /NJS /NC /NDL /BYTES /FP /XJ /XD DfsrPrivate /R:0 /W:0 /UNILOG:C:\ADBackup\list-photos.txt
```

Read the log as Unicode. The file filter of the group excludes `~*`, `*.bak`,
`*.tmp` and `Thumbs.db`, so these differ.
