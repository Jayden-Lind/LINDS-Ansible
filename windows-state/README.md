# State of the Windows domain

Written by `playbooks/windows-capture.yml` and
`playbooks/windows-ca-backup.yml`. Do not edit by hand: capture again and read
the diff.

| Folder | What |
| --- | --- |
| `domain/` | The domain, sites, OUs with their GPO links, groups, users, computers, service accounts, who is privileged, delegation |
| `gpo/` | Every Group Policy object: `report.xml` (settings), `gpo.yml` (status, permissions), `backup/` (restorable with `Import-GPO`) |
| `dns/` | Zones and the records somebody created |
| `ca/` | The CA's settings, certificate templates and trust stores; `backup/` holds the CA key and database |
| `hosts/` | Per server: features, shares and permissions, services, scheduled tasks, software, security settings |

## What is encrypted

This repository is public. Files that name people, say who holds which rights
or show what is weak or switched off are encrypted with the Ansible vault;
the structure of the domain is plain text. The list is `SENSITIVE` in
`scripts/windows_state.py` and is mirrored in `.gitattributes` here.

To read an encrypted file: `ansible-vault view <file>`.

To make `git diff` and `git log -p` show them in the clear on your machine,
once per clone:

    git config diff.ansible-vault.textconv "ansible-vault view"

To get a readable copy of everything, for example to restore a GPO with
`Import-GPO -Path <copy>/gpo/<name>/backup`:

    .venv/bin/python scripts/windows_state.py decrypt-tree /dev/shm/windows-state windows-state vault_password

An encrypted file is only rewritten when its content changes, so a capture of
an unchanged domain still leaves `git status` clean.

Everything encrypted here, the CA's private key included, is exactly as safe
as the vault password.
