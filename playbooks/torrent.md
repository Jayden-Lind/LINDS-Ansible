# torrent.yml

The playbook installs qBittorrent and mounts the NAS on the torrent hosts. It
applies the roles `common` and `torrent`.

## Before you start

- Run the commands from the repository root.
- Install the Galaxy roles and collections: `make update-requirements`.
- The play uses `become: true`. Your user needs `sudo` without a password on
  the hosts.
- If somebody changed settings in the qBittorrent web UI, copy the files from
  the hosts to the role first. See "Safety" in
  [roles/torrent/README.md](../roles/torrent/README.md).

## Procedure

**NOTE:** Merging to `main` applies this playbook to the torrent hosts. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/torrent.yml --check --diff`.
2. Run `ansible-playbook playbooks/torrent.yml`. Add `--limit jd_torrent` or
   `--limit linds_torrent` for one site.

## What it changes

- The group `torrent`: `jd-torrent-01.linds.com.au` (`jd_torrent`) and
  `10.0.36.2` (`linds_torrent`).
- See [roles/common/README.md](../roles/common/README.md) and
  [roles/torrent/README.md](../roles/torrent/README.md).
