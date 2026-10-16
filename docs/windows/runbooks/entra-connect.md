# Sync the domain to Entra again

Since 11 October 2026 nothing syncs the domain to Entra. Entra Connect was on
the old `linds-dc2`, and the rebuild did not install it again. Before that it
was in staging mode since November 2024, so it exported nothing.

The configuration export (52 files) and the state of the old installation are
in `\\linds-dc\NAS\server\backup\linds-dc2-before-rebuild-2026-10-11`. The
disk of VM 110 (`LINDS-DC2-old`) also has the old installation.

## Procedure

1. Install Entra Connect on a member server, not on a domain controller.
2. Import the configuration export.
3. In the wizard, choose the sign-in method: pass-through authentication (it
   needs a new agent) or password hash sync. This needs a tenant administrator.
4. Leave staging mode in the wizard ("Configure staging mode").

## Notes

- If you do not want Entra Connect, delete the account `MSOL_abd8982191a0`. It
  can read every password hash in the domain.
- Over WinRM, the cmdlets that read the run history or the settings fail with
  "no endpoint listening". Run them in a console, or in a scheduled task with
  logon type S4U.
