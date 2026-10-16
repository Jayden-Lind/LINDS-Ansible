# A server starts with the wrong time

**Symptom:** After a cold start:

- WinRM says "the specified credentials were rejected by the server".
- AD replication fails with error 1398 (time difference).
- A service that logs on with a domain account at boot does not start.

**Cause:** The VM has no OS type in Proxmox. Proxmox then gives a hardware clock
in UTC, and Windows reads it as local time. The server is 10 or 11 hours wrong
until the time service corrects it.

## Check

Ask the server for the time. You do not need to log on:

```shell
ntpdate -q <address>
qm config <vmid> | grep -E 'ostype|localtime'
```

An offset of about -39600 seconds shows this fault.

## Procedure

1. On the Proxmox host, run `qm set <vmid> --localtime 1`, or set
   `ostype: win11`. It takes effect at the next cold start.
2. After the time is correct, run `repadmin /syncall <dc> /Ade` to clear the
   replication errors.

The VMs that Terraform makes have `ostype: win11`.
