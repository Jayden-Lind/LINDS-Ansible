# windows-edition.yml

The playbook converts an Evaluation installation to the full edition with a
product key that you type.

## Before you start

- You have a product key for the edition in `windows_edition_target`
  (default `ServerStandard`).
- The server is not a domain controller.

## Procedure

1. For a clone that is not in the domain, run
   `make windows-edition HOST=<fqdn> ADDRESS=<DHCP address>`.
2. For a domain member, run `make kinit`, then
   `make windows-edition HOST=<fqdn>`.
3. Type the product key at the prompt.

**NOTE:** The key goes to Ansible in the environment of this run only. It is
not in a file, a log or the shell history.

## What it changes

- The edition of the server. The server restarts.
- On a server that already has the full edition, nothing.

## Next step

`playbooks/windows-join.md`.
