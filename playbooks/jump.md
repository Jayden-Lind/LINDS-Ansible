# jump.yml

The playbook hardens the jump host `jd-jump-01` and removes the packages
that a VM does not use. It applies three parts of the role `common`: the
hardening, the trim and the kernel command line. It does not apply the other
parts of the role.

## Before you start

- Run the commands from the repository root, on `jd-jump-01`. The inventory
  uses a local connection, and the playbook stops on a different host.
- Your user needs `sudo` without a password.

## Procedure

**NOTE:** Merging to `main` applies this playbook to the jump host. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/jump.yml --check --diff`.
2. Run `ansible-playbook playbooks/jump.yml`.
3. To apply one part, add `--tags hardening`, `--tags trim` or
   `--tags kernel-cmdline`.

## What it changes

- The group `jump` in `inventory/jump.yml`: `jd-jump-01`.
- `inventory/host_vars/jd-jump-01/common.yml` keeps the tools (`git`, the
  manual pages), because the host is for interactive work.
- See "Hardening" and "Trim" in
  [roles/common/README.md](../roles/common/README.md).

## Safety

**CAUTION:** After the playbook, SSH logins to the jump host use a key only,
and the password of `jayden` is locked. Make sure that your key is in
`/home/jayden/.ssh/authorized_keys` before you run it.

**NOTE:** The kernel command line has `mitigations=off`
(`common_disable_mitigations`), as the other VMs have. It applies at the next
restart of the host.

**NOTE:** The playbook does not restart the host or the Claude Code service.
The memory that `kdump-tools` kept (512 MB) is free after the next restart of
the host.
