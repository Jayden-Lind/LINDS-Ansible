# Windows domain (linds.com.au)

Four Server 2025 guests, managed over WinRM with Kerberos. Terraform owns the
VMs (`LINDS-Terraform/proxmox/vms-jd.tf`); Ansible owns what runs inside them.

| Host | Address | Site | Role |
| --- | --- | --- | --- |
| `jd-dc-01` | 10.0.50.200 | JD | DC, GC, DNS, **PDC emulator + RID master** |
| `linds-dc` | 10.3.1.200 | LINDS | DC, GC, DNS, schema + naming master, `linds-CA` |
| `linds-dc2` | 10.3.1.201 | LINDS | DC, GC, DNS |
| `jd-fs-01` | 10.0.50.201 | JD | file server, 12 TB `D:` |

## Running it

```shell
make venv          # once
make kinit         # per session - prompts for the domain admin password
make windows-check # --check --diff
make windows
```

No credentials are stored anywhere in this repo. Authentication comes from the
operator's Kerberos ticket, which expires on its own. The ticket cache is
`/tmp/krb5cc_<uid>`, so restarting the machine it was taken on loses it.

Two constraints the tooling depends on:

**The venv must be built against `/usr/bin/python3`.** `pykerberos` links
against the system MIT krb5 and cannot load under the nix Python's glibc — it
fails with `libgssapi_krb5.so.2: cannot open shared object file`.

**Kerberos delegation is required, not optional.** The GPMC cmdlets make an
onward LDAP bind and fail with `LDAP_OPERATIONS_ERROR (0x80072020)` without a
forwarded ticket. CredSSP is the usual workaround and is deliberately rejected
because it weakens the servers; a forwardable ticket achieves the same with no
server-side change.

## What is managed here

- **`windows_ad_topology`** — sites, subnets, site link. Before this there was
  a single site holding all three DCs, with `10.3.1.0/24` undefined despite two
  DCs living on it. DC locator treated every DC as equally close, so clients
  authenticated across the IPsec tunnel most of the time. That was the cause of
  the intermittent slow logons.
- **`windows_ad_recovery`** — AD Recycle Bin and FSMO placement.
- **`windows_dc_time`** — domain time hierarchy. Reads the current PDC from AD
  rather than taking it as a variable, so moving the role moves the time
  authority with it.
- **`windows_dfsr`** — the NAS replication group: group, replicated folders,
  members, content paths, staging and conflict quotas, and connections.
  `PrimaryMember` is deliberately not declared; it is a one-shot initial-sync
  flag that DFSR clears itself, so asserting it would re-arm an initial sync on
  every run. Staging quotas are per folder (`dfsr_staging_quota_overrides_mb`);
  the conflict quota is one value and is only ever raised, because lowering it
  purges the oldest conflict copies at once.

## Runbook: the DFS-R stale junction trap

Not automated — this is a one-off repair for a storage move, not desired state.
Recorded here because the symptom points somewhere other than the cause.

DFSR does not keep its working directories inside the replicated folder. It
creates `<root>\DfsrPrivate` as a **junction** pointing at
`<volume>\System Volume Information\DFSR\Private\{contentSet}-{member}`. That
junction is an ordinary NTFS reparse point, so it is copied or carried along
like any other directory entry when data is moved between servers — but its
target embeds the *source* server's drive letter and member GUID.

After the storage move, all seven roots on `jd-fs-01` held junctions pointing
at `E:\System Volume Information\DFSR\...`, which is LINDS-DC's drive letter.
`jd-fs-01` has no `E:` volume. DFSR resolves the staging path through the
junction while reading its AD config, gets `ERROR_FILE_NOT_FOUND`, and discards
the content set before it ever looks at the volume — so it registered no
volumes at all and never created its database.

The symptom is thoroughly misleading. Event 6404 says "the local path is not
the fully qualified path name of an existing, accessible local folder", which
points at the root path; the root path was always fine. Only the service's own
debug log names the real failure:

```
VolumeIdTable::FindVolumeFromFilePath context.cpp:1170  Error:2
Config::AdReader::ReadSettings  Failed to add content set to volume config list. csPath:D:\Photos
Config::XmlWriter::MergeAdConfig  No volume guids found locally.
```

