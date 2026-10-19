# windows-nas-access.yml

The playbook shows what each enabled domain account can do in each top folder
of the `NAS` share, on each file server. It reads only.

For each account, Windows makes a token with the real group memberships of the
account, without its password. The playbook then asks Windows for the rights
that the share and the folder give to that token. The effective right is the
smaller of the two.

## Before you start

- Run `kinit -f Administrator@LINDS.COM.AU`.

## Procedure

1. Run `ansible-playbook playbooks/windows-nas-access.yml`.
2. Compare the table of each server with the model in
   `inventory/host_vars/jd-fs-01.linds.com.au/fileserver.yml`.

To check one server, add `--limit <fqdn>`.

## How to read the table

| Value | The account can |
| --- | --- |
| `none` | Not open the folder. |
| `read` | List the folder and read the files. |
| `write` | Also add files, but not delete them. |
| `modify` | Also change and delete files. |
| `full` | Also change the permissions and the owner. |

Administrators have `full` on all folders.

**NOTE:** The table shows the top folder only. A folder below it can give more
or less. The role `windows_fileserver` removes the broad entries below the top
folders, but it keeps the entries for one person.
