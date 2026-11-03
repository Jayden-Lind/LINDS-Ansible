# media.yml

The playbook configures the media hosts: Plex Media Server at LINDS, and
qBittorrent at both sites. Each host also gets the role `common`.

| Play | Hosts | Roles |
| --- | --- | --- |
| Plex | `linds-plex-01.linds.com.au` (group `plex`) | [common](../roles/common/README.md), [plex](../roles/plex/README.md) |
| qBittorrent | `jd-torrent-01.linds.com.au` (`jd_torrent`) and `10.0.36.2` (`linds_torrent`) | [common](../roles/common/README.md), [torrent](../roles/torrent/README.md) |

## Before you start

- Run the commands from the repository root.
- Install the Galaxy roles and collections:
  `ansible-galaxy install -r requirements.yml`.
- The plays use `become: true`. Your user needs `sudo` without a password on
  the hosts.
- If somebody changed settings in the qBittorrent web UI, copy the files from
  the hosts to the role first. See "Safety" in
  [roles/torrent/README.md](../roles/torrent/README.md).

## Procedure

**NOTE:** Merging to `main` applies this playbook to the media hosts. See
[deploy/README.md](../deploy/README.md). Use the commands below to see a
change before you merge it, or to apply a change by hand.

1. Run `ansible-playbook playbooks/media.yml --check --diff`.
2. Run `ansible-playbook playbooks/media.yml`.
3. To apply one group, add `--limit plex`, `--limit torrent`,
   `--limit jd_torrent` or `--limit linds_torrent`.

## What it changes

- The groups `plex` and `torrent` in `inventory/media.yml`.
- See the README of each role.
