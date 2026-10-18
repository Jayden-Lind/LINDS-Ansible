# AD replication between the sites

The two sites replicate every 15 minutes, through one domain controller at
each site (the bridgehead).

## A new domain controller that the other site cannot pull from

**Symptom:** `repadmin /showrepl <dc>` shows a link that fails every time with
error 1396 ("The target account name is incorrect"). The other links of the
same partner work.

**Cause:** To pull from a domain controller, a server needs a Kerberos ticket
for the replication name of that partner
(`E3514235-4B06-11D1-AB04-00C04FC2DCD2/<NTDS GUID>/<domain>`). The name is on
the computer account of the partner. If the server has an old copy of that
account, it cannot get the ticket, and so it cannot pull the new account.
After the `linds-dc2` rebuild, JD received nothing from LINDS for 24 hours
because of this.

**Procedure:**

1. On a domain controller that has the new account, send the objects to the
   domain controller that does not have it:

   ```powershell
   $dc = Get-ADComputer <new dc>
   Sync-ADObject -Object $dc -Source <dc that has it> -Destination <dc that lacks it>
   ```

2. Do the same for its server object (under `CN=Sites`) and for the `NTDS
   Settings` object under the server object.
3. On the receiving domain controller, run `klist -li 0x3e7 purge` and
   `repadmin /kcc`.
4. Run `repadmin /showrepl` again. The link must work.

`windows_ad_converge` does steps 1 and 2 after each promotion. The retirement
with `-e windows_dc_retire_keep_bridgehead=true` keeps the bridgehead on the
old partner until the promotion is complete.

## DNS records of a removed domain controller come back

**Symptom:** After a domain controller is removed, DNS gives its records again
(`_ldap._tcp`, `_kerberos._tcp`, the A record of the domain).

**Cause:** A DNS server reads changes from the directory every three minutes,
and writes back all records of a name when it changes one.

**Procedure:**

1. On each DNS server, look for the records:

   ```powershell
   Get-DnsServerResourceRecord -ZoneName linds.com.au |
       Where-Object { $_.RecordData.DomainName -like '<name>.*' }
   ```

2. Delete them on every DNS server.
3. Look again after more than three minutes. Repeat until two scans find
   nothing.

`windows-retire-dc.yml` does this (tag `cleanup`).

## A demoted server refuses logons

**Symptom:** After the demotion, the server answers "Access is denied" to
every new logon.

**Cause:** The server is not a domain controller and not yet a member until it
restarts.

**Procedure:** Restart it from the Proxmox console. `windows_dc_retire`
restarts it from inside the demotion session.
