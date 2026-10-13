# Windows domain (linds.com.au)

Four Server 2025 guests, managed over WinRM with Kerberos. Terraform owns the
VMs (`LINDS-Terraform/proxmox/vms-jd.tf`, `vms-linds.tf`); Ansible owns what
runs inside them, and can build one from nothing: see "Building a server from
the template" below.

| Host | Address | Site | Role |
| --- | --- | --- | --- |
| `jd-dc-01` | 10.0.50.200 | JD | DC, GC, DNS, **PDC emulator + RID master** |
| `linds-dc` | 10.3.1.200 | LINDS | DC, GC, DNS, schema + naming + infrastructure master, `linds-CA`, file server, 11 TB `E:`. Rebuilt from the template on 12 October 2026 |
| `linds-dc2` | 10.3.1.201 | LINDS | DC, GC, DNS. Rebuilt from the template on 11 October 2026 |
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
  the intermittent slow logons. It also keeps the `_msdcs` delegation in the
  forest's DNS zone naming every domain controller: retiring the server it
  named removes it, and nothing else puts it back.
- **`windows_ad_recovery`** — AD Recycle Bin and FSMO placement.
- **`windows_dc_time`** — domain time hierarchy. Reads the current PDC from AD
  rather than taking it as a variable, so moving the role moves the time
  authority with it.
- **`windows_baseline`** — firewall on for all profiles, Defender real-time
  protection on, SMB1 removed, Print Spooler off, event logs big enough to
  hold more than a day, Remote Desktop with NLA, and (only when asked) Windows
  updates. A server built from the template gets it as it is built. The
  servers that were here before do not, until `make windows-baseline
  HOST=<fqdn>` is run against them; `make windows` does not apply it.
- **`windows_bootstrap`, `windows_domain_join`, `windows_edition`,
  `windows_domain_controller`, `windows_dc_retire`, `windows_ad_converge`** —
  the stages of building and replacing a server. They run from
  `playbooks/windows-build.yml` and `playbooks/windows-retire-dc.yml`, not
  from `make windows`.
- **`windows_dfsr`** — the NAS replication group: group, replicated folders,
  members, content paths, staging and conflict quotas, and connections.
  `PrimaryMember` is deliberately not declared; it is a one-shot initial-sync
  flag that DFSR clears itself, so asserting it would re-arm an initial sync on
  every run. Staging quotas are per folder (`dfsr_staging_quota_overrides_mb`);
  the conflict quota is one value and is only ever raised, because lowering it
  purges the oldest conflict copies at once.

## Building a server from the template

Three tools, each doing the part it is good at:

| Step | Tool | Where |
| --- | --- | --- |
| Install Windows unattended, add VirtIO drivers and the guest agent, sysprep, leave a template | Packer | `LINDS-Terraform/packer/windows/` |
| Clone the template into a VM with the right CPU, memory, disk and VLAN | Terraform | `LINDS-Terraform/proxmox/vms-linds.tf` |
| Name, address, baseline, updates, domain join, edition, promotion | Ansible | `playbooks/windows-build.yml` |

The host has to be in `inventory/windows.yml` first, with its `windows_*`
variables (`linds-dc2` is the example). Then:

```shell
# in LINDS-Terraform/proxmox
terraform apply -target=proxmox_virtual_environment_vm.linds_dc2
terraform output windows_bootstrap_addresses     # the clone's DHCP address

# here
make windows-prepare HOST=linds-dc2.linds.com.au ADDRESS=<that address>
make windows-edition HOST=linds-dc2.linds.com.au ADDRESS=<that address>   # asks for the product key
make kinit
make windows-build   HOST=linds-dc2.linds.com.au ADDRESS=<that address>
make windows-promote HOST=linds-dc2.linds.com.au
```

What each one does:

- **`windows-prepare`** talks to the clone as its local Administrator over
  NTLM (the password is `vault_windows_bootstrap_password`, the same one the
  template was built with) at the address DHCP gave it, and applies
  `windows_baseline` including Windows updates. About an hour on
  `linds-proxmox-01`, nearly all of it the cumulative update. Nothing in the
  domain, and no server that still has the name, can tell it is happening.
- **`windows-edition`** converts an Evaluation install to the full edition
  with `dism /online /set-edition`, using a product key typed at the prompt.
  The key is passed in the environment for that one run; it is not stored,
  logged or put on a command line. On a server that is already a full edition
  it does nothing. With `ADDRESS` it works on the clone before it has joined;
  without, on a domain member over Kerberos.
- **`windows-build`** gives the machine its name and static address, runs the
  baseline again (minutes, if `windows-prepare` has been run) and joins the
  domain. The join is offline: an existing domain controller creates the
  computer account and a one-time blob (`djoin /provision`), the new machine
  consumes it (`djoin /requestodj`). No domain credential ever reaches the new
  machine, and nothing has to delegate one to it.
