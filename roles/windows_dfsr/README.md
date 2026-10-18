# windows_dfsr

The role makes the DFS Replication group of the file servers agree with the
inventory: the group, its folders, members, content paths, quotas and
connections.

## What it does

1. If `dfsr_group` is empty, it stops and changes nothing.
2. It makes the replication group.
3. It makes each replicated folder in `dfsr_folders`.
4. It adds each member in `dfsr_members`.
5. For each member and folder, it sets the content path (`<root>\<folder>`),
   the staging quota and the Conflict and Deleted quota, and enables the
   membership.
6. For a new folder in `dfsr_initial_primary`, it makes that member primary
   when it gives the folder its first content path. It stops if another member
   already has files in the folder. A folder is new while no member has a
   content path for it. A member that joins again after a rebuild is never
   primary.
7. It makes each connection in `dfsr_connections` and enables it, with Remote
   Differential Compression as set.

## Requirements

- A Kerberos ticket with delegation (`kinit -f Administrator@LINDS.COM.AU`).
- The file servers have the role `windows_fileserver` with
  `windows_fileserver_replication: true`.

## Variables

Set them in `inventory/group_vars/windows/replication.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `dfsr_group` | `""` | The name of the replication group. |
| `dfsr_folders` | `[]` | The folders. Each is a folder in the root of the data volume. |
| `dfsr_initial_primary` | `{}` | Folder to member: the member that has the data of a new folder. |
| `dfsr_members` | `{}` | Member to the root of its data volume, for example `JD-FS-01: "D:"`. |
| `dfsr_connections` | `[]` | `{source, destination}`. Give both directions for two-way replication. |
| `dfsr_staging_quota_mb` | `4096` | The staging quota of a folder. |
| `dfsr_staging_quota_overrides_mb` | `{}` | Folder to staging quota, for large folders. |
| `dfsr_conflict_quota_mb` | `4096` | The Conflict and Deleted quota. |
| `dfsr_rdc_enabled` | `true` | Remote Differential Compression on the connections. |

## How to use it

`ansible-playbook playbooks/windows.yml --tags dfsr`. To add a folder, see "Add
a replicated folder" in `docs/windows/runbooks/replication.md`.

## Safety

**WARNING:** Do not set `PrimaryMember` on a folder that already replicates.
The primary member publishes its files as new files. In August 2026 this
caused 33,513 name conflicts and about 380,000 files moved aside.

**WARNING:** A non-primary member moves files that only it has to
`DfsrPrivate\PreExisting`. They do not replicate. Make sure that the folder
is empty on all members except the primary.

**CAUTION:** Make the staging quota at least the total size of the 32 largest
files of the folder. A smaller quota makes replication slow.

**NOTE:** The role only increases the Conflict and Deleted quota. A decrease
deletes the oldest entries immediately.

## Known problems

- Staging is on the data volume. On thin storage it uses real space, up to the
  staging quota of each folder, and it stays.
- A member that joins again with its data stages and hashes every file. For
  4.7 TiB at LINDS this took 33 hours.
