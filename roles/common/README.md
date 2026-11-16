# common

The `common` role applies the base settings to a Linux host: updates, the
time zone, log rotation, remote logging, the login message, the root SSH key
and the LINDS CA certificate. It also hardens the host and removes the
packages and services that a VM does not use.

## What it does

The role is for Debian and Ubuntu hosts. It does the trim first, then the
hardening, then the steps below. The removal of a package also removes its
configuration files, and the steps below install one of those files.

1. Installs `unattended-upgrades` and `apt-listchanges`, and copies
   `files/10periodic` to `/etc/apt/apt.conf.d/`: the package lists update
   and the updates install every day. It keeps `apt-daily.timer` and
   `apt-daily-upgrade.timer` on.
2. Installs the login message `files/dynmotd` to `/usr/local/bin/dynmotd`.
   PAM runs it at each login (`/etc/pam.d/login` and `/etc/pam.d/sshd`).
   It comments out `pam_motd` and sets `PrintMotd no` in sshd.
3. Copies `files/logrotate.conf` to `/etc/logrotate.conf` (daily, 7 old
   files, compressed, with the date) and keeps `logrotate.timer` on.
4. Sets the time zone to `common_timezone`. The distribution keeps the clock
   in time (chrony or systemd-timesyncd).
5. Adds the key in `files/authorized_keys` to `root`.
6. Adds the LINDS CA certificate (`files/LINDS-CA.enc`, in the vault) to the
   trust store. It rebuilds the trust store only when the file changes.
7. Installs `rsyslog` and writes `common_rsyslog_remote_line` to
   `/etc/rsyslog.d/90-remote.conf`.
   If the file changes, it restarts `rsyslog`.
8. Copies `files/02-disabledns.conf` (`UseDNS no`) to
   `/etc/ssh/sshd_config.d/`. If the file changes, it restarts `sshd`.
9. On a VM with 32768 MB of memory or more, writes `common_sysctl_highmem` to
   `/etc/sysctl.d/99-common-highmem.conf`.
10. Starts `qemu-guest-agent`.
11. Copies `50unattended-upgrades`, `99-Phased-Updates` and `99needrestart`
    to `/etc/apt/apt.conf.d/`.
12. Sets `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`. If the line
    changes, it runs `update-grub`.
13. If `/etc/logrotate.d/cloud-init-base` exists, removes
    `/etc/logrotate.d/cloud-init`. The old file names the same log, and
    logrotate stops with an error.

### Hardening

The tasks are in `tasks/hardening.yml` and have the tag `hardening`.

1. Copies `files/01-hardening.conf` to `/etc/ssh/sshd_config.d/`: SSH logins
   use a key only, `root` included, and X11 forwarding is off. If the file
   changes, it restarts `ssh`.
2. Locks the password of each account in `common_password_locked_users`. The
   account keeps its SSH keys.
3. Removes each account in `common_absent_users`, with its home directory and
   its sudo rule.
4. Copies `files/90-common-hardening.conf` to `/etc/sysctl.d/`: no core
   files, hidden kernel addresses, no `kexec`, no ICMP redirects.
5. Copies `files/common-hardening-modules.conf` to `/etc/modprobe.d/`. The
   kernel does not load the network protocols and file systems in the file.

### Trim

The tasks are in `tasks/trim.yml` and have the tag `trim`.

1. If the host runs `ntpsec`, installs `chrony`. `chrony` sets the clock and
   does not answer NTP requests.
2. Removes the packages in `common_packages_absent`, with their
   configuration. A host keeps the packages in `common_packages_keep`.
3. On an Ubuntu VM, installs `common_ubuntu_vm_kernel_package` and removes
   `common_ubuntu_hardware_kernel_packages`. The kernel is the same HWE
   kernel. The firmware, the microcode and the kernel headers go.
4. Removes the packages that no other package needs (`apt autoremove`).
5. Stops and masks the units in `common_units_masked`.
6. If `common_cloud_init_disabled` is true, makes
   `/etc/cloud/cloud-init.disabled`. cloud-init does not run at the next
   start.
7. If the removal changed the kernel command line, runs `update-grub`.

The packages in `common_packages_absent` are in these groups:

