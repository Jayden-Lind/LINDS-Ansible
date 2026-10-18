# windows-edition.yml

The playbook converts an Evaluation installation to the full edition with a
product key that you type.

## Before you start

- You have a product key for the edition in `windows_edition_target`
  (default `ServerStandard`).
- The server is not a domain controller.

## Procedure

1. For a clone that is not in the domain, run:

   ```shell
   ansible-playbook playbooks/windows-edition.yml -e target=<fqdn> -e bootstrap_address=<DHCP address>
   ```

2. For a domain member, run `kinit -f Administrator@LINDS.COM.AU`, then:

   ```shell
   ansible-playbook playbooks/windows-edition.yml -e target=<fqdn>
   ```

3. Type the product key at the prompt.

**NOTE:** Ansible keeps the key in memory for this run only. It is not in a
file, a log or the shell history. Do not give it with `-e`: the shell history
and the process list then show it.

## What it changes

- The edition of the server. The server restarts.
- On a server that already has the full edition, nothing.

## Next step

`playbooks/windows-join.md`.
