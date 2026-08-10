# Windows domain remediation and codification

**Date:** 2026-08-09
**Status:** design, awaiting review

## Problem

The `linds.com.au` domain has been managed entirely by hand. It works, but it
carries roughly 5,200 error and warning events per week across four servers,
logons are intermittently slow, and nothing about its configuration is written
down. The goal is to fix what is broken, then express the corrected state as
Ansible so it stops drifting.

## Discovered state (2026-08-09)

Four Windows Server 2025 guests, all reachable over WinRM 5985 with Kerberos:

| Host | Address | Role |
| --- | --- | --- |
| `jd-dc-01` | 10.0.50.200 | DC, GC, DNS |
| `linds-dc` | 10.3.1.200 | DC, GC, DNS, **all five FSMO roles**, `linds-CA` |
| `linds-dc2` | 10.3.1.201 | DC, GC, DNS |
| `jd-fs-01` | 10.0.50.201 | file server, 12 TB `D:`, domain member |

Forest and domain both at `Windows2016` level, tombstone lifetime 180 days.
SYSVOL is on DFSR (NTFRS disabled) and genuinely in sync: 16 policy folders and
14,851 files identical on all three DCs. Clocks are correct and the w32time
hierarchy is right — PDC on external NTP, the others `NT5DS`.

### Faults, in the order they will be fixed

1. **One AD site.** A single site `LINDS` holds all three DCs. Defined subnets
   are `192.168.6.0/24`, `10.0.51.0/24` and `10.0.50.0/24`, all mapped to it.
   `10.3.1.0/24` — where two DCs live — and `10.0.53.0/24` are not defined at
   all. DC locator therefore treats every DC as equally close and clients
   authenticate across the IPsec tunnel (15 ms, ~52 Mbit) most of the time.
   This is the cause of the intermittent slow logons.

2. **Broken drive mapping.** `Drive Mapping - Everyone` maps `O:` to
   `\\linds-dc\d`, a share that does not exist. 94 failures in 7 days
   (`0x800300FD`). The same GPO already references `\\jd-fs-01\nas`, so the
   migration was started but not finished.

3. **Certificate enrollment broken domain-wide.** AD's Enrollment Services
   object points at `JD-DC-01\linds-CA`, but `CertSvc` is stopped and disabled
   there; the CA actually runs on `linds-dc`. Every DC fails autoenrollment
   with `0x800706ba`, ~1,000 events per week. All DC certificates — Kerberos
   Authentication, Domain Controller Authentication, Directory Email
   Replication — expired 30–31 July 2024, so LDAPS has been down for two years.

4. **VMware Tools on both LINDS DCs.** Left over from the ESXi-to-Proxmox
   migration, running alongside QEMU-GA. `vmStatsProvider` emits 2,384 errors
   per week on `linds-dc2` alone — 80% of that host's log volume.

5. **No recoverability.** Event 2089 reports no partition backed up in 90+
   days. The AD Recycle Bin is disabled, so an accidental deletion is currently
   unrecoverable. All five FSMO roles sit on `linds-dc`, which was powered off
   for several weeks recently.

6. **DFS-R lost a member.** The `NAS` replication group replicated between
   `linds-dc` and `jd-dc-01` until the 14 TB volume was moved to `jd-fs-01`
   earlier today. `jd-dc-01`'s `msDFSR-Member` object survives, as do two stale
   members for `linds-dc` (`WIN-SU2FFTN9QTS`, its pre-rename hostname, and a
   GUID-named duplicate). Seven folders — `business doc`, `Cheryls Files`,
   `holiday videos`, `Jayden`, `Personal Files`, `Photos`, `Zoe` — each with a
   100 GB staging quota, currently replicate nowhere.

### Recorded but not scheduled

