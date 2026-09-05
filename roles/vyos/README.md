# vyos role

Manages both VyOS routers: **jd-vyos-01** (10.0.50.1) and **linds-vyos-01**,
selected by the `vyos_site` group var (`jd` / `linds`).

## Layout — where things live

| What | Where |
|---|---|
| Data (addresses, VLANs, DHCP maps, firewall rules, …) | `inventory/group_vars/jd_vyos.yml` / `linds_vyos.yml`; shared defaults in `defaults/main.yml` |
| CLI syntax (`set …` lines) | `templates/*.j2`, rendered by thin task files |
| Task flow | `tasks/main.yml` (common) → `tasks/{jd,linds}.yml` (per-site orchestrator) → one task file per area (`jd_interfaces.yml`, `jd_suricata.yml`, …) |
| Secrets | ansible-vault values in the inventory (`vault_password` file is picked up via `ansible.cfg`); `files/linds-ca.cer` is a vault-encrypted file that `with_file` decrypts transparently |

To change configuration, edit **group_vars data** first; only touch a template
when the CLI syntax itself changes. The task files should stay thin wrappers.

## Running it

```sh
# dry run first — shows the config diff without committing anything
ansible-playbook playbooks/vyos.yml --limit jd_vyos --check --diff

# real run (module_defaults in the playbook auto-saves the config)
ansible-playbook playbooks/vyos.yml --limit jd_vyos
```

A clean box shows every `vyos_config` task `ok`. Investigate any `changed`
before a real run: it is either drift (someone changed the box by hand —
decide which side wins and reconcile) or a task regression. The `vyos_command`
tasks (post-boot script, /etc file seeds) are skipped in check mode and always
report unchanged (`changed_when: false`).

## Conventions and sharp edges

* **Single quotes, never double.** `vyos_config` compares candidate lines
  against `show configuration commands`, which single-quotes leaf values. Bare
  and single-quoted values compare equal; **double-quoted values never match**,
  so the task pushes on every run and check mode reports phantom drift.
  Write `interface '{{ wan_interface }}'`, not `interface "{{ wan_interface }}"`.
* **PKI blobs need the prefix-gate pattern.** The `network_cli` terminal runs
  at width 512, and the screen-scrape corrupts one character at every wrap
  point of longer lines — so `vyos_config` can never match a cert/key line
  against the running config and reports phantom drift forever (the router's
  own `compare` shows "No changes"). PKI tasks are therefore gated with a
  `when:` prefix match against `vyos_pki_running` (registered in
  `tasks/main.yml`); use the same pattern for any future >512-char value.
* **The role only adds lines — it never prunes.** Deleting something from
  group_vars does not delete it from the router; remove it on the box (or add
  an explicit `delete …` line) as part of the same change.
* **`ansible_command_timeout` is 180s** (inventory `vyos` group vars): a commit
  touching an interface cascades into dependent services (Suricata reloads
  ~52k ET Open rules) and blows through the 30s network_cli default.
* **`/config/scripts/vyos-postconfig-bootup.script` has exactly one writer:**
  `jd_postboot.yml`, which writes it whole. Never append to it from another
  task — a previous split writer duplicated blocks on every run.
* **Suricata non-native bits** (`/etc/rsyslog.d/60-suricata-eve.conf` EVE→Loki
  relay, `/etc/suricata/disable.conf` sid tuning, journald size cap, and the
  `suricata.service.d/20-linds-capture.conf` runmode/thread drop-in) are
  written by `jd_suricata.yml` and re-seeded at boot by the post-boot script,
  because `/etc` does not survive VyOS image upgrades. A fresh image also
  needs one manual `update suricata` to fetch ET Open — and so does any
  change to `vyos_suricata_disabled_sids` (suricata-update is what applies
  disable.conf). Capture runs as **one ordered capture thread + autofp**:
  with the stock one-worker-per-core fanout, the kernel sprays the router's
  own VLAN-tagged egress copies across threads (`tcp.pkt_on_wrong_thread`
  15–30%), so check that counter stays at 0 after any Suricata/VyOS upgrade
  (`sudo suricatasc -c dump-counters /run/suricata/suricata.socket`).
* **Patching VyOS Jinja templates under `/usr/share` is a trap:** the
  long-lived `vyos-configd` daemon caches templates from first use, so the
  next commit silently renders the stale copy unless configd is restarted.
  This role deliberately contains no such patches (the one it had was replaced
  by the rsyslog relay) — prefer a design that avoids them.

## jd task-file map

`jd.yml` runs, in order (ordering matters — interfaces before DHCP/firewall,
IPsec before BGP-over-vti0): interfaces → dhcp → dns → services → **suricata**
→ firewall → nat → ipsec site-to-site → ipsec remote-access → wireguard →
routing → post-boot script.
