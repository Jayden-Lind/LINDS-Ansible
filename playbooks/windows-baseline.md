# windows-baseline.yml

The playbook applies the server baseline (`roles/windows_baseline`) to one
server that is in the domain.

## Before you start

- Run `make kinit`.
- The server is in the group `windows` of the inventory.

## Procedure

1. Run `make windows-baseline HOST=<fqdn>`.
2. To install updates too, add `UPDATES=true`. The server can restart.
3. To apply one setting only, add `TAGS=<tag>`, for example
   `TAGS=cpu-mitigations` or `TAGS=nic-offloads`.

**CAUTION:** On a server that never had the baseline, the first run turns on
the firewall and Defender. Apply it to one server at a time and look at the
server after the run.

## What it changes

- See `roles/windows_baseline/README.md`.
- A change to the CPU mitigations takes effect at the next restart. The
  playbook does not restart the server for it.
- A change to the network adapter offloads restarts the adapter. The network
  stops for about 3 seconds, and SMB clients connect again by themselves.