- **`windows-promote`** installs AD DS and DNS, promotes the member to an
  additional domain controller and global catalog in its site, waits for
  SYSVOL, sets the DNS forwarders and the server's own resolver order, tells
  the other domain controllers about it, waits for its RID pool, runs
  `dcdiag`, enrols its certificate from the domain's CA and checks that LDAPS
  answers, puts it in the time hierarchy and closes the template's bootstrap
  WinRM rule. The restore-mode password is `vault_windows_dsrm_password`
  unless one is typed. Eleven to seventeen minutes.

**What the server becomes follows the groups it is in** in
`inventory/windows.yml`, and a server can be in several: `windows_dc` (promoted
as above), `windows_ca` (the CA is installed, restored from the vaulted backup
if there is one) and `windows_fileserver` (its data disk is brought online and
its shares and exports recreated). `make windows-promote` does all that apply.

From the promote stage on, the server is managed like the others: `make
windows` covers it.

Things that were learned the hard way and are now built in:

- **An Evaluation install cannot be converted once it is a domain
  controller.** The promote stage therefore refuses an Evaluation edition.
  `-e windows_edition_allow_evaluation=true` overrides that for a throwaway;
  an Evaluation server stops working 180 days after it was installed.
- **The two sites replicate every 15 minutes, and nearly every step trips
  over that.** A computer account created at LINDS is unknown at JD, where
  the operator's Kerberos client asks first, and the answer is "Server not
  found in Kerberos database". After a demotion at LINDS, JD still lists the
  server as a domain controller and holds its account, and for a reused name
  would issue tickets for the old machine. A new domain controller has no RID
  pool until the RID master at JD knows it. `windows_ad_converge` deals with
  all three: it has every domain controller recalculate its topology
  (`repadmin /kcc`) and pull from its partners (`repadmin /syncall <dc>
  /Aed`, twice), then waits until all of them hold, or no longer hold, the
  computer in question. A push from the one that has the change (`/syncall
  /AdeP`) reported success and moved nothing.
- **The connection between the sites moves.** While a third domain
  controller existed at LINDS, JD's inbound connection was re-pointed at it,
  and JD was left without a partner when it went. The retirement moves it
  onto the domain controller that stays before it demotes anything; see
  "replacing a domain controller".
- **A ticket can outlive the key it was issued under.** A machine changes
  its password as it joins, at the nearest domain controller. A ticket for it
  requested a minute later from the other site was issued under the previous
  key. The member accepted it, because a member remembers its previous
  password; once promoted it refused it, and the restart after promotion sat
  on "the specified credentials were rejected by the server". The same
  happens, sooner, when a name is reused. The join stage therefore replicates
  the new key everywhere and then runs `kinit -R`, which keeps the
  ticket-granting ticket and drops every service ticket.
- **"Update for Windows Security platform" (KB5007651) installs, reports
  success and is offered again.** `win_updates` calls that a loop and fails
  after everything else has gone in. It is in
  `windows_baseline_update_reject` and left to Windows' own updater.
- **A domain controller certificate has an empty subject**; its names are in
  the alternative-name extension. A check for LDAPS that looks at the subject
  never passes.
