# windows_directory

The role makes the directory agree with the inventory: OUs, groups, users,
group membership, GPO links and the password policy.

## What it does

1. It makes each OU in `windows_directory_ous`.
2. It makes each group in `windows_directory_groups`.
3. It makes each user in `windows_directory_users`. A new user gets the
   password in `windows_directory_initial_passwords`, if there is one.
4. It makes the members of each group in `windows_directory_members` exact.
5. It makes the members of each group in `windows_directory_privileged` exact.
6. `tasks/links.yml` makes the GPO links of each container in
   `windows_directory_gpo_links` exact, in the given order. It removes a link
   that is not in the list. `playbooks/windows.yml` runs it after the role
   `windows_gpo`, because a GPO can name a group that this role makes.
7. It sets the password policy and the machine account quota, if they are set.
8. It lists the OUs, groups and users that exist but are not in the files.

## Requirements

- A Kerberos ticket with delegation (`kinit -f Administrator@LINDS.COM.AU`). The
  GPO cmdlets need it.

## Variables

Set them in `inventory/group_vars/windows/directory.yml` (OUs, GPO links,
groups) and `directory.vault.yml` (users, members, privileged groups, password
policy). Edit the vault file with `ansible-vault edit`.

| Variable | Default | Description |
| --- | --- | --- |
| `windows_directory_ous` | `[]` | The OUs. |
| `windows_directory_groups` | `[]` | The groups that this repository owns. |
| `windows_directory_users` | `[]` | The users. |
| `windows_directory_members` | `{}` | Group to members, exact. |
| `windows_directory_privileged` | `{}` | Privileged group to members, exact. |
| `windows_directory_gpo_links` | `{}` | Container to GPO names, in order. |
| `windows_directory_initial_passwords` | `{}` | User to first password. Used only for a new user. |
| `windows_directory_password_policy` | not set | The default password policy of the domain. |
| `windows_directory_machine_account_quota` | not set | `ms-DS-MachineAccountQuota`. |

## How to use it

1. Edit the files.
2. Run `ansible-playbook playbooks/windows.yml --tags directory --check --diff`
   to see the changes.
3. Run `ansible-playbook playbooks/windows.yml --tags directory`.

To add a person to a group, add the name under the group in
`windows_directory_members`.

## Safety

**WARNING:** Membership is exact for the listed groups. The next run removes a
member that someone added in a console. List a group in
`windows_directory_privileged` only if every member is in the file.

**NOTE:** The role does not delete an OU, group or user that is not in the
files. It lists them under "not in the code".

**NOTE:** The role does not change the password of a user that exists.

**NOTE:** The role does not change the GPOs. The role `windows_gpo` makes the
GPOs that the code owns. Edit the other GPOs in GPMC.
`ansible-playbook playbooks/windows-capture.yml` keeps a backup of each GPO.

## Known problems

- In check mode, the role cannot show the members of a group or user that the
  same run makes. Those show as ignored errors.
- In check mode, the role cannot link a GPO that the same run makes. That
  shows as an ignored error.
- Do not run `scripts/windows_directory_export.py` again. It writes over the
  files with the state of the domain at that time.
