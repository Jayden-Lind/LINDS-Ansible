# windows-capture.yml

The playbook reads the domain and writes it to `windows-state/` as files that
you can compare. It changes nothing on the servers.

| Folder | Contents |
| --- | --- |
| `domain/` | Domain, sites, OUs and GPO links, groups, users, computers, privileged membership, delegation |
| `gpo/` | A report and a backup of each GPO |
| `dns/` | Zones and the records that a person made |
| `ca/` | CA settings, templates, trust stores, and the CA backup |
| `hosts/<server>/` | Features, shares, NFS exports, services, tasks, software, security settings |

## Before you start

- Run `kinit -f Administrator@LINDS.COM.AU`.

## Procedure

1. Run `ansible-playbook playbooks/windows-capture.yml`. It takes about five
   minutes.
2. Run `git diff -- windows-state`. The diff shows what changed in the domain
   since the last capture.
3. Commit the result.

## Safety

**CAUTION:** The repository is public. The files that name people, show who
has rights, or show a weakness are encrypted with the vault. The list is
`SENSITIVE` in `scripts/windows_state.py`. Read an encrypted file with
`ansible-vault view <file>`.

**NOTE:** On GitHub the diff of an encrypted file is not readable. To read it
locally, run `git config diff.ansible-vault.textconv "ansible-vault view"`
one time.
