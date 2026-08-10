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
operator's Kerberos ticket, which expires on its own.

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
  every run.

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

- **`jd-fs-01` runs Server 2025 Evaluation** — expires and then force-reboots
  hourly.
- **`jd-dc-01` has ~6.8 GB free on a 39.4 GB `C:`**.
- **DNS**: `linds.com.au` accepts nonsecure dynamic updates and scavenging is
  disabled; two stale public IPv6 `AAAA` records for `jd-fs-01` persist as a
  result.
- **System-state backups are not configured.** Event 2089 reports no partition
  backed up in 90+ days.
- **`linds-dc2` holds a dozen expired ADFS agent certificates** from a
  decommissioned deployment. They generate a steady stream of "about to expire"
  warnings (event 64) that are noise, not enrolment failures.
