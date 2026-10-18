# windows-promote.yml

The playbook makes a domain member what its inventory groups say:

| Group | What the server becomes |
| --- | --- |
| `windows_dc` | A domain controller with DNS and the global catalog |
| `windows_ca` | The certification authority, restored from its backup if there is one |
| `windows_fileserver` | A file server: volumes, shares, NFS exports, shadow copies |

A server can be in more than one group.

## Before you start

- `windows-join.yml` is complete.
- Run `make kinit`.
- For a file server with a data disk: `make windows-data-disk HOST=<fqdn>`.
- For the CA: `windows-state/ca/backup` has a current backup.

## Procedure

1. Run `make windows-promote HOST=<fqdn>`.
2. At the prompt, type a restore-mode password, or press Enter to use the one
   in the vault.
3. After it is complete, run `make windows` to apply the domain settings (for
   example, replication).

## What it changes

1. It stops if the server is an Evaluation installation.
2. It applies the baseline.
3. For `windows_dc`:
   - It promotes the server.
   - It makes the server known to every domain controller.
   - It waits for the RID pool and runs `dcdiag`.
   - It gets the LDAPS certificate.
   - It applies Group Policy. The GPOs on `Domain Controllers` set its time
     source.
4. For `windows_ca`: it installs or restores the CA.
5. For `windows_fileserver`: it brings the data volumes online and makes the
   shares and NFS exports.
6. It releases the preferred bridgehead that a retirement with
   `REPLACING=true` left.

A promotion takes 11 to 17 minutes. With the CA and a file server, about one
hour.

## If it fails

- Run the same command again. Each step does nothing if it is complete.
- "credentials were rejected" after the restart: run `make kinit`, then run
  the command again.

## Next step

Run `make windows`. Then `make windows-ca-backup` and `make windows-capture`,
and commit `windows-state/`.
