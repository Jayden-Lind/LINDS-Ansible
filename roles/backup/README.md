# backup

The `backup` role adds weekly cron jobs that back up routers, TrueNAS hosts
and a switch, and copy the backup files to an SMB share.

## What it does

1. Installs `git`.
2. Loads `vars/backup.yml` into the variable `backup_var`.
3. Adds a `root` cron job for each host of each entry in `backups`. The job
   runs on Monday at 00:00:
   `cd /root/<dest_folder> && python3 <file> <host> <user name> <password>`.
4. Adds a cron job for each entry. On Monday at 02:00, it copies the entry's
   backup files from `/root/<dest_folder>` to `/mnt/nas`.
5. Clones the repository of each entry into `root_path`.
6. Mounts the SMB share `//jd-dc-01/nas/server/backup` at `/mnt/nas` with
   autofs (role `robertdebock.autofs`).

The entries in `vars/backup.yml`:

| Entry | Repository (github.com/Jayden-Lind) | Script | Hosts | Files |
| --- | --- | --- | --- | --- |
| `opnsense` | `OPNSense-Backup` | `backup.py` | `10.0.50.1`, `192.168.6.1` | `*.xml` |
| `truenas` | `TrueNAS-backup-API` | `api.py` | `linds-truenas-01.linds.com.au`, `jd-truenas-01.linds.com.au` | `*.db` |
| `hpe_switch` | `HPE-OfficeConnect-Backup` | `backup.py` | `10.0.0.2` | `*.stk` |

## Requirements

- Install the Galaxy roles: `make update-requirements`.
- The `vault_password` file must be in the repository root.

## Variables

The variables are in `vars/backup.yml`, under `backup_var`. Change them in
that file. The inventory cannot override them.

| Variable | Default | Description |
| --- | --- | --- |
| `root_path` | `/root/` | The directory for the cloned repositories. |
| `smb_username` | Stored in the vault | The user for the SMB share. |
| `smb_password` | Stored in the vault | The password for the SMB share. |
| `smb_domain` | `linds.com.au` | The domain for the SMB share. |
| `backups` | The three entries above | For each entry: `path` (repository URL), `hosts` (with a user name and password from the vault), `dest_folder`, `file` and `backup_file_extenion`. |

## How to use it

`playbooks/backup.yml` applies `common` and then this role to the group
`backup` (`jd-backup-01.linds.com.au`). See
[playbooks/backup.md](../../playbooks/backup.md).

## Safety

**CAUTION:** The cron jobs put the user names and passwords from the vault on
the command line. A user who can read the root crontab or the process list
can see them.

## Known problems

- The `opnsense` entry backs up `10.0.50.1` and `192.168.6.1`. In this
  inventory, `10.0.50.1` is `jd-router-01` (Debian) and `192.168.6.1` is a
  VyOS router. Not known if the OPNsense script works on them.
- The key `backup_file_extenion` has this spelling in the code. Use the same
  spelling if you add an entry.
