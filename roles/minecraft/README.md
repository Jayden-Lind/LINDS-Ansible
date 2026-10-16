# minecraft

The `minecraft` role prepares a RedHat-family host to start a Minecraft
server from `/root/LINDS`, and copies the server to the NAS every day.

## What it does

1. Installs `screen`, `java-latest-openjdk`, `nfs-utils`, `net-tools` and
   `wget` with `dnf`.
2. Adds the cron job `Minecraft server`. At boot, it starts
   `/root/LINDS/script.sh` in `screen`.
3. Sets `vm.nr_hugepages` to `12288`.
4. Mounts `jd-truenas-01.linds.com.au:/mnt/NAS` at `/mnt/NAS` (NFS 4.2) and
   adds the mount to `/etc/fstab`.
5. Adds a cron job that copies `/root/LINDS` to `/mnt/NAS/minecraft/LINDS/`
   every day at 23:00.

## Requirements

- The host is RedHat family. The role uses `dnf`.
- The server files and `script.sh` are in `/root/LINDS`. The role does not
  install the server.

## Variables

The role has no variables. The paths, the NFS server and the number of huge
pages are written in `tasks/main.yml`.

## How to use it

`playbooks/minecraft.yml` applies `common` and then this role to the group
`minecraft` (`jd-minecraft-01`). See
[playbooks/minecraft.md](../../playbooks/minecraft.md).

## Safety

**CAUTION:** `vm.nr_hugepages: 12288` reserves memory that other processes
cannot use. With 2 MiB pages, this is 24 GiB.

## Known problems

- Two tasks write the same cron job, `Minecraft server`. The second task
  wins, so each run reports two changes.
- If `/mnt/NAS/minecraft/LINDS/` exists, `cp -pr` copies the server into
  `/mnt/NAS/minecraft/LINDS/LINDS`.
