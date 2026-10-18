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
3. In LINDS-Ansible, prepare the clone. It takes about one hour:

   ```shell
   ansible-playbook playbooks/windows-prepare.yml -e target=<fqdn> -e bootstrap_address=<address>
   ```

4. Convert the edition. The playbook asks for the product key:

   ```shell
   ansible-playbook playbooks/windows-edition.yml -e target=<fqdn> -e bootstrap_address=<address>
   ```

5. Get a Kerberos ticket: `kinit -f Administrator@LINDS.COM.AU`.
6. Join the clone to the domain:

   ```shell
   ansible-playbook playbooks/windows-join.yml -e target=<fqdn> -e bootstrap_address=<address>
   ```

7. For a file server with a data disk, attach the disk:

   ```shell
   ansible-playbook playbooks/windows-data-disk.yml -e target=<fqdn>
   ```

8. Promote the server:

   ```shell
   ansible-playbook playbooks/windows-promote.yml -e target=<fqdn>
   ```

9. Apply the settings of the domain: `ansible-playbook playbooks/windows.yml`.
10. Record the state, and commit `windows-state/`. For the CA, also back it up:

    ```shell
    ansible-playbook playbooks/windows-capture.yml
    ansible-playbook playbooks/windows-ca-backup.yml
    ```

Steps 3 and 4 do not change the domain. If the new server replaces an old one
with the same name, do them while the old server is in service. Then follow
[runbooks/replace-a-domain-controller.md](runbooks/replace-a-domain-controller.md).

## Test a change

To test a change to the build, use a test identity: a second inventory file
with another name and address for the same VM. Give it with
`-i inventory/ -i <file>`. Remove it after the test with
`playbooks/windows-retire.yml`.

To test the CA or a new forest, use a separate test forest. See
[windows-forest.md](../../playbooks/windows-forest.md).

## Known problems

- After the promotion, the local Administrator does not exist. You cannot run
  `windows-prepare.yml`, `windows-edition.yml` with `bootstrap_address`, or
  `windows-join.yml` against a domain controller.
- Setup adds a recovery partition after `C:` unless the template moves it.
  The template does this (`os-partition-last.ps1`).