What made it conclusive was a throwaway single-member replication group with
empty folders on both `C:` and `D:`. Both initialised immediately, on the very
same volume and service instance that was rejecting `D:\Photos` — which ruled
out the volume, the machine, permissions and the AD configuration in one step,
and left the folders themselves as the only remaining difference.

`E:\Personal Files` on LINDS-DC had the same defect, pointing at a `D:` path,
dated April 2022. That folder had not been replicating for over four years and
nothing had reported it.

**When moving DFSR data between servers, delete `<root>\DfsrPrivate` on the
destination.** Delete it non-recursively — it is a link, and a recursive delete
can follow it into `System Volume Information`. DFSR recreates it correctly.

## Runbook: never make a newly-added member the primary

Fixing the junctions got replication running, and it then destroyed ~380,000
files from the live trees over the following two hours. Everything was
recovered from shadow copies, but the mechanism is worth understanding because
it is entirely counter-intuitive.

`jd-fs-01` was added as a **new** member and designated primary, on the
reasoning that it held the good copy. That is the wrong lever. The primary flag
does not mean "this copy wins" — it means "treat this member's files as brand
new objects and publish them". `linds-dc` already had an established database
with its own UID for every one of those paths, so each republished file
collided with the existing object: **33,513 NameConflicts**, each one moving a
file aside. With `ConflictAndDeleted` capped at 4 GB, the losers were purged
almost immediately.

The flag is also single-shot. DFSR clears it the moment that member finishes
its initial build, after which conflict resolution silently reverts to
last-writer-wins — so the intended authority does not even persist.

**The correct shape:** the member that already has a database is authoritative
simply by having one. A member joining a pre-seeded folder must arrive with
**no DFSR database at all**, and *not* be marked primary. It then hash-matches
the pre-seeded content and adopts it, rather than colliding with it.

To rebuild a member that way:

1. `Remove-DfsrMember` for that member
2. Delete `<datavolume>\System Volume Information\DFSR` on it — **only** the
   data volume; SYSVOL's database lives on `C:` and must survive
3. Move any files unique to that member out of the replicated tree first. A
   non-primary member's unmatched content goes to `PreExisting` and is **never
   replicated outward**, so anything only it holds would be stranded. A
   same-volume move is a rename, so this costs nothing.
4. `Add-DfsrMember`, set content paths, recreate connections, leave
   `PrimaryMember` false
5. Move the held files back once initial sync settles; they then replicate out
   as ordinary new files

Confirmation that it worked: after the rebuild, initial sync ran with **zero**
4412 conflict events on either member, against 178 in the first two hours of
the previous attempt.

