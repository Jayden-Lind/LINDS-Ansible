# Build a server from the template

Three tools build a server:

| Step | Tool | Where |
| --- | --- | --- |
| Install Windows, the VirtIO drivers and the guest agent, then make the template | Packer | `LINDS-Terraform/packer/windows/` |
| Clone the template to a VM | Terraform | `LINDS-Terraform/proxmox/vms-*.tf` |
| Name, address, baseline, updates, domain join, edition, promotion | Ansible | the playbooks below |

## Before you start

- Add the host to `inventory/windows.yml` with `windows_hostname`,
  `windows_ipv4_address`, `windows_ipv4_prefix`, `windows_ipv4_gateway`,
  `windows_dns_servers` and `ad_site`. Put it in the groups that it needs
  (`windows_dc`, `windows_ca`, `windows_fileserver`). Use `linds-dc2` as an
  example.
- Have a product key for the full edition. The template is an Evaluation
  installation.

## Procedure

1. In `LINDS-Terraform/proxmox`, make the VM with a targeted apply:
   `terraform apply -target=proxmox_virtual_environment_vm.<name>`.

   **WARNING:** Never run `terraform apply` without `-target` there.

2. Find the DHCP address of the clone: `terraform output windows_bootstrap_addresses`.
3. Run `make windows-prepare HOST=<fqdn> ADDRESS=<address>`. About one hour.
4. Run `make windows-edition HOST=<fqdn> ADDRESS=<address>`, and type the key.
5. Run `make kinit`.
6. Run `make windows-join HOST=<fqdn> ADDRESS=<address>`.
7. For a file server with a data disk, run `make windows-data-disk HOST=<fqdn>`.
8. Run `make windows-promote HOST=<fqdn>`.
9. Run `make windows`.
10. Run `make windows-capture` (and `make windows-ca-backup` for the CA), and
    commit `windows-state/`.

Steps 3 and 4 do not change the domain. If the new server replaces an old one
with the same name, do them while the old server is in service. Then follow
[runbooks/replace-a-domain-controller.md](runbooks/replace-a-domain-controller.md).

## Test a change

To test a change to the build, use a test identity: a second inventory file
with another name and address for the same VM. Give it with
`-i inventory/ -i <file>`. Remove it after the test with
`make windows-retire-dc`.

To test the CA or a new forest, use a separate test forest. See
[windows-forest.md](../../playbooks/windows-forest.md).

## Known problems

- After the promotion, the local Administrator does not exist. You cannot run
  `windows-prepare.yml`, `windows-edition.yml` with `ADDRESS`, or
  `windows-join.yml` against a domain controller.
- Setup adds a recovery partition after `C:` unless the template moves it.
  The template does this (`os-partition-last.ps1`).
