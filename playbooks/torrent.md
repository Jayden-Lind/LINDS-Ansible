# torrent.yml

The `torrent.yml` playbook sets up the qBittorrent hosts at both sites. It
applies the roles `common` and `torrent`.

## Before you start

- Run the commands from the repository root. `ansible.cfg` reads the
  inventory and the `vault_password` file from there.
- Install the Galaxy roles and collections: `make update-requirements`.

## Procedure

**NOTE:** Each run stops and starts qBittorrent. See "Known problems" in the
role README.

1. Run `ansible-playbook playbooks/torrent.yml --limit jd_torrent` for JD.
2. Run `ansible-playbook playbooks/torrent.yml --limit linds_torrent` for
   LINDS.

## What it changes

- The group `torrent` in `inventory/torrent.yml`:
  `jd-torrent-01.linds.com.au` (group `jd_torrent`) and `10.0.36.2` (group
  `linds_torrent`).
- For the settings, see [roles/common/README.md](../roles/common/README.md)
  and [roles/torrent/README.md](../roles/torrent/README.md).

## If it fails

- Read "Known problems" in the two role READMEs.