Two smaller traps met along the way. `Add-DfsrConnection` creates **both**
directions, so adding the reverse fails as "already exists". And `rmdir` cannot
delete files whose names carry trailing spaces — the Win32 path parser strips
them — so the last remnants of a DFSR database need `[IO.File]::Delete` with a
`\\?\` prefix.

## Runbook: stale AAAA records break DFS-R across the tunnel

After the rebuild, replication ran but the connection flapped every few minutes
all evening:

```
5014  stopping communication with partner JD-FS-01 ... Error: 1726 (The remote procedure call failed.)
5008  failed to communicate with partner JD-FS-01 ... Error: 1722 (The RPC server is unavailable.)
5004  successfully established an inbound connection with partner JD-FS-01
```

`jd-fs-01` held stale **public IPv6 AAAA records** in `linds.com.au`. Windows
prefers IPv6 over IPv4, so `linds-dc` resolved those, tried to reach them across
the IPsec tunnel where they do not route, stalled, and dropped the RPC session —
then re-established on IPv4 and repeated. Throughput ran at roughly half rate
and looked idle whenever sampled during a down phase.

Disabling IPv6 on `jd-fs-01` removed the AAAA registration; the host now
resolves to its `A` record alone, the flapping stopped, and sustained
throughput doubled to ~11 MB/s.

Two things make this worth remembering:

- **Diagnosing it from the backlog is impossible.** `Get-DfsrBacklog` compares
  version vectors, and a member still in initial sync has not established one —
  so it reports "No backlog" regardless. That reads as "in sync" and means
  nothing of the kind. Count files and read the `Total Bytes Received`
  performance counter instead.
- The zone still accepts **nonsecure dynamic updates** with **scavenging
  disabled**, so records like these never age out and any host can register
  them. That combination is what let a cosmetic-looking DNS wart take out
  cross-site replication.

## Runbook: recovering from shadow copies

Recovery worked because both volumes had Volume Shadow Copies predating the
damage. Points worth keeping:

- Shadow storage defaults to **10% of the volume**, and a large resync generates
  enough copy-on-write to evict exactly the snapshots you need. Raise the cap
  (`vssadmin resize shadowstorage`) *before* starting anything that churns.
- `[IO.File]::Copy` carries the source's **ReadOnly** attribute to the
  destination, so a subsequent timestamp write fails with access denied. The
  file is copied correctly; only its mtime is wrong. Set attributes last.
- Reading many **large** files out of an old snapshot is pathologically slow:
  every block of a since-deleted file sits in the fragmented copy-on-write diff
  area. Small files restore fine (58,508 files / 373 GB in ~50 minutes); large
  ones effectively do not. Prefer any live source over a snapshot for bulk data.

## Runbook: adding a replicated folder

Replication is by folder, from a list (`dfsr_folders`). Anything on a data
volume that is not in the list stays on that one server. At JD that is `immich`
alone, on purpose. At LINDS it is `server` (old Veeam backups of hosts that no
longer exist), `.bzvol`, `._nfs` and the loose files in the root of `E:\`.

For a folder whose content exists at **one site only**:

1. Add the name to `dfsr_folders` and run `make windows`. That creates the
   folder object and a membership on each member, and then nothing moves,
   because neither member is primary: each waits (event 4102) for a partner
   that already has the content.
2. Make the member that holds the data primary, for this folder only. The other
   member's folder must be empty.

   ```powershell
   Set-DfsrMembership -GroupName NAS -FolderName '<name>' -ComputerName <member with the data> -PrimaryMember $true -Force
   ```

3. `dfsrdiag pollad` on both members. Expect 4112 on the primary, then 4102 and
   finally 4104 on the other.

This is the one place the primary flag is right: a folder that neither member
has a database for. It does not contradict the runbook above, which is about a
folder that already replicates.

`Music` and `papa usb` went in this way on 10 October 2026, from LINDS. The
LINDS uplink carried them at about 3 MB/s.

**Why not replicate the whole volume and exclude `immich`?** DFS-R can do it: a
replicated folder may be a volume root, and it takes a list of folder names to
skip (`Set-DfsReplicatedFolder -DirectoryNameToExclude`, matched by name at any
depth). But replicated folders cannot nest, so the existing ones would have to
be removed and replaced by one new folder at `D:\` and `E:\`. That is a fresh
initial sync over every file on both volumes, with one member primary: the
kind of operation that cost 380,000 files in August. The only thing it buys is
that a new top-level folder replicates without being added to the list.

## Runbook: a backlog that is only old deletion records

On 10 October 2026 `dfsrdiag backlog` showed 717 files in `holiday videos`
waiting to go from JD to LINDS. Nothing was waiting. Every file it named was
already on both servers, the same size and date.

DFS-R keeps a record of each deleted file (a tombstone) for 60 days and then
clears them out. The August rebuild deleted and restored hundreds of thousands
of files around 10 August. Sixty days later, at midnight on 10 October, the
clean-up ran (115,000 `GcTask::GcIdRecord` lines in the first minute on
`linds-dc`) and the two members re-exchanged what was left. The backlog counter
counts records, not files, so it reads as files queued.

How to tell this from a real backlog:

- The debug log (`C:\Windows\debug\Dfsr*.log`, older ones gzipped) shows
  `GcTask::GcIdRecord` in bulk at the hour it started, and the receiver logs
  `Meet::InstallTombstone` for the "backlogged" names.
- The records carry a version from a database that neither member has now.
  Compare the GUID in `gvsn:{...}` with
  `Get-CimInstance -Namespace root\MicrosoftDfs DfsrVolumeInfo`.
- No 4412 conflict events, nothing new in `ConflictAndDeleted`, and no bytes
  moving.

It cleared by itself at 09:22, the next time the two members re-established
their connection.

**To prove the two sites hold the same files**, list both trees and compare
path and size. This takes about 30 seconds per member for every replicated
folder:

```powershell
robocopy 'D:\Photos' NULL /L /S /NJH /NJS /NC /NDL /BYTES /FP /XJ /XD DfsrPrivate /R:0 /W:0 /UNILOG:C:\ADBackup\list-photos.txt
```

On 10 October: 635,000 files, and the only differences were files the folder
filter leaves out by design (`~*`, `*.bak`, `*.tmp`, `Thumbs.db`), about 1,030
of them.

## Runbook: giving space back to the hypervisor when retrim fails

The data disks are thin: a ZFS zvol at JD, an LVM thin volume at LINDS. Windows
tells the disk about freed space in two ways, and only one of them works here.

- **Deleting a file** sends a TRIM for that file's blocks. This works.
- **Retrim** (`Optimize-Volume -ReTrim`, and the weekly `ScheduledDefrag` task)
  re-sends TRIM for all free space. This fails at once with event 264,
  `Incorrect function (0x80070001)`, on `jd-fs-01`, `jd-dc-01` and `linds-dc`,
  system and data volumes alike, with virtio drivers from 0.1.240 to 0.1.285.
  Not yet explained.

So any space whose TRIM was missed when the file was deleted is never handed
back. By October 2026 the JD zvol held 11.3 TiB for 5.2 TiB of files.

The way round it is to make Windows delete something that covers the free
space. Allocating a file with `SetLength` reserves clusters without writing to
them, so it costs no space on the pool and takes milliseconds; deleting it then
sends the TRIM.

```powershell
$dir = 'D:\_trimfill'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
$keep = 300GB; $chunk = 256GB; $i = 0
while (((Get-PSDrive D).Free - $keep) -gt 16GB) {
  $size = [Math]::Min($chunk, (Get-PSDrive D).Free - $keep)
  $fs = [IO.File]::Open((Join-Path $dir ("fill{0:D3}.bin" -f $i)), 'CreateNew', 'Write', 'None')
  $fs.SetLength($size); $fs.Close(); $i++
}
foreach ($f in (Get-ChildItem $dir -File | Sort-Object Name)) { Remove-Item $f.FullName -Force; Start-Sleep -Seconds 45 }
Remove-Item $dir -Force
```

Run it from a SYSTEM scheduled task, not a WinRM session; it takes about 20
minutes. For those minutes the volume has only `$keep` free, so nobody should be
copying large amounts onto it.

At JD on 10 October 2026 this took `NAS-SSD/vm-1103-disk-0` from 11.3 TiB to
6.58 TiB and the pool from 77% to 45% full. It has to be repeated whenever the
gap grows again, until retrim itself is fixed.

The shadow copies came through it. Files deleted from `D:` since a snapshot
was taken still read back from that snapshot afterwards: two 365 MB database
dumps, from the 27 August and 6 October copies, decompressed with their
checksums intact. Check the same way after any future run.

At LINDS the same afternoon (`E:` on `linds-dc`, paths changed to match) one
pass was not enough. The first, with 256 GB files 45 seconds apart, took the
thin pool `NAS` from 88% to 66% full and left about 1.7 TiB of free space still
mapped. A second pass, with 128 GB files 30 seconds apart, brought it to 52%:
3.9 TiB handed back in all, 5.2 TiB available. So part of the first pass's
TRIMs were simply lost on the way to the pool.

Two things it was not: shadow copies holding the blocks (nothing had been
deleted from `E:` since the oldest copy), and fragmentation (99.8% of the free
space sits in whole 64K blocks, the pool's chunk size).

**After a run, compare what the pool has mapped with what NTFS uses**, and run
it again if they are far apart:

```shell
lvs -o lv_name,lv_size,data_percent NAS/vm-102-disk-0   # LINDS
zfs get used,logicalreferenced NAS-SSD/vm-1103-disk-0   # JD
```

## Entra Connect on `linds-dc2`

`linds-dc2` runs Entra Connect Sync 2.6.3.0 against the tenant
`lindtestazuread.onmicrosoft.com`, with pass-through authentication as the
sign-in method. As found, and partly fixed, on 10 October 2026:

- **The sync service did not survive a cold start.** On 15 August `ADSync`
  failed in the first minute of the boot ("the user name or password is
  incorrect" for its managed service account), and Windows does not retry a
  failed start, so it stayed stopped until 10 October. The cause was the
  clock: see "a domain controller that boots with the wrong clock" below.
  **Fixed twice over:** the service is on delayed automatic start, and came up
  by itself on 10 October even with the clock still wrong; and the VM now
  gets a local-time clock. An Entra Connect upgrade may put the start type
  back.
- **Its import from Entra failed on every cycle** once it was running again:
  run result `stopped-server-down`, event 109 "Error Code: 78 ... An internal
  error has occurred". Most likely its place in Entra's change feed had
  expired during the 58 days it was stopped. **Fixed** with one full cycle,
  which is safe in staging mode because nothing is exported; the delta cycle
  after it succeeded on both connectors:

  ```powershell
  Start-ADSyncSyncCycle -PolicyType Initial
  ```

- **It is in staging mode, and has been since 2 November 2024.** It imports and
  calculates but sends nothing to Entra. If it were made active today it would
  add ten groups (the `k8s-*` groups) and change nothing else. **Not fixed:**
  leaving staging mode is done in the Entra Connect wizard ("Configure staging
  mode") and needs a tenant administrator sign-in. The wizard does tenant-side
  work at that point (password hash sync is configured here but still off in
  the tenant), which is why the setting was not simply flipped with PowerShell.
- **The pass-through agent looks dead.** Its registration certificate was
  issued on 2 November 2024, expired on 1 May 2025 and was never renewed; the
  store holds nothing newer. The service still runs and logs a connection
  failure most days. **Not fixed:** it has to be reinstalled (the installer is
  in the Entra portal under Entra Connect, Pass-through authentication), again
  with a tenant administrator sign-in.
- **The Connect Health agent's newest certificate expired on 6 December 2025.**

**Working on it over WinRM.** The cmdlets that read run history, global
settings or tenant features talk to `net.pipe://localhost/ADSyncManagement`,
which refuses network logons, so over WinRM they fail with "no endpoint
listening". Run them from a console session, or from a scheduled task
registered for an `ADSyncAdmins` member with logon type S4U (no password
needed). `Get-ADSyncScheduler`, `Start-ADSyncSyncCycle` and `csexport.exe` do
work over WinRM. To see what an export would do while in staging mode:

