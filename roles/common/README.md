# common

The `common` role applies the base settings to a Linux host: updates, the
time zone, log rotation, remote logging, the login message, the root SSH key
and the LINDS CA certificate.

## What it does

On every host:

1. Applies `robertdebock.auto_update` with `auto_update_apply_updates: true`.
2. Installs the login message from `template/motd` (`claranet.motd`).
3. Applies `robertdebock.logrotate`: daily, 7 old files, compressed.
4. Sets the time zone to `common_timezone`. The distribution keeps the clock
   in time (chrony or systemd-timesyncd).
5. Adds the key in `files/authorized_keys` to `root`.
6. Adds the LINDS CA certificate (`files/LINDS-CA.enc`, in the vault) to the
   trust store. It rebuilds the trust store only when the file changes.
7. Writes `common_rsyslog_remote_line` to `/etc/rsyslog.d/90-remote.conf`.
   If the file changes, it restarts `rsyslog`.
8. Copies `files/02-disabledns.conf` (`UseDNS no`) to
   `/etc/ssh/sshd_config.d/`. If the file changes, it restarts `sshd`.
9. On a VM with 32768 MB of memory or more, writes `common_sysctl_highmem` to
   `/etc/sysctl.d/99-common-highmem.conf`.

On RedHat-family hosts:

10. Installs EPEL, `bash-completion` and `qemu-guest-agent`, and starts the
    agent.
11. Stops and disables `firewalld`.
12. Adds `mitigations=off` to each kernel that does not have it (`grubby`).

On Debian-family hosts:

13. Starts `qemu-guest-agent`.
14. Copies `50unattended-upgrades`, `99-Phased-Updates` and `99needrestart`
    to `/etc/apt/apt.conf.d/`.
15. Sets `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`. If the line
    changes, it runs `update-grub`.
16. On Ubuntu, installs the HWE kernel package `common_ubuntu_hwe_package`.

## Requirements

- Install the Galaxy roles and collections: `make update-requirements`.
- The play uses `become: true`. Ansible logs in as your user, which needs
  `sudo` without a password.

## Variables

All variables are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `common_timezone` | `Australia/Melbourne` | The time zone. |
| `common_rsyslog_remote_line` | `*.* @(o)172.16.1.23:1514;RSYSLOG_SyslogProtocol23Format` | The rsyslog line that sends all logs to Alloy in the cluster. Empty: no file. |
| `common_enable_qemu_guest_agent` | `true` | Install (RedHat) and start `qemu-guest-agent`. |
| `common_disable_mitigations` | `true` | Add `mitigations=off` to the kernel command line. |
| `common_sysctl_enabled` | `true` | Apply the high-memory sysctl settings. |
| `common_sysctl_vm_only` | `true` | Apply those settings only on a VM. |
| `common_sysctl_highmem_threshold_mb` | `32768` | The minimum memory, in MB, for those settings. |
| `common_sysctl_highmem` | see `defaults/main.yml` | The high-memory sysctl settings. |
| `common_ubuntu_hwe_enabled` | `true` | Install the Ubuntu HWE kernel. |
| `common_ubuntu_hwe_package` | `linux-generic-hwe-{{ ansible_distribution_version }}` | The HWE kernel package. |

## How to use it

The playbooks `plex`, `torrent` and `minecraft` apply it before their own
role.

## Safety

**NOTE:** `files/50unattended-upgrades` allows updates from all origins and
sets `Automatic-Reboot "true"`. Debian-family hosts can restart after an
update.

**NOTE:** `mitigations=off` turns off the kernel protections against CPU
side-channel attacks.

## Known problems

- The login message shows the time of the last run, so its task reports
  `changed` on every run.
