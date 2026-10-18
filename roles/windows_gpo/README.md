# windows_gpo

The role makes GPOs from the inventory, and keeps their contents the same as
the inventory.

## What it does

1. It makes each WMI filter in `windows_gpo_wmi_filters`, or corrects its query.
2. It makes each GPO in `windows_gpo_definitions`. Then it sets these items
   of the GPO:
   - The comment.
   - The user settings, which it turns off. The GPOs of this role have
     computer settings only.
   - The registry policy values in `policy`. For each key in the list, the role
     removes the values that are not in the list.
   - The registry preference items in `preferences`, with the action Update.
   - The computers in `apply_to`. Only these computers apply the GPO.
     Authenticated Users keep Read.
   - The WMI filter in `wmi_filter`.
3. It removes the values in `windows_gpo_remove_values` from GPOs that it does
   not own.

The role does not link the GPOs. The role `windows_directory` links them, from
`windows_directory_gpo_links`.

## Requirements

- A Kerberos ticket with delegation (`kinit -f Administrator@LINDS.COM.AU`). The
  GPO cmdlets need it.
- The computers in `apply_to` must have accounts in the domain.

## Variables

Set them in `inventory/group_vars/windows/gpo.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `windows_gpo_wmi_filters` | `[]` | `{name, description, query}` for each WMI filter. The query is WQL in `root\CIMv2`. |
| `windows_gpo_definitions` | `[]` | `{name, comment, apply_to, wmi_filter, policy, preferences}` for each GPO. |
| `windows_gpo_remove_values` | `[]` | `{gpo, key, name}` for each value to remove from a GPO that the role does not own. |

Each item in `policy` and `preferences` is `{key, name, type, value}`. The
type is `DWord` or `String`. An item with `state: absent` is removed.

The GPOs in the inventory:

| GPO | Linked to | What it sets |
| --- | --- | --- |
| `Server - Baseline` | the domain | The settings of `windows_baseline`, for the servers in the inventory group `windows_managed`. |
| `PDC Emulator - Time` | `Domain Controllers`, first | The PDC emulator gets its time from `ntp_servers`. |
| `Domain Controller - Time` | `Domain Controllers`, second | The other domain controllers get their time from the domain. |

## How to use it

`playbooks/windows.yml` applies it (tag `gpo`). Run the tag `directory` after it
when you add a GPO, because that tag makes the links:

1. Run
   `ansible-playbook playbooks/windows.yml --check --diff --tags gpo,directory`.
2. Run `ansible-playbook playbooks/windows.yml --tags gpo,directory`.
3. On a server, run `gpupdate /target:computer` to apply the change now.
   Otherwise the change comes at the next refresh, in 90 to 120 minutes.

## Safety

**CAUTION:** The role owns the GPOs in `windows_gpo_definitions`. The next run
removes a change that someone made in GPMC. Change the inventory, not the GPO.

**NOTE:** A preference item stays on a server after the GPO goes, or after the
server leaves `apply_to`. Change the setting on the server if necessary.

## Known problems

- A setting that is in an enforced GPO higher in the tree wins over these
  GPOs. The Default Domain Policy is enforced on the domain.
