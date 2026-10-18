# windows-join.yml

The playbook gives a new clone its name and static address, applies the
baseline, and joins it to the domain.

## Before you start

- `windows-prepare.yml` and `windows-edition.yml` are complete.
- Run `kinit -f Administrator@LINDS.COM.AU`.
- If a server with the same name exists, retire it first
  (`playbooks/windows-retire-dc.md`).

## Procedure

1. Run the playbook:

   ```shell
   ansible-playbook playbooks/windows-join.yml -e target=<fqdn> -e bootstrap_address=<DHCP address>
   ```

2. If you run it again after a failure and the server already has its static
   address, leave out `-e bootstrap_address`.

## What it changes

1. The clone gets its name and static address, and restarts.
2. The baseline runs again at the static address.
3. A domain controller makes the computer account and the offline-join data.
   The server uses the data and restarts as a domain member.
4. Every domain controller gets the new computer account.
5. The playbook renews your Kerberos ticket. This discards old tickets for a
   server with the same name.

## If it fails

- "Server not found in Kerberos database": the account is not at your domain
  controller yet. Run the playbook again.
- "The Kerberos ticket did not renew": run
  `kinit -f Administrator@LINDS.COM.AU`.

## Next step

`playbooks/windows-promote.md`.