```powershell
& 'C:\Program Files\Microsoft Azure AD Sync\Bin\csexport.exe' '<connector name>' C:\ADBackup\pending.xml /f:x
```

If Entra Connect is not wanted any more, removing it also removes the reason
for `MSOL_abd8982191a0`, an account that can read every password hash in the
domain.

## Runbook: a domain controller that boots with the wrong clock

`LINDS-DC2` (VM 110 on `linds-proxmox-01`) had no OS type set in Proxmox.
Proxmox then gives the guest a hardware clock in UTC, and Windows reads the
hardware clock as local time, so after every **cold start** the server came up
10 or 11 hours slow and stayed that way until the time service stepped it: 45
seconds on 15 August 2026, 17 minutes on 10 October. A guest reboot does not
do it; the clock survives those.

While the clock is wrong:

- Kerberos to the server fails. Over WinRM that reads "the specified
  credentials were rejected by the server".
- Directory replication with it fails with 1398, "there is a time and/or date
  difference between the client and server".
- A service that logs on with a domain account early in the boot can be
  refused. That is what stopped `ADSync` on 15 August.

To see it without logging on, ask the server for the time:

```shell
ntpdate -q 10.3.1.201      # or any SNTP query; -39600 s is the giveaway
qm config 110 | grep -E 'ostype|localtime'
```