- **A demoted server refuses new logons until it has restarted** ("Access is
  denied"): it is no longer a domain controller and not yet a member. The
  demotion therefore queues its own restart from inside the session that
  demotes.
- **Server 2025 locks the local Administrator out** for ten minutes after ten
  bad logons, and refuses all logons while setup is still running. A clone
  therefore does not answer WinRM at all until setup has finished (that is in
  the template), and the bootstrap stage simply waits for it.
- **Renaming and re-addressing over the connection being used** cannot be done
  as two ordinary tasks. The bootstrap stage hands the machine a script and 20
  seconds' notice; it does both and restarts, and the next stage waits for it
  on the new address.
- **Group variables must sit beside the inventory** (`inventory/group_vars/`).
  A `group_vars/` at the top of the repository is not read by
  `ansible-playbook playbooks/x.yml`.
- **The inventory connects by address, Kerberos needs the name.**
  `ansible_winrm_kerberos_hostname_override` in the group variables supplies
  it. Variables set on a play also apply to its `delegate_to: localhost`
  tasks, which is why the bootstrap plays have none.
- **Nothing before the promotion can be re-run against a finished domain
  controller.** It has no local Administrator left to connect as. Each stage
  can be repeated up to that point.

A rehearsal identity is the safe way to try a change to any of this: a second
inventory file with a different name and address for the same VM, passed with
`-i inventory/ -i <file>`, and `make windows-retire-dc` to take it out again.

## A server with a data disk

The NAS volumes outlive the servers that serve them. A data disk is never
created, formatted or resized by any of this. It belongs to another VM on the
hypervisor and is attached to the server's VM by reference:

```shell
make windows-data-disk HOST=linds-dc.linds.com.au
```

reads `windows_vm` from the inventory and, on the hypervisor, attaches each
disk listed there to the server's VM. **It refuses while any other VM that
has the disk is running**: two machines writing one NTFS volume destroy it.
It also sets those other VMs not to start with the host, and protects the VM
that owns the volume from deletion.

Why this is safe: Proxmox deletes only the volumes that carry the ID of the
VM being destroyed. Tried with a 4 GB dummy disk on 12 October 2026: a VM
with the dummy attached by reference was replaced through Terraform, and
later destroyed outright; the disk and the file on it were there each time.
The LINDS-Backup VM has attached the NAS disk this way for years.

On a freshly built server the disk arrives **offline, read-only and under
whatever drive letter was free**. `windows_fileserver` finds the volume by
its label, brings it online and gives it its letter; then, if the server is
to be a replication member, clears the previous member's replication state
from it (the database under `System Volume Information\DFSR` and the
`DfsrPrivate` link in each folder, as the two DFS-R runbooks below require);
then recreates what lives on the server rather than on the disk: SMB shares
and their permissions, NFS exports and their clients, and the shadow-copy
schedule. File permissions need nothing: they are on the disk and name domain
accounts.

A server's shares are in `inventory/host_vars/<fqdn>/fileserver.vault.yml`
(`ansible-vault edit`).

## The CA in code

```shell
make windows-ca-backup               # key, database, settings into windows-state/ca/backup
make windows-ca HOST=<fqdn>          # install on HOST: restored if there is a backup, new if not
```

`windows_ca` installs the role and then either restores the CA from the
vaulted backup (same name, same key, same database: everything it issued
stays valid and stays revocable) or creates a new one. The certificate
templates it issues are `windows_ca_templates` (for `linds-dc`, in its
`host_vars`): after a restore the CA publishes the default set, because the
list lives in the directory and goes when the role is removed.

Installing a CA writes to the forest's configuration, so that part runs as
the operator; the database is only handed over to, and taken back from, the
server's own SYSTEM account, which is why those two steps use `become`.

**A domain controller cannot be demoted while it has the CA role.** The
retirement backs the CA up one last time and removes the role first. From
that point the old server cannot simply be switched back on as the CA: the
way back is the restore.

## A new forest

```shell
ansible-playbook -i <inventory> playbooks/windows-forest.yml \
    -e target=<fqdn> -e windows_forest_domain=<domain>
```

Makes a freshly built server the first domain controller of a domain that
does not exist yet; every other server then joins with
`playbooks/windows-build.yml`. It exists for two things: a lab to rehearse in,
and the day `linds.com.au` has to be rebuilt from nothing (there are no
system-state backups, by decision; see "Known outstanding"). In that case
the order is: this, then `make windows-directory` to recreate the OUs, groups,
users and GPO links from `directory*.yml`, `Import-GPO` from
`windows-state/gpo/*/backup`, the CA from its backup, and the file servers.
Every account gets a new identity, so NAS permissions and every joined
machine have to be redone.

It refuses to run if a domain of that name already answers.

## Runbook: replacing a domain controller

Done for `linds-dc2` on 11 October 2026, whose component store could no
longer take a cumulative update (see that runbook further down). The
replacement takes the old one's name and address, so nothing that refers to it
changes: the DNS forwarders on the router, the Keycloak LDAP URLs, `krb5.conf`
and this inventory. That swap took 31 minutes from start to a healthy domain
controller: 13 for the retirement, 7 for name, address and join, 11 for the
promotion. Keycloak logged no LDAP errors meanwhile; it has all three domain
controllers in its URL list.

Before starting, check what the old server holds that the directory does not:

- **FSMO roles**: `netdom query fsmo`. The retire role refuses a role holder;
  move the roles first (`windows_ad_recovery`).
- **DNS zones that are not AD-integrated**: `Get-DnsServerZone | Where-Object
  { -not $_.IsDsIntegrated -and -not $_.IsAutoCreated }`. Anything listed
  would be lost. Forwarders are per server and are set by the promote stage.
- **Shares other than SYSVOL and NETLOGON**, scheduled tasks, installed
  software, certificates with private keys.

Then the order matters, because the site has one domain controller fewer
from the retirement until the promotion has finished:

```shell
# While the old server is still in service. An hour or more, and the product
# key; none of it touches the domain.
terraform apply -target=proxmox_virtual_environment_vm.linds_dc2 \
                -replace=proxmox_virtual_environment_vm.linds_dc2    # LINDS-Terraform/proxmox
make windows-prepare HOST=linds-dc2.linds.com.au ADDRESS=<its DHCP address>
make windows-edition HOST=linds-dc2.linds.com.au ADDRESS=<its DHCP address>

# The swap. About half an hour, with `repadmin /replsummary` clean beforehand.
make windows-retire-dc HOST=linds-dc2.linds.com.au REPLACING=true
make windows-build     HOST=linds-dc2.linds.com.au ADDRESS=<its DHCP address>
make windows-promote   HOST=linds-dc2.linds.com.au
```

`REPLACING=true` is for exactly this case, a server of the same name about to
be built; leave it off when a domain controller is going for good. Every one
of these can be run again after a failure and carries on from where it
stopped.

`windows-retire-dc` first hands over whatever the server carries, and skips
each step that does not apply:

- its FSMO roles move to the site's other domain controller;
- it is checked for replicated files that only it holds (a member that
  rejoins with data already on its disk keeps only what its partner also
  has; `--tags unique-files` runs this check alone, worth doing the day
  before), and is taken out of its replication groups;
- the CA is backed up into `windows-state/ca/backup` and the role removed.

Then it does four things, the first and last on the site's other domain
controller:

1. Moves replication between the sites onto the domain controller that is
   staying, and proves it works in both directions (see below).
2. Demotes the old server, restarts it as a member and shuts it down. It
   refuses a FSMO role holder and the last domain controller.
3. Deletes the computer account and the empty server object a demotion
   leaves under the site, and waits until no domain controller at either
   site knows the name any more.
4. Removes the server's DNS records from every DNS server, and gives the
   choice of bridgehead back to the topology generator. With
   `REPLACING=true` it does not give it back: `windows-promote` does, once
   the replacement is known at both sites.

About a quarter of an hour, half of it waiting to see that the DNS records
stay gone. `--tags cleanup` runs steps 3 and 4 alone, for a server that is already
demoted and off; `--tags bridgehead` runs step 1 alone and touches nothing on
the server to be retired; `--tags bridgehead-release` undoes it.

Step 1 exists because replication between two sites runs through one domain
controller at each end, chosen by the topology generator, and the choice
moves: on 11 October it sat on `linds-dc`, then on a rehearsal server while
that existed, then on `linds-dc2`. If the server being retired holds it, the
other site loses its only partner at the demotion, cannot hear that the
partner was demoted, and by default waits two hours before trying another.
Everything after the demotion needs the sites to agree within minutes. So
the domain controller that stays is made the site's preferred bridgehead
(`bridgeheadTransportList` on its server object), every topology generator
is run, and the demotion does not start until a pull through that server has
succeeded in each direction. A preferred bridgehead left in place would stop
the generator choosing another one if that server went down, which is why it
is removed again at the end.

**Why the preference outlives the retirement when a replacement follows.**
After the `linds-dc2` swap the preference was released at once, and minutes
after the new `linds-dc2` was promoted the topology generator made it
`jd-dc-01`'s one partner at LINDS. To pull from a domain controller a server
needs a Kerberos ticket for that partner's replication service name
(`E3514235-4B06-11D1-AB04-00C04FC2DCD2/<NTDS GUID>/<domain>`), which sits on
the partner's computer account; `jd-dc-01`'s copy of that account was still
the one from before the promotion, without the name. The pull failed with
error 1396, "the target account name is incorrect", and because that pull
was the only way the corrected account could arrive, it went on failing.
**JD received nothing from LINDS from 17:59 on 11 October until 17:54 the
next day**, when step 1 of the `linds-dc` retirement refused to go on.
Changes made at JD still reached LINDS, and everything held up arrived once
the link worked, so nothing was lost; an account or group changed at LINDS
would not have been seen at JD in between. Two things now stop it happening:

- the preference stays on the old, known domain controller until the
  replacement's promotion has finished;
- after a promotion, `windows_ad_converge` runs on the site's other domain
  controller and pushes the new server's computer account, server object and
  NTDS settings straight to every domain controller that does not yet hold
  its replication name (`Sync-ADObject`, sent from a server the receiver can
  already authenticate), then fails unless every domain controller has an
  inbound partner and no failing link.

By hand, the sign is a link in `repadmin /showrepl <dc>` that fails with 1396
every time while the same partner's other links are fine, and the cure is
the push: `Get-ADComputer <new dc> | Sync-ADObject -Source <a DC that has it>
-Destination <the DC that lacks it>`, the same for its server object and the
`NTDS Settings` under it, then `klist -li 0x3e7 purge` and `repadmin /kcc`
on the receiver.

The DNS part is slower than it looks, on purpose. On a rehearsal the demotion
and a clean-up on one DNS server left nothing behind, and a minute later all
three DNS servers again held ten records for the retired machine: its
entries under `_kerberos._tcp`, `_ldap._tcp.gc` and the rest, the global
catalog's address record, and the domain's own (`linds.com.au` resolving, one
time in four, to a server that was switched off). A DNS server reads changes
from the directory only every three minutes and writes back all the records
of a name when it touches one, so a server that has not yet read a removal
can undo it. The playbook deletes on every DNS server and ends only when two
scans of all of them, more than three minutes apart, find nothing. If a
domain controller has been removed by other means, check for the same
leftovers: `Get-DnsServerResourceRecord -ZoneName linds.com.au | Where-Object
{ $_.RecordData.DomainName -like '<name>.*' }`, on each DNS server.

On the hypervisor, stop the old VM from coming back (`qm set <vmid> --onboot
0`) and keep it until the new one has been in service for a while. The old
`linds-dc2` is VM 110 on `linds-proxmox-01`, renamed `LINDS-DC2-old`; delete
it when nothing on its disk is wanted any more. It must
not be started again on the network: it would come up as a member whose
account no longer exists, at the address the new one now has.

The new server's `windows-build` renews the operator's Kerberos ticket once
it has joined, so that no ticket issued for the old server of that name is
offered to the new one.

Any other machine with a ticket cache of its own (another administrator's
session, a script host) still holds a service ticket for the old server, and
its connections to the new one are rejected until that ticket expires or is
renewed: `kinit -R`, or `klist purge` on Windows.

## The directory in code

```shell
make windows-directory-check     # what a run would change
make windows-directory           # make it so (also part of `make windows`)
```

`windows_directory` makes the domain match two files in
`inventory/group_vars/windows/`:

| File | Holds | How to edit |
| --- | --- | --- |
| `directory.yml` | OUs; which GPOs are linked to each, in order; the groups this repository owns | Any editor |
| `directory.vault.yml` | Users; who is in each owned group; the exact members of the privileged groups; the password policy and machine account quota | `ansible-vault edit` |

To add someone to a group, add their name under the group in
`windows_directory_members`. To add a user, add an entry to
`windows_directory_users` (and, if the account should be usable at once, a
first password under `windows_directory_initial_passwords`). To move a GPO
link or change its order, edit the list under its OU. Then check, then run.

What it will and will not do:

- **It never deletes an OU, group or user for being absent from the files.**
  The run ends with a list, "not in the code", of what exists and is not
  described. Today that is the groups products left behind (`ADSync*`,
  `docker-users`, `IPAMUG`, `WSUS *`, `DHCP *`) and `MSOL_abd8982191a0`, the
  account of the Entra Connect that no longer exists.
- **Membership is exact** for the groups in `windows_directory_members` and
  `windows_directory_privileged`. Someone added to Domain Admins in a console
  is taken out again by the next run. That is the point of listing the
  privileged groups; do not list a group there unless every member should be
  in the file.
- **GPO links are exact** for every container listed, in the order written
  (first wins). The GPOs themselves are not touched: they are edited in GPMC
  and captured.
- **It never sets the password of an existing account.**

The files were generated once, from the capture of 11 October 2026, by
`scripts/windows_directory_export.py`, so that the first run would change
nothing; it did not. Do not run the export again: it would overwrite the
files with whatever the domain looks like at that moment.

`--check` cannot preview the membership of a group or user that the same run
would create, because it does not exist yet; those show as ignored errors in
a check run and work in a real one. And in a script that supports `--check`,
`ForEach-Object <property>` returns nothing under `-WhatIf`; use a script
block. That made the first check run propose unlinking every GPO.

## The state of the domain, captured

```shell
make windows-capture             # into ./windows-state
git diff -- windows-state        # what changed since the last one
```

Reads the domain as it is and writes it out as a few dozen YAML files (and
the GPO backups) with a fixed layout and ordering. It changes nothing on the
servers. A capture of an unchanged domain produces an empty diff: logon
times, free space, update revisions and everything else that moves by itself
is left out. So whatever the diff shows was changed by somebody, or by
something, since the last capture, whether through this repository or in a
console.

| Folder | What is in it |
| --- | --- |
| `domain/` | The domain (levels, FSMO holders, password policy), sites and subnets, OUs with their GPO links in order, every group with its members, every user and computer with the flags that matter (delegation, pre-authentication, password never expires, SPNs), service accounts, who is in the powerful groups with nesting followed, and the explicit permissions on the domain root, AdminSDHolder and each OU |
| `gpo/` | One folder per GPO: `report.xml` (the settings, readable), `gpo.yml` (versions, status, who may edit or apply it), `backup/` (what `Import-GPO` restores from). A backup is replaced only when the GPO's version has moved |
| `dns/` | Zones and their settings (dynamic updates, transfers, aging), and the records somebody created. Records machines register for themselves are left out |
| `ca/` | The CA's settings and who may manage it, every certificate template with who may enrol and the three settings that make a template dangerous, and the directory's trust stores |
| `hosts/<server>/` | Features, shares with share and NTFS permissions one level down, NFS exports, services that are not Windows' own or log on as an account, scheduled tasks, installed software, and security settings as they are on the server (firewall, Defender, SMB, LSA, RDP, SSH, time) |

It runs from `jd-dc-01` for the directory, every server in the `windows` group
for the per-server part, and the `windows_ca` group for the CA. About five
minutes.

The result is committed in [`windows-state/`](../windows-state/). **This
repository is public**, so the files that name people, say who holds which
rights or show what is weak or switched off are encrypted with the vault as
they are written: users, groups, computers, privileged membership,
delegation, the domain's password policy, every GPO's settings and backup,
certificate template permissions, DNS zone settings, and each server's
shares, services, software and security settings. What stays readable is the
structure: sites, the OU tree with its GPO links, DNS records, each server's
features and addresses, the CA's settings and public certificates. The list is
`SENSITIVE` in `scripts/windows_state.py`.

```shell
ansible-vault view windows-state/domain/privileged.yml          # one file
git config diff.ansible-vault.textconv "ansible-vault view"     # once per clone: readable git diff
make windows-state-plain DEST=/dev/shm/windows-state            # a readable copy of everything
```

An encrypted file is rewritten only when its content has changed, so an
unchanged domain still leaves `git status` clean. On GitHub the diff of an
encrypted file is unreadable; read it locally.

### Backing up the CA

```shell
make windows-ca-backup
```

Writes into `windows-state/ca/backup/`:

| File | What | Stored |
| --- | --- | --- |
| `linds-CA.p12` | The CA's certificate and private key | Ansible vault |
| `linds-CA-database.zip` | What it has issued and revoked | Ansible vault |
| `linds-CA-configuration.reg` | Its registry settings | Plain text |
| `password.yml` | The password of the `.p12` | Ansible vault |

and ends by opening what it stored and checking that the private key belongs
to the certificate. The `.p12` is password-protected from the moment the CA
writes it and never exists unprotected; the password is generated here, kept
for later runs, and stored separately.

The key only changes when the CA certificate is renewed. The database changes
with every certificate issued or revoked: run this after anything that
matters, and always immediately before moving the CA to another server.

The backup has to run as the CA server's own SYSTEM account (`become` with
`runas`). The CA refuses to hand its database to a network logon, which is
what a WinRM session is: `Backup-CARoleService` fails in `BackupDatabase` with
"Access is denied" for a domain administrator.

