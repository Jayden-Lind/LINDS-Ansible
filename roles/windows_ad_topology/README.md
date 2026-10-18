# windows_ad_topology

The role makes the AD sites, subnets and site link, and the `_msdcs` DNS
delegation, agree with the inventory.

## What it does

1. It makes each site in `ad_sites`.
2. It moves each domain controller to the site in its host variable `ad_site`.
3. It makes each subnet in `ad_subnets` and gives it its site.
4. It sets the sites, the cost and the replication interval of the site link.
   The site link contains only the sites in the list.
5. It adds every domain controller to the `_msdcs` delegation in the DNS zone
   of the forest.

## Requirements

- A Kerberos ticket (`kinit -f Administrator@LINDS.COM.AU`).

## Variables

Set them in `inventory/group_vars/windows/topology.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `ad_sites` | `[]` | The site names. |
| `ad_subnets` | `[]` | `{name: <CIDR>, site: <site>, description: <text>}` for each subnet. |
| `ad_site_link` | `{}` | `{name, cost, replication_frequency_minutes, sites}`. Empty: the role does not change the site link. |
| `ad_site` | none | Host variable: the site of a domain controller. |

## How to use it

`playbooks/windows.yml` applies it (tag `topology`).

## Known problems

- Without correct subnets, clients do not find the nearest domain controller.
  They then log on across the tunnel. Give each client network a subnet.
- The retirement of a domain controller removes its NS records, also from the
  `_msdcs` delegation. Step 5 puts the delegation back.