Fixed on 10 October with `qm set 110 --localtime 1`, which takes effect at the
VM's next cold start. `LINDS-DC-01` (VM 102) has `ostype: win11`, which implies
the same thing. After a skewed boot, `repadmin /syncall <dc> /Ade` clears the
replication errors once the clock is right.

## What is deliberately not managed here

**GPOs are not enforced declaratively.** Re-importing a GPO is not an
idempotent operation and must not run unattended against a live domain.
Authoring stays in GPMC; the intended treatment is scheduled `Backup-GPO` into
git plus a drift report.

**AD users, groups and OUs** are out of scope.

**FSMO roles cannot be made highly available.** They are single-master by
design; forcing a role onto a second DC while the original lives causes
split-brain. The mitigation is to spread them so no single failure takes all
five, and to seize on loss. Only the PDC emulator matters day to day.

## Runbook: certificate autoenrollment and machine-wide DCOM

Also a one-off repair, recorded for the same reason: the error names the wrong
layer.

Autoenrollment reaches the CA as the **computer account** over DCOM. A caller
must pass the machine-wide DCOM launch limit before the CA's own permissions
are ever consulted. On `linds-dc` that limit read:

```
BUILTIN\Administrators          0x1F   ...ActivateLocal, ActivateRemote
Everyone                        0x0B   Execute, ExecuteLocal, ActivateLocal
BUILTIN\Distributed COM Users   0x1F   (group empty)
```

