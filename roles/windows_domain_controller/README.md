# windows_domain_controller

The role promotes a domain member to an additional domain controller with DNS
and the global catalog.

## What it does

`main.yml`:

1. It installs AD DS, DNS and the management tools, and restarts if needed.
2. If the server is not a domain controller, it promotes it in its site
   (`ad_site`) with the restore-mode password, and restarts it.
3. It waits until the directory and SYSVOL are available.
4. It sets the DNS forwarders.
5. It sets the resolvers of the server: another domain controller first,
   then itself.

`finish.yml`, after the other domain controllers know the new one:

1. It waits for the RID pool.
2. It runs `dcdiag`.
3. It gets the LDAPS certificate (`ldaps.yml`), if the server is not the CA.
4. It closes the WinRM firewall rule that the template opened for the first
   connection.

`ldaps.yml` enrols the domain controller certificates and waits until LDAPS
answers with a certificate from the domain CA.

## Requirements

- The server is a domain member with the full edition (not Evaluation).
- A Kerberos ticket with delegation (`make kinit`).
- The restore-mode password: typed at `make windows-promote`, or
  `vault_windows_dsrm_password` in the vault.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_dc_site` | `ad_site` | The AD site. |
| `windows_dsrm_password` | from the environment or the vault | The restore-mode password. |
| `windows_dc_dns_forwarders` | `[]` | The DNS forwarders. The inventory sets them. |
| `windows_dc_dns_client_servers` | `windows_dns_servers` + `127.0.0.1` | The resolvers of the server. |
| `windows_dc_ready_timeout` | `1800` | Seconds to wait for the directory and SYSVOL. |
| `windows_dc_rid_pool_timeout` | `900` | Seconds to wait for the RID pool. |
| `windows_dc_require_ldaps` | `true` | Wait for LDAPS. Set `false` in a domain without an enterprise CA. |
| `windows_dc_ldaps_timeout` | `600` | Seconds to wait for LDAPS. |

## How to use it

`make windows-promote HOST=<fqdn>`, for a host in the group `windows_dc`.

## Known problems

- A domain controller certificate has an empty subject. Its names are in the
  subject alternative name. The LDAPS check does not look at the subject.
- A ticket that a domain controller issued with the old password of the
  server works on a member, but not on a domain controller. `windows-join.yml`
  renews the ticket of the operator for this reason.
