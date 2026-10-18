# windows_capture

The role reads the domain, Group Policy, DNS, the CA and each server. The
playbook then writes the result to `windows-state/` as files that you can
compare with `git diff`.

## What it does

The role has no main task file. Use one of its task files:

| Task file | Runs on | What it reads |
| --- | --- | --- |
| `domain.yml` | the first domain controller | The domain, sites, OUs and GPO links, groups, users, computers, service accounts, privileged membership, delegation, DNS zones and records, and a report and backup of each GPO. |
| `host.yml` | each Windows server | Features, shares and their permissions, NFS exports, services, scheduled tasks, software and security settings. |
| `ca.yml` | the CA | The CA settings, the certificate templates and the trust stores. |

The scripts are in `files/`. `scripts/windows_state.py` writes the files.

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_capture_work` | `""` | The work directory on the control node. The playbook sets it. |

## How to use it

`ansible-playbook playbooks/windows-capture.yml`, then
`git diff -- windows-state`.

## Safety

**NOTE:** The role changes nothing on the servers. The GPO task writes a zip
file to the temporary folder of the domain controller, copies it, and removes
it.

**CAUTION:** The repository is public. `scripts/windows_state.py` encrypts the
sensitive files with the vault (list `SENSITIVE`). If you capture something
new that names people or shows a weakness, add it to that list.
