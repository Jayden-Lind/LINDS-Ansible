# windows/ca-backup.yml

The playbook backs up each certification authority (CA) to the folder
`backup` in its state, encrypted with the Ansible vault.

| CA | Server | Backup |
| --- | --- | --- |
| `linds-CA` | `linds-dc` | `windows-state/ca/backup` |
| `linds-CA-G2` | `jd-dc-01` | `windows-state/ca/linds-CA-G2/backup` |

Each backup has these files:

| File | Contents | Stored |
| --- | --- | --- |
| `<CA>.p12` | The certificate and the private key | Vault |
| `<CA>-database.zip` | The issued and revoked certificates | Vault |
| `<CA>-configuration.reg` | The registry settings | Plain text |
| `password.yml` | The password of the `.p12` | Vault |

## Before you start

- Run `kinit -f Administrator@LINDS.COM.AU`.

## Procedure

1. Run `ansible-playbook playbooks/windows/ca-backup.yml`. To back up one CA
   only, add `--limit <fqdn of its server>`.
2. Make sure that the last line for each CA says that the key matches the
   certificate.
3. Commit `windows-state/ca`.

Run it after you issue or revoke an important certificate, and always before
you move the CA.

## Safety

**WARNING:** The private key of each CA is in a public repository. It is as
safe as the vault password. A person with that password can issue
certificates that the whole domain trusts.

## How to restore by hand

1. Decrypt the three vault files with `ansible-vault decrypt`.
2. Unzip the database into a folder `DataBase` beside the `.p12`.
3. On the new server, run
   `Restore-CARoleService -Path <folder> -Password <password> -Force`.
4. Import the registry settings with `reg import`.

`windows-ca.yml` does these steps for you.
