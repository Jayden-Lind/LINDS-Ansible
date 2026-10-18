# windows_edition

The role stops an Evaluation installation before its promotion, and converts
it to the full edition if you give a product key.

## What it does

1. It reads the edition.
2. If the edition is Evaluation and there is no product key, it stops,
   unless `windows_edition_allow_evaluation` is true.
3. It refuses to convert a domain controller.
4. It converts the edition with `dism /online /set-edition`, restarts, and
   confirms the new edition.

## Requirements

- For a conversion: a product key for the target edition.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `windows_edition_target` | `ServerStandard` | The edition: `ServerStandard` or `ServerDatacenter`. |
| `windows_product_key` | `""` | The product key. `playbooks/windows-edition.yml` asks for it. |
| `windows_edition_allow_evaluation` | `false` | `true`: let an Evaluation installation continue (test servers only). |

## How to use it

- `playbooks/windows-edition.yml` converts a clone or a domain member. See
  `playbooks/windows-edition.md`.
- `playbooks/windows-promote.yml` runs the check first.

## Safety

**CAUTION:** You cannot convert a domain controller. Convert the edition
before the promotion.

**NOTE:** Ansible does not keep the product key. The make target gives it in
the environment of one run.

**NOTE:** An Evaluation installation stops working 180 days after the
installation.
