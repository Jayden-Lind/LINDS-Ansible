# common

The `common` role applies the base settings to a Linux host: updates, log
rotation, remote logging, the login message, the root SSH key and the LINDS
CA certificate.

## What it does

On every host:

1. Applies the role `robertdebock.auto_update` with
   `auto_update_apply_updates: true`.
2. Installs the login message from `template/motd` (role `claranet.motd`).
3. Applies the role `robertdebock.logrotate`. It rotates the logs daily,
   keeps 7 old files and compresses them.
4. Adds the key in `files/authorized_keys` to `root`.
5. Adds the LINDS CA certificate (`files/LINDS-CA.enc`, stored in the vault)
   to the system trust store.
6. Writes `common_rsyslog_remote_line` to `/etc/rsyslog.d/90-remote.conf`. If
   the file changes, it restarts `rsyslog`.
7. Copies `files/02-disabledns.conf` (`UseDNS no`) to
   `/etc/ssh/sshd_config.d/`. If the file changes, it restarts `sshd`.
8. On a VM with 32768 MB of memory or more, writes `common_sysctl_highmem` to
   `/etc/sysctl.d/99-common-highmem.conf`.

On RedHat-family hosts:

9. Installs EPEL (role `robertdebock.epel`), `bash-completion` and
   `qemu-guest-agent`, and starts the agent.
10. Stops and disables `firewalld`.
11. Adds `mitigations=off` to every kernel with `grubby`.

On Debian-family hosts:

12. Starts `qemu-guest-agent`.
13. Copies `50unattended-upgrades`, `99-Phased-Updates` and `99needrestart`
    to `/etc/apt/apt.conf.d/`.
14. Replaces `/etc/default/grub` and runs `update-grub`. The kernel command
    line gets `mitigations=off`.
15. On Ubuntu, installs the HWE kernel package `common_ubuntu_hwe_package`.

## Requirements

- Install the Galaxy roles and collections: `make update-requirements`.
- The `vault_password` file must be in the repository root.

## Variables

All variables are in `defaults/main.yml`. No inventory file overrides them.

| Variable | Default | Description |
| --- | --- | --- |
| `common_rsyslog_remote_line` | `*.* @(o)172.16.1.23:1514;RSYSLOG_SyslogProtocol23Format` | The rsyslog line that sends all logs to the Alloy listener in the Kubernetes cluster. If it is empty, the role writes no file. |
| `common_enable_qemu_guest_agent` | `true` | Installs (RedHat) and starts `qemu-guest-agent`. |
| `common_disable_mitigations` | `true` | Adds `mitigations=off` to the kernel command line. |
| `common_sysctl_enabled` | `true` | Applies the high-memory sysctl settings. |
| `common_sysctl_vm_only` | `true` | Applies those settings only on a VM. |
| `common_sysctl_highmem_threshold_mb` | `32768` | The minimum memory, in MB, for the high-memory settings. |
| `common_sysctl_highmem` | See `defaults/main.yml` | The high-memory sysctl settings. |
| `common_ubuntu_hwe_enabled` | `true` | Installs the Ubuntu HWE kernel. |
| `common_ubuntu_hwe_package` | `linux-generic-hwe-{{ ansible_distribution_version }}` | The HWE kernel package. |

## How to use it

`playbooks/dev.yml` applies only this role. The playbooks `backup`,
`kubernetes`, `minecraft`, `plex`, `terraform` and `torrent` apply it before
their own role. See [playbooks/dev.md](../../playbooks/dev.md).

## Safety

**CAUTION:** On Debian-family hosts, the role replaces all of
`/etc/default/grub`. A setting that you add to that file by hand is lost at
the next run.

**NOTE:** `files/50unattended-upgrades` allows updates from all origins and
sets `Automatic-Reboot "true"`. Debian-family hosts can reboot after an
update.

**NOTE:** `mitigations=off` turns off the kernel protections against CPU
side-channel attacks.

## Known problems

- `tasks/common.yml` and `tasks/debian.yml` are not used, because
  `tasks/main.yml` does not import them. Only these files set NTP and the time
  zone, so the role does not set them.
- The role reports `changed` on every run, because `update-grub` and `grubby`
  always run.
