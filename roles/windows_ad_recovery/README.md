# windows_ad_recovery

The role turns on the AD Recycle Bin and puts the FSMO roles on the domain
controllers that the inventory names.

## What it does

1. It turns on the AD Recycle Bin for the forest, if it is off.
2. For each FSMO role in `fsmo_placement`, it moves the role to the named
   domain controller if another domain controller has it. It moves one role at
   a time.

## Requirements

- A Kerberos ticket (`make kinit`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `fsmo_placement` | `{}` | FSMO role name to domain controller FQDN. Set in `inventory/group_vars/windows/topology.yml`. |
| `enable_ad_recycle_bin` | `true` | Turn on the AD Recycle Bin. |

## How to use it

`make windows` applies it (tag `recovery`).

## Safety

**CAUTION:** You cannot turn the AD Recycle Bin off again.

**NOTE:** The role moves a role only while both domain controllers are online.
To take a role from a domain controller that is lost, seize it by hand
(`Move-ADDirectoryServerOperationMasterRole -Force`).
