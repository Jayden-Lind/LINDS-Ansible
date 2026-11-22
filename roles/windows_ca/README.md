# windows_ca

The role installs, backs up, restores and removes an enterprise root
certification authority (CA). The domain can have more than one CA, each on
its own server.

## What it does

The role has no main task file. Use one of its task files:

| Task file | What it does |
| --- | --- |
| `install.yml` | Installs the CA role. If the state of the CA has a backup, it restores the CA from it (same name, same key, same database). If not, it makes a new CA. Then it publishes `windows_ca_templates`, waits until the CA answers (`certutil -ping`) and publishes the CRL. |
| `backup.yml` | Backs up the key (PKCS#12, with a password), the database and the registry settings to a temporary folder on the CA, and copies them to the control node. |
| `restore.yml` | Used by `install.yml`. Puts back the database and the registry settings. |
| `remove.yml` | Removes the CA and the CA role from a server, before its demotion. |

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`). The install writes
  to the configuration of the forest, so it runs as the operator.
- The backup and the restore run as `SYSTEM` (`become` with `runas`). The CA
  refuses its database to a network logon.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_ca_name` | `<first label of windows_domain>-CA` | The name of a new CA. A restored CA keeps its name. |
| `windows_ca_key_algorithm` | `RSA` | The key algorithm of a new CA: `RSA`, `ECDSA_P256`, `ECDSA_P384` or `ECDSA_P521`. |
| `windows_ca_key_length` | `2048` | The key length of a new CA. For an ECDSA key, the number in the name of the algorithm. |
| `windows_ca_hash` | `SHA256` | The hash algorithm of a new CA. |
| `windows_ca_validity_years` | `10` | The validity of a new CA certificate. |
| `windows_ca_default_templates` | `true` | `false`: a new CA starts with no templates. The role writes `C:\Windows\CAPolicy.inf` for this before the setup. |
| `windows_ca_templates` | `[]` | The templates that the CA issues. Empty: no change. Set in `host_vars`. |
| `windows_ca_state_subdir` | empty | Empty: the state of the CA is `windows-state/ca`. A name: the state is `windows-state/ca/<name>`. Give each CA after the first one a name. |
| `windows_state_dir` | `windows-state` | The state directory. |

The settings of each CA are in `inventory/host_vars/<server>/ca.yml`.

| Server | CA | Key | State |
| --- | --- | --- | --- |
| `linds-dc` | `linds-CA` | RSA 2048 | `windows-state/ca` |
| `jd-dc-01` | `linds-CA-G2` | ECDSA P-384 | `windows-state/ca/linds-CA-G2` |

## How to use it

- `playbooks/windows.yml` installs or restores the CA, and sets the
  published templates (tag `ca`).
- `playbooks/windows/ca-backup.yml` makes a backup of each CA.
- `playbooks/windows/promote.yml` installs it on a host in the group
  `windows_ca`.
- `playbooks/windows/retire.yml` makes a backup and removes it from the
  server to retire.

## Safety

**CAUTION:** Give each CA its own `windows_ca_state_subdir`. A server with
the state of a different CA restores that CA: the domain then has the same CA
on two servers.

**WARNING:** The backup holds the private key of the CA. It is in a public
repository, encrypted with the Ansible vault. A person with the vault password
can issue certificates that the whole domain trusts.

**CAUTION:** A domain controller cannot be demoted while it has the CA role.
After `remove.yml`, the old server is no longer the CA. To go back, restore
the CA.

## Known problems

- After a restore, the CA issues the default templates, because the list is in
  the directory. Set `windows_ca_templates` to keep the correct list.
- Right after the CA service starts, `certutil -crl` can fail with "RPC server
  unavailable". `install.yml` waits for `certutil -ping` first.