To restore onto a server that has the CA role installed but not configured:
`ansible-vault decrypt` the three files, unzip the database into `DataBase\`
beside the `.p12`, then `Restore-CARoleService -Path <folder> -Password
<password> -Force` and `reg import` the settings. The CA keeps its name, so
everything it has issued stays valid.

**The key is in a public repository, so it is exactly as safe as the vault
password.** Whoever has that can issue certificates the whole domain trusts,
including logon certificates for any account and client certificates for the
mTLS ingress. So is everything else in the vault here. A longer vault password
protects what is committed after it is changed; what is already in the
history stays under the password it was encrypted with.

## Runbook: replacing `linds-dc`

Done on 12 October 2026. `linds-dc` is a domain controller, the CA and the
LINDS file server, and holds three FSMO roles. It is now VM 113
(`LINDS-Terraform`, `proxmox_virtual_environment_vm.linds_dc`), built from the
template. The old one is VM 102, `LINDS-DC-old`: switched off, set not to
start, protected from deletion, and **kept, because the NAS disk
(`NAS:vm-102-disk-0`) carries its ID** and Proxmox deletes a VM's own volumes
with it. Never start it: it would mount the disk the new server is writing.

```shell
# Before, while the old server is in service. Nothing here touches the domain.
make windows-prepare HOST=linds-dc.linds.com.au ADDRESS=<clone's DHCP address>
make windows-edition HOST=linds-dc.linds.com.au ADDRESS=<clone's DHCP address>
make windows-capture && git commit                  # the state as it is, for comparing afterwards
ansible-playbook playbooks/windows-retire-dc.yml --tags unique-files -e target=linds-dc.linds.com.au

