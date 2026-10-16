# windows-ca.yml

The playbook installs the certification authority on one server. If
`windows-state/ca/backup` has a backup, it restores the CA from it. If not, it
makes a new CA.

## Before you start

- Run `make kinit`.
- The server is in the group `windows_ca`.
- No other server has the CA.

## Procedure

1. Run `make windows-ca HOST=<fqdn>`.

**NOTE:** `make windows-promote` does this for a server in `windows_ca`. Use
this playbook to run the step alone.

## What it changes

- The CA role and the CA on the server, and its certificate templates.

## Next step

Run `make windows-ca-backup` and commit `windows-state/ca/backup`.
