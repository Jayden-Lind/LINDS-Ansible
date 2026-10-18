# windows-data-disk.yml

The playbook attaches the data disks of a server to its VM, on the Proxmox
host. Use it when a file server gets a new VM.

## Before you start

- The host has `windows_vm` with `data_disks` in `inventory/windows.yml`.
- You can connect to the Proxmox host as `root` with SSH.
- The other VMs that have the disk are stopped.

## Procedure

1. Run `ansible-playbook playbooks/windows-data-disk.yml -e target=<fqdn>`.

**WARNING:** Two machines that write to one NTFS volume destroy it. The
playbook refuses if a VM in `never_running_with` runs. Do not start such a VM
by hand while the server runs.

## What it changes

- The VMs in `never_running_with` do not start with the host.
- The VM that owns the volume gets protection.
- The disk is attached to the VM of the server.

## Next step

`windows-promote.yml` brings the volume online in Windows.