# The swap. The CA is off from the first command and the LINDS NAS and its NFS
# exports from the demotion inside it, until the last command has finished.
make windows-retire-dc HOST=linds-dc.linds.com.au REPLACING=true   # hand over, demote, shut down, clean up
qm stop 102; qm set 102 --onboot 0 --name LINDS-DC-old             # on linds-proxmox-01, if it is not already off
make windows-data-disk HOST=linds-dc.linds.com.au   # the NAS disk onto VM 113
make windows-build     HOST=linds-dc.linds.com.au ADDRESS=<clone's DHCP address>
make windows-promote   HOST=linds-dc.linds.com.au   # DC, CA restored, disk online, shares, exports
make windows                                        # replication member re-added (never as primary), FSMO roles placed
make windows-ca-backup && make windows-capture && git commit       # the CA as restored, and what changed
```

**How it went.** 2 h 17 min from the first command (17:25) to the last
(19:42): retirement 53 min, disk under a minute, name, address and join 22,
promotion 59. The NAS was unreachable for about 1 h 40 min and the CA for a
little longer. Three stops are in those figures, each for something the
playbooks now handle: the bridgehead check refusing because JD could not pull
from `linds-dc2` (the account above), the new domain controller not being
announced to the other site before the steps that needed it, and the restored
CA being asked for a CRL in the second it started. Each time the same command
was run again and went on.

What the new server was checked for afterwards, and had:

- domain controller and global catalog at the old name and address, health
  checks clean, replication with both other domain controllers in both
  directions, its replication name known at JD;
- schema, naming and infrastructure master back on it, PDC emulator and RID
  master still on `jd-dc-01`;
- `linds-CA` running with the certificate it had (thumbprint ending
  `7699BC3F`), its issued certificates on record and its templates published,
  and its own LDAPS certificate issued by it;
- `E:` online with every folder and the 64 shadow copies that were on it;
  shares `NAS` and `RedirectedFolders$`; the NFS export, 4.1 only, for the
  same three clients;
- Keycloak with no LDAP errors throughout (it lists all three domain
  controllers).

**Replication afterwards.** The member is re-added with the data already on
its disk. The service first walks the whole disk to build a new database, one
folder at a time, and until a folder's turn comes it shows as
`uninitialised` with no event at all, which looks like nothing happening: the
debug log (`C:\Windows\debug\Dfsr*.log`, `DirWalkerTask` lines) shows the
walk. Then each folder logs 4102, hashes its files against JD, copies nothing
that matches, and logs 4104.

**It took 33 hours** for the nine folders and their 635,000 files: re-added at
19:48 on 12 October, the walk done at 20:18, the last folder normal at 04:52
on 14 October. Folders finish one after another, small ones first: `Music`
in two minutes, the three largest more than a day in. Almost nothing crosses
the tunnel meanwhile (under 1 GiB in the first 29 hours). Three things to
know before doing it again:

- **It writes to the data disk.** To hash a file the service first stages a
  copy of it under `DfsrPrivate\Staging` on the same volume, so it reads and
  writes about as much as there is data, at 40 MB/s here. Staging is kept up
  to each folder's quota, and on thin storage that is real growth: the LINDS
  thin pool went from 52.6% to 60.9%, about 920 GiB. Some 550 GiB of that is
  staging, which stays; about 260 GiB is space the guest has freed and the
  pool did not get back (the reclaim runbook below returns it). Check the
  headroom first: this pool has been full once.
- **Estimate the end from the backlog, not from bytes read.** `dfsrdiag
  backlog /rgname:NAS /rfname:<folder> /smem:<partner> /rmem:<this server>`
  twice, some minutes apart, gives files per minute for the folder being
  worked on; the folders behind it do not move until it is done. One very
  large file holds its folder for hours and needs staging room for about
  three copies of itself: a 39 GiB file here had 107 GiB of staging against a
  100 GiB quota, with a 4206 warning ("failed to clean up old staging files")
  every half hour until it was through.
- **A 4412 during the first sync is a file that did not match, and is worth
  reading.** The rejoin is the one time every file at a site is compared with
  the other site by content. Here it found one: a 39 GiB file whose LINDS
  copy held 3.4 GiB of zeros, in runs of 192 KiB every 256 KiB across a
  4.5 GiB stretch, under the same size and dates as the good copy at JD.
  That is the mark of a thin pool with 64 KiB chunks filling while a file is
  written, and this pool filled on 15 August 2026, days after replication
  had rewritten these folders. Replication never noticed, because afterwards
  it only looks at files that change. This time the service fetched the
  differing parts from JD (3.4 GiB over the tunnel), installed the good file
  and moved the damaged one to `DfsrPrivate\ConflictAndDeleted`, where the
  two can be compared block by block. Every other file matched.

There must be nothing in a folder's `DfsrPrivate\PreExisting`.

**The LINDS-Backup VM (104)** still mounts the same disk for its Backblaze
runs. Its routine is now: shut VM 113 down, start 104, and the reverse; never
the two at once, and never VM 102. `make windows-data-disk` refuses to attach
the disk while either of the others runs, but nothing stops a VM being
started by hand.

**What did not come across**, because it was never in code: AnyDesk,
TeamViewer, Chrome, VMware Tools, the Milestone and IPAM leftovers, the dead
shadow-copy tasks, the share `D` (it pointed at a drive that did not exist),
the printer-driver share, and the computer account's membership of the three
`RDS ...` groups left from a Remote Desktop deployment that no longer exists.
An expired certificate of an earlier CA (`linds-LINDS-DC-CA-1`, ended 2024)
was in the old server's own trust store and is not in the new one's.

NFS clients hold a mount of a server that went away; one that does not
recover by itself needs remounting. No client had reconnected twenty minutes
after the swap.

**Rehearsed first** in a separate two-server lab forest (`iaclab.test`), built
with these same playbooks: one server carrying the CA, a data disk with a
share and an NFS export, a replicated folder and all five FSMO roles was
retired and rebuilt from a fresh clone with the same disk. What a lab of one
site could not show is what stopped the real run: two sites that hear of
changes a quarter of an hour apart.

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

## Entra Connect (was on `linds-dc2`; not installed anywhere now)

**Since 11 October 2026 nothing syncs this domain to Entra.** Entra Connect
lived on the old `linds-dc2`, which was retired that day, and the build does
not put it on a domain controller again. Nothing that was working stopped: it
had been in staging mode since November 2024, so it exported nothing, and its
pass-through agent had been dead since May 2025. Its configuration export
(52 files) and persisted state are in
`\\linds-dc\NAS\server\backup\linds-dc2-before-rebuild-2026-10-11`. To bring
it back, install it on a member server, import that configuration, and decide
in the wizard between pass-through authentication (which needs a new agent)
and password hash sync. The old server's disk (VM 110, `LINDS-DC2-old`) still
holds the original installation.

The rest of this section records the installation as it was.

The old `linds-dc2` ran Entra Connect Sync 2.6.3.0 against the tenant
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

This was the old `linds-dc2`, VM 110, retired on 11 October 2026. The VMs
Terraform creates set `ostype: win11`, so its replacement does not have the
problem; the runbook stays because the symptoms mislead and any hand-made
Windows VM can have it.

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

## Runbook: a cumulative update that will not install (`linds-dc2`)

Closed on 11 October 2026 by replacing the server; the new one installed the
same update (KB5122871) in 55 minutes. Kept for the diagnosis.

The old `linds-dc2` had been on build 26100.3476 (March 2025) while the other three
moved on. On 10 October 2026 the reasons came out one behind the other.

1. **No disk space.** 3 GB free of 70; the Windows Update cache alone held
   15 GB. Fixed: cache reset, disk grown to 100 GB.
2. **`0x800F0831`, store corruption.** The servicing store listed two packages
   from a half-installed earlier update but had lost their files. The exact
   names are in the "Checking System Update Readiness" summary near the end of
   `C:\Windows\Logs\CBS\CBS.log` (read it with `Get-Content -Tail`; the logs are
   hundreds of megabytes). `DISM /Online /Cleanup-Image /RestoreHealth` ran for
   49 minutes and could not fetch them (`0x800f0915`). Fixed by copying the
   four `.mum` and `.cat` files from a healthy server's
   `C:\Windows\servicing\Packages`: they were byte-identical on all three and
   their catalogs carry a valid Microsoft signature. `robocopy /B` writes into
   that folder; set the owner back to `NT SERVICE\TrustedInstaller`.
   `dism /online /get-packageinfo /packagename:<name>` then answers instead of
   failing.
3. **`0x80070306`, hydration.** Not fixed. The update now gets as far as
   staging and fails rebuilding files from the deltas it downloads
   ("Hydration failed ... Forward Delta"). The installed versions of those
   components (26100.3037) have no reverse-delta files (`r\` under the
   component's `WinSxS` folder) on this server; healthy servers have them.
   Emptying `SoftwareDistribution\Download` and letting Windows Update work the
   payload out again made no difference.

Two things to know when retrying:

- Windows' own updater installs the moment a download completes, so a manual
  install through the Windows Update API is refused (`0x80240016`). Watch the
  update history instead of racing it.
- From a build that old, the download stage alone can take over an hour of
  CPU-bound work with no network traffic. That is slow, not stuck.

What is left is a repair install of Server 2025 over the top, or replacing
this domain controller.

## What is deliberately not managed here

**GPOs are not enforced declaratively.** Re-importing a GPO is not an
idempotent operation and must not run unattended against a live domain.
Authoring stays in GPMC. They are captured instead: `make windows-capture`
backs up every one and its settings report into the state directory, and the
diff is the drift report.

**AD users, groups and OUs** are managed by `windows_directory`; see "The
directory in code". Computer accounts are not: machines create their own when
they join.

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

As of 14 October 2026.

- **Retrim fails on the guests**, so thin space is only handed back by the
  runbook above. Both sites were done on 10 October.
- **Nothing syncs to Entra.** Entra Connect went with the old `linds-dc2`;
  see the section above for where its configuration is and how to bring it
  back.
- **The old `linds-dc2` is still on the hypervisor**: VM 110, `LINDS-DC2-old`,
  switched off and set not to start. It was demoted first, so it holds no
  copy of the directory. Delete it when nothing on it is wanted.
- **The old `linds-dc` is still on the hypervisor and has to stay**: VM 102,
  `LINDS-DC-old`, switched off, set not to start and protected. It owns the
  NAS disk that VM 113 uses. Its own system disk (`local-lvm:vm-102-disk-0`,
  74 GB in use) can be detached and deleted to give the space back; the VM
  cannot go, because the NAS volume would go with it.
- **The new `linds-dc2` reports itself as not activated** (volume-licence
  channel, notification state). The other three were not checked for this.
- **Time does not follow the domain hierarchy.** The Default Domain Policy
  sets every member, domain controllers included, to `Type=NTP` with
  `0.au.pool.ntp.org`, and policy wins over what `windows_dc_time` configures:
  the role reports `ok` and `w32tm /query /source` on any server names the
  pool. Everything agrees because everything asks the same pool, but a machine
  that cannot reach the internet drifts. The setting belongs in a policy that
  applies to the PDC emulator alone.
- **`jd-dc-01` has 8.2 GB free on a 39.4 GB `C:`**.
- **DNS**: `linds.com.au` accepts nonsecure dynamic updates and scavenging is
  disabled on the servers. The stale public IPv6 `AAAA` records for `jd-fs-01`
  are gone.
- **There are no system-state backups, by decision** (12 October 2026). They
  were set up for a night and removed: each is about 20 GB whatever the size
  of the domain, because Windows defines a system state to include all of its
  own system files. A lost domain controller is rebuilt from the template and
  filled by replication. If the directory itself were lost or damaged beyond
  the Recycle Bin, the domain would be rebuilt from this repository, and the
  NAS permissions and every joined machine redone. Event 2089 on the domain
  controllers ("not backed up") is therefore expected.
- **Data on the LINDS NAS disk outside the replicated folders has been
  checked against nothing** since its thin pool filled on 15 August 2026. The
  rejoin of 12 October compared every replicated file with JD and found one
  damaged by that event (see "replacing `linds-dc`"); files that are not
  replicated, such as `E:\server`, had no such comparison.
- **`E:\server\old_backup` on `linds-dc`** is 248 GB of Veeam backups from
  2019 to 2021, of hosts that no longer exist.
- **Dead scheduled tasks**: `jd-dc-01` has two `ShadowCopyVolume{...}` tasks
  for volumes that no longer exist, failing twice a day.
- **`jd-dc-01` and `jd-fs-01` are the two servers not yet built from the
  template.** `jd-dc-01` is the only domain controller at JD and holds the PDC
  emulator and RID master; `jd-fs-01`'s 12 TB disk is a zvol that would move
  to its replacement the way the LINDS disk did.