`Certificate Service DCOM Access` — the group AD CS exists to use, and which
contains `Authenticated Users` — was absent. Machine accounts therefore matched
only `Everyone`, which has no **ActivateRemote**, so every enrolment was refused
while an interactive administrator sailed through. That asymmetry is the
diagnostic signature: same host, same port 135, valid Kerberos tickets, refused
in ~150 ms rather than timing out.

The error is thoroughly unhelpful — `0x800706ba RPC_S_SERVER_UNAVAILABLE`
suggests the CA is unreachable, and it was reachable the whole time.

Fix, applied to `HKLM\SOFTWARE\Microsoft\Ole\MachineLaunchRestriction` (a
`REG_BINARY` security descriptor, not the `Policies` key — no GPO was setting
it):

```
add ACE:  (A;;CCDCLCSWRP;;;CD)     # CD = S-1-5-32-574, full COM rights
```

It takes effect immediately; no reboot is needed. The prior descriptor is saved
on the CA at `C:\ADBackup\dcom-machinelaunch-before.txt`.

Afterwards `jd-dc-01` and `linds-dc2` both enrolled Kerberos Authentication,
Domain Controller Authentication and Directory Email Replication certificates
valid to 2027. `jd-fs-01` enrols nothing and logs no errors, which is correct —
those are DC-only templates and no Computer template is published for
autoenrollment.

Not automated: this is a repair to one host's DCOM descriptor, not fleet state.

## Known outstanding

As of 10 October 2026.

- **Retrim fails on the guests**, so thin space is only handed back by the
  runbook above. Both sites were done on 10 October.
- **Entra Connect is in staging mode and its pass-through agent looks dead**;
  see the section above. Both need a tenant administrator in the wizard.
- **`jd-dc-01` has 8.2 GB free on a 39.4 GB `C:`**.
- **DNS**: `linds.com.au` accepts nonsecure dynamic updates and scavenging is
  disabled on the servers. The stale public IPv6 `AAAA` records for `jd-fs-01`
  are gone.
- **System-state backups are not configured.** Event 2089 reports no partition
  backed up in 90+ days.
- **`E:\server\old_backup` on `linds-dc`** is 248 GB of Veeam backups from
  2019 to 2021, of hosts that no longer exist.
- **`linds-dc2` holds ten expired Entra agent certificates** (pass-through and
  Connect Health). They generate "about to expire" warnings (event 64) that are
  noise, not enrolment failures.
- **Dead scheduled tasks**: `jd-dc-01` and `linds-dc` each have two
  `ShadowCopyVolume{...}` tasks for volumes that no longer exist, failing twice
  a day. The same one on `linds-dc2`, and its three vCenter tasks, were
  disabled on 10 October.
- **VMware Tools is still installed on `linds-dc` and `linds-dc2`.** On
  `linds-dc2` it writes about 2,500 errors a week to the Application log.
