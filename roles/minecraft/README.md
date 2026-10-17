# minecraft

The `minecraft` role prepares the Minecraft host: Java, a start at boot, huge
pages, the NAS mount and a nightly copy of the server to the NAS.

## What it does

1. Installs `screen`, `java-latest-openjdk`, `nfs-utils`, `net-tools` and
   `wget` with `dnf`.
2. Adds a cron job that starts `/root/LINDS/script.sh` in `screen` at boot.
3. Sets `vm.nr_hugepages` to `12288`.
4. Mounts `jd-truenas-01.linds.com.au:/mnt/NAS` (the storage address of
   `jd-proxmox-02`) at `/mnt/NAS` with NFS 4.2.
5. Adds a cron job that copies `/root/LINDS` to `/mnt/NAS/minecraft/` at
   23:00 every night.

## Requirements

- A RedHat-family host. The server files are in `/root/LINDS`.
- The play uses `become: true`.

## Variables

The role has no variables.

## How to use it

`playbooks/minecraft.yml` applies `common` and then this role. See
[playbooks/minecraft.md](../../playbooks/minecraft.md).

## Known problems

- The VM (`JD-Minecraft-01`, VM 1110 on `jd-proxmox-02`) is stopped and has no
  DNS name. Start it and give it a name before you run the playbook.
