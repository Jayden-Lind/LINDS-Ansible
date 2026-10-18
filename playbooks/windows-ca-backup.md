# windows-ca-backup.yml

The playbook backs up the certification authority to
`windows-state/ca/backup`, encrypted with the Ansible vault.

| File | Contents | Stored |
| --- | --- | --- |
| `<CA>.p12` | The certificate and the private key | Vault |
| `<CA>-database.zip` | The issued and revoked certificates | Vault |
| `<CA>-configuration.reg` | The registry settings | Plain text |
| `password.yml` | The password of the `.p12` | Vault |

## Before you start

- Run `kinit -f Administrator@LINDS.COM.AU`.

## Procedure

1. Run `ansible-playbook playbooks/windows-ca-backup.yml`.
2. Make sure that the last line says that the key matches the certificate.
3. Commit `windows-state/ca/backup`.

Run it after you issue or revoke an important certificate, and always before
you move the CA.

## Safety

**WARNING:** The private key of the CA is in a public repository. It is as
safe as the vault password. A person with that password can issue
certificates that the whole domain trusts.

## How to restore by hand

1. Decrypt the three vault files with `ansible-vault decrypt`.
2. Unzip the database into a folder `DataBase` beside the `.p12`.
3. On the new server, run
   `Restore-CARoleService -Path <folder> -Password <password> -Force`.
4. Import the registry settings with `reg import`.

`windows-ca.yml` does these steps for you.
