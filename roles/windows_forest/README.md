# windows_forest

The role makes a new server the first domain controller of a new forest.

## What it does

1. It stops if `windows_forest_domain` is empty.
2. It stops if a domain with that name already answers in DNS.
3. It installs AD DS, DNS and the management tools.
4. It makes the forest, and the server restarts as its first domain
   controller.
5. It waits until the directory is available and sets the DNS forwarders.

## Requirements

- A new server with its name and address, not in a domain
  (`windows-prepare.yml`, then the name and address step of
  `windows-join.yml`).
- A connection as the local Administrator.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_forest_domain` | `""` | The DNS name of the new domain. You must give it. |
| `windows_forest_netbios` | first label, in capitals | The NetBIOS name. |
| `windows_dsrm_password` | from the environment or the vault | The restore-mode password. |
| `windows_forest_dns_forwarders` | `windows_dc_dns_forwarders` | The DNS forwarders. |

## How to use it

```shell
ansible-playbook -i <inventory> playbooks/windows-forest.yml \
    -e target=<fqdn> -e windows_forest_domain=<domain>
```

## Safety

**WARNING:** Do not use the name of a domain that exists. The machines that
join cannot tell two forests with the same name apart.

**NOTE:** After the forest is made, the local Administrator is the
Administrator of the new domain, with the same password.
