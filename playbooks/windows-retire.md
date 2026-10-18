# windows-retire.yml

The playbook retires a Windows server: a domain controller, or a member such
as a file server. It hands over what the server carries, demotes it if it is a
domain controller, stops it, and removes what is left of it in the directory
and in DNS.

## Before you start

- Run `kinit -f Administrator@LINDS.COM.AU`.
- Run `repadmin /replsummary` on a domain controller. It must show no errors.
- Make sure that the server has nothing that is not in code: DNS zones that
  are not AD-integrated, shares other than SYSVOL and NETLOGON, software,
  scheduled tasks, certificates with private keys.
- For a replication member: run the file check the day before (step 1).

## Procedure

1. Optional: run the file check. It only reads. It stops if the server has
   files that its partner does not have:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn> --tags unique-files
   ```

2. If a new domain controller with the same name comes next, run:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn> -e windows_dc_retire_keep_bridgehead=true
   ```

3. For a member server, or for a domain controller that goes for good, run:

   ```shell
   ansible-playbook playbooks/windows-retire.yml -e target=<fqdn>
   ```

4. On the Proxmox host, stop the old VM from starting:
   `qm set <vmid> --onboot 0 --name <name>-old`.

**WARNING:** Do not start the old VM again. It would come up as a member with
an account that does not exist, at the address of the new server.

## What it changes

1. The partner gets the FSMO roles of the server, and the server leaves its
   replication groups.
2. For the CA: the playbook makes a last backup and removes the CA.
3. For a domain controller: the partner becomes the preferred bridgehead of
   its site. The playbook waits until replication works through it in both
   directions.
4. A domain controller is demoted and restarts as a member. Then the server
   stops.
5. The partner deletes its computer account and server object, and removes
   its DNS records from every DNS server.
6. Without `-e windows_dc_retire_keep_bridgehead=true`, the partner releases
   the preferred bridgehead.

It takes 15 to 55 minutes. The DNS step alone takes about 7 minutes.

## Tags

| Tag | Runs |
| --- | --- |
| `unique-files` | The file check only. |
| `handover` | The file check, the FSMO roles, replication and the CA. |
| `bridgehead` | Step 3 only. It does not change the server to retire. |
| `cleanup` | Step 5 and 6, for a server that is already demoted and stopped. |
| `bridgehead-release` | Step 6 only. |

## If it fails

- The bridgehead step stops: replication between the sites does not work.
  Look at `repadmin /showrepl` on each domain controller. Error 1396: see
  `docs/windows/runbooks/replication.md`.
- Run the same command again. The steps that are complete do nothing.
