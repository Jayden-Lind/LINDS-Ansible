# windows-forest.yml

The playbook makes a new server the first domain controller of a new forest.
Use it for a test forest, or to make the domain again from nothing.

## Before you start

- The server has its name and address and is in no domain: run
  `windows-prepare.yml`, then `windows-join.yml` up to the name and address
  step, in a test inventory.
- Use your own inventory (`-i <inventory>`), not the inventory of the real
  domain.

## Procedure

1. Run:

   ```shell
   ansible-playbook -i <inventory> playbooks/windows-forest.yml \
       -e target=<fqdn> -e windows_forest_domain=<domain>
   ```

2. Join the other servers with `windows-join.yml`.

**WARNING:** The playbook refuses a domain name that answers in DNS. Never use
the name of the real domain.

## To make the real domain again from nothing

1. Make the forest with this playbook.
2. Run `ansible-playbook playbooks/windows.yml --tags gpo,directory` to make
   the OUs, groups, users, the GPOs that the code owns, and the GPO links.
3. Import the other GPOs from `windows-state/gpo/*/backup` with `Import-GPO`.
4. Restore the CA with `windows-ca.yml`.
5. Make the file servers with `windows-promote.yml`.

**NOTE:** Every account gets a new identity (SID). The permissions on the NAS
and the membership of every computer must be done again.