DNS accepts nonsecure dynamic updates on `linds.com.au` and scavenging is
disabled, which is why two stale public IPv6 `AAAA` records for `jd-fs-01`
persist. `jd-dc-01` has 6.8 GB free of 39.4 GB. `linds-dc2` has 8 GB RAM and
logs resource-exhaustion events. `jd-fs-01` runs Server 2025 **Evaluation**
with 179.6 days remaining. Share permissions are flat (`Everyone: Change` on
`NAS`, `Authenticated Users: Modify` on `D:\`). Four SYSVOL policy folders are
orphaned and `Drive Mapping - Jayden` is unlinked. Terraform models neither
`jd-fs-01`'s 12 TB disk nor its removal from `jd-dc-01`.

On performance: the USN journal is already 1.0 GB with a 64 MB allocation
delta, `disablelastaccess` is disabled and TRIM is enabled — all optimal. The
volume uses 4 KB clusters on 12 TB and the MFT is 1.19 GB against a 200 MB
zone, but correcting that needs a reformat and is not worth it. SMB signing is
confirmed off on `jd-fs-01`. There is no meaningful NTFS-layer win left.

## Scope

Four workstreams, in this order:

**A. Sites and subnets, and the drive map.** Create sites `JD` and `LINDS`,
move each DC into the right one, define every subnet, replace the single-site
`LINDS-SITELINK` with a real two-site link. Then repoint `Drive Mapping -
Everyone` at `\\jd-fs-01\nas` and drop the `\\linds-dc\d` item.

**B. Certificates and log noise.** Correct the Enrollment Services registration
so it names the host actually running the CA, reissue DC certificates, confirm
LDAPS. Uninstall VMware Tools and VGAuthService from both LINDS DCs.

**C. Recoverability.** Enable the AD Recycle Bin and distribute FSMO roles so a
single DC outage is survivable. Both are immediate and need no storage
decision.

The system-state backup target is **deliberately deferred** — the candidates
(an SMB share on the ZFS host, a local volume replicated off-box, or
cross-site to LINDS) trade off differently and none of them should hold up A,
B or D. Event 2089 stays unresolved until that follows.

**D. DFS-R rehook.** Add `jd-fs-01` as a member of the `NAS` group with content
paths on `D:`, rebuild connections to `linds-dc`, and remove the two stale
`linds-dc` member objects. Existing data on both sides is preserved; the
primary member designation decides authority for the initial sync.

### Out of scope

Creating a DFS namespace (worth doing later — it is the prerequisite for moving
data again without touching clients, but it is not needed to restore
replication). Declarative GPO enforcement. AD user, group and OU lifecycle.
Reformatting the data volume. ZFS. Anything in the Terraform repo beyond
recording the drift noted above.

## Approach

Fixes are applied by hand or by targeted ad-hoc PowerShell first, verified,
then written as Ansible describing the corrected state. Codifying before
verifying would mean asserting settings onto a live domain whose behaviour we
have not yet confirmed.

Enforcement is split by blast radius:

- **Ansible enforces** what converges safely and idempotently: AD sites,
  subnets and site links (`microsoft.ad.object`), DNS zone and record settings,
  time configuration, SMB and NTFS settings, share and NTFS ACLs, DFS-R
  membership, guest-tool package state, Recycle Bin state.
- **Ansible backs up and reports** what does not: GPOs get scheduled
  `Backup-GPO` runs committed to git plus a drift report. GPO *authoring* stays
  in GPMC. Re-importing a GPO is not an idempotent operation and must not run
  unattended against a live domain.

Terraform keeps owning VM shape — disks, NICs, CPU, boot order. Ansible owns
what runs inside. There is no credible Terraform provider for AD internals.

## Access layer

Committed to `LINDS-Ansible`:

- `krb5.conf` — realm `LINDS.COM.AU`, the three DCs as KDCs, `dns_lookup_kdc`
  enabled. Referenced through `KRB5_CONFIG`; the system file is left alone.
- `inventory/windows.yml` — group `windows`, children `windows_dc` and
  `windows_fileserver`, hosts as FQDNs so Kerberos SPNs match.
- `group_vars/windows/` — `ansible_connection: winrm`,
  `ansible_winrm_transport: kerberos`, `ansible_winrm_message_encryption:
  always`, and `ansible_winrm_kerberos_delegation: true`.
- `Makefile` targets `venv` and `kinit`.

No credentials are stored. Authentication comes from the operator's ticket
cache, obtained with `kinit` before a run.

Two constraints found while establishing access, both of which the roles must
respect:

- The venv must be built against `/usr/bin/python3`, not the nix Python.
  `pykerberos` links against the system MIT krb5 and cannot load under nix's
  glibc.
- Kerberos delegation is **required**, not optional. The GPMC cmdlets make an
  onward LDAP bind and fail with `LDAP_OPERATIONS_ERROR (0x80072020)` without a
  forwarded ticket. CredSSP is the usual workaround and is rejected here
  because it weakens the servers; a forwardable ticket achieves the same with
  no server-side change.

## Risks and rollback

Workstream A changes which DC clients authenticate against. It is reversible by
moving DC objects back to a single site, and no data is touched. The drive map
edit is reversible from the GPO backup taken first.

Workstream B touches a CA that has been broken for two years; reissuing
certificates may surface further problems. Nothing is deleted — the existing
expired certificates stay in place until replacements are confirmed working.

Workstream C is additive. Enabling the AD Recycle Bin is **irreversible** —
that is accepted deliberately; it can only help.

Workstream D moves data. The primary-member designation determines which side
wins the initial sync, so it must be set explicitly rather than defaulted, and
the 100 GB staging quotas must be checked against the largest files before
seeding.

## Verification

Each workstream has a concrete check, run before and after:

- **A** — `nltest /dsgetdc:linds.com.au` from a JD client returns a JD DC;
  `Get-ADReplicationSubnet -Filter *` lists every subnet; event 4098/4117
  count for Group Policy Drive Maps drops to zero over 24 hours.
- **B** — `certutil -ping` against the CA succeeds; each DC holds an unexpired
  Kerberos Authentication certificate; `ldp.exe` binds on 636; the
  CertificateServicesClient event count drops to zero. `vmStatsProvider` events
  stop on both LINDS DCs.
- **C** — `Get-ADOptionalFeature 'Recycle Bin Feature'` reports a populated
  `EnabledScopes`; `netdom query fsmo` shows roles on more than one host.
  (Backup verification arrives with the deferred backup work.)
- **D** — `Get-DfsrBacklog` between `jd-fs-01` and `linds-dc` returns to zero
  for all seven folders; `Get-DfsrMembership` lists exactly two members per
  folder; DFSR event 5008 stops.

The event-log aggregation used during discovery is the overall regression test:
total Critical/Error/Warning volume over 7 days should fall from roughly 5,200
to a few hundred.