| Group | Packages | Why |
| --- | --- | --- |
| Hardware services | `modemmanager`, `usbmuxd`, `bolt`, `upower`, `udisks2`, `fwupd`, `thermald`, `ubuntu-drivers-common`, `open-vm-tools` | A Proxmox VM has no modem, Thunderbolt port, battery or firmware to update. |
| Storage | `multipath-tools`, `open-iscsi`, `mdadm`, `bcache-tools`, `btrfs-progs`, `xfsprogs`, `ntfs-3g` | The hosts have one virtual disk with LVM and ext4. |
| snap and LXD | `snapd`, `lxd-installer`, `lxd-agent-loader` | No host uses a snap, but for the jump host. |
| Crash reports | `apport`, `kdump-tools`, `kexec-tools`, `makedumpfile` | `kdump-tools` keeps 512 MB of memory for a second kernel. |
| Data collection | `sysstat`, `landscape-common`, `motd-news-config`, `update-notifier-common`, `sos`, `packagekit`, `networkd-dispatcher` | Timers and services whose output nobody reads. |
| Clients | `telnet` | Not used. |
| Trace tools | `bpftrace`, `bpfcc-tools`, `trace-cmd` | Not used. With their libraries they are about 200 MB. |
| NTP servers | `ntpsec`, `ntp` | `chrony` keeps the time. |

## Requirements

- Install the collections: `ansible-galaxy collection install -r requirements.yml`.
- The play uses `become: true`. Ansible logs in as your user, which needs
  `sudo` without a password.

## Variables

All variables are in `defaults/main.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `common_timezone` | `Australia/Melbourne` | The time zone. |
| `common_rsyslog_remote_line` | `*.* @(o)172.16.1.23:1514;RSYSLOG_SyslogProtocol23Format` | The rsyslog line that sends all logs to Alloy in the cluster. Empty: no file. |
| `common_enable_qemu_guest_agent` | `true` | Start `qemu-guest-agent`. |
| `common_disable_mitigations` | `true` | Add `mitigations=off` to the kernel command line. |
| `common_sysctl_enabled` | `true` | Apply the high-memory sysctl settings. |
| `common_sysctl_vm_only` | `true` | Apply those settings only on a VM. |
| `common_sysctl_highmem_threshold_mb` | `32768` | The minimum memory, in MB, for those settings. |
| `common_sysctl_highmem` | see `defaults/main.yml` | The high-memory sysctl settings. |
| `common_ubuntu_vm_kernel` | `true` | On an Ubuntu VM, use the kernel package for a VM. |
| `common_ubuntu_vm_kernel_package` | `linux-image-virtual-hwe-<version>` | The HWE kernel package for the Ubuntu version of the host, without firmware. |
| `common_ubuntu_hardware_kernel_packages` | see `defaults/main.yml` | The kernel packages that only hardware needs. |
| `common_password_locked_users` | `[jayden]` | The accounts with a locked password. |
| `common_absent_users` | `[ubuntu]` | The accounts that the role removes. |
| `common_packages_absent` | see `defaults/main.yml` | The packages that the role removes. |
| `common_packages_keep` | `[]` | The packages of `common_packages_absent` that this host keeps. |
| `common_units_masked` | see `defaults/main.yml` | The units that the role stops and masks. |
| `common_cloud_init_disabled` | `true` | Stop cloud-init after the first start of the host. |

## How to use it

`playbooks/media.yml` applies it before the roles `plex` and `torrent`.

To apply only the hardening or only the trim, add `--tags hardening` or
`--tags trim`.

To see which packages the trim removes from a host, run this command on the
host. It changes nothing.

```
sudo apt-get -s --auto-remove purge <the packages of common_packages_absent>
```

## Safety

**NOTE:** `files/50unattended-upgrades` allows updates from all origins and
sets `Automatic-Reboot "true"`. The hosts can restart after an update.

**NOTE:** `mitigations=off` turns off the kernel protections against CPU
side-channel attacks.

**CAUTION:** After the hardening, an account with a locked password cannot
log in at the Proxmox console. Use SSH with a key. If SSH does not work, use
`qm guest exec` on the Proxmox host. To give the account a password again,
remove it from `common_password_locked_users` and run `sudo passwd <account>`.

**CAUTION:** The trim also removes the packages that depend on a removed
package. On Ubuntu these are the collections `ubuntu-server` and
`ubuntu-server-minimal`, which install nothing by themselves. Before you add
a package to `common_packages_absent`, run the `apt-get -s` command above on
a host and read the list.

**NOTE:** The memory that `kdump-tools` kept, the kernel package and
`/etc/cloud/cloud-init.disabled` have an effect only after the next restart
of the host. The role does not restart the host.

**NOTE:** If a host must mount with NFS version 3, remove `rpcbind.socket`
and `rpcbind.service` from `common_units_masked` for that host.
