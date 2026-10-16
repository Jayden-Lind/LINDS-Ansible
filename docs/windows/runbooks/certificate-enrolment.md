# Computers cannot enrol certificates

**Symptom:** Autoenrolment fails with `0x800706ba` (RPC server unavailable).
An administrator can enrol from the same computer.

**Cause:** The computer account reaches the CA over DCOM. It must pass the
machine-wide DCOM launch limit before the CA looks at its own permissions. On
`linds-dc` the group `Certificate Service DCOM Access` was not in that limit,
so computer accounts had no remote activation right.

## Procedure

1. On the CA, open `HKLM\SOFTWARE\Microsoft\Ole\MachineLaunchRestriction`
   (a security descriptor in `REG_BINARY`).
2. Add the ACE `(A;;CCDCLCSWRP;;;CD)`. `CD` is `Certificate Service DCOM
   Access` (S-1-5-32-574).
3. No restart is necessary. Run `certutil -pulse` on a domain controller and
   look for new certificates.

**NOTE:** This is a repair to one server. Ansible does not manage it. Check it
after you rebuild the CA.
