#!/usr/bin/env python3
"""Ad-hoc PowerShell runner over WinRM/Kerberos against the LINDS Windows hosts.

Usage:  winrun.py <host-or-@group> <script-file>
        winrun.py <host-or-@group> -c '<inline powershell>'

Groups: @dc   the three domain controllers
        @fs   the file server
        @all  everything

Reads the caller's existing Kerberos ticket cache; no passwords anywhere.
Get a ticket first:
    KRB5_CONFIG=$PWD/krb5.conf kinit Administrator@LINDS.COM.AU
"""
import base64
import sys
import winrm

GROUPS = {
    "@dc": ["jd-dc-01.linds.com.au", "linds-dc.linds.com.au", "linds-dc2.linds.com.au"],
    "@fs": ["jd-fs-01.linds.com.au"],
    "@all": ["jd-dc-01.linds.com.au", "linds-dc.linds.com.au",
             "linds-dc2.linds.com.au", "jd-fs-01.linds.com.au"],
}

# powershell.exe -encodedcommand puts the whole script on the command line,
# which Windows caps near 8 KB. Anything larger is staged to a temp file in
# base64 chunks, executed, then deleted.
INLINE_LIMIT = 2000


def make_session(host):
    return winrm.Session(
        "http://%s:5985/wsman" % host,
        auth=(None, None),
        transport="kerberos",
        realm="LINDS.COM.AU",
        # GPMC cmdlets make an onward LDAP bind; without a forwarded ticket
        # they fail with LDAP_OPERATIONS_ERROR (0x80072020).
        kerberos_delegation=True,
        message_encryption="always",
        read_timeout_sec=900,
        operation_timeout_sec=840,
    )


def run(host, script):
    session = make_session(host)
    # Progress records come back on stderr as CLIXML and drown real errors.
    script = "$ProgressPreference='SilentlyContinue'\n" + script

    if len(script) <= INLINE_LIMIT:
        return session.run_ps(script)

    blob = base64.b64encode(script.encode("utf-8")).decode("ascii")
    remote = r"$env:TEMP\_winrun.b64"
    chunks = [blob[i:i + 1500] for i in range(0, len(blob), 1500)]

    for n, chunk in enumerate(chunks):
        op = ">" if n == 0 else ">>"
        res = session.run_ps("'%s' %s %s" % (chunk, op, remote))
        if res.status_code != 0:
            raise RuntimeError("staging chunk %d failed: %s"
                               % (n, res.std_err.decode("utf-8", "replace")))

    try:
        return session.run_ps(
            "$b=(Get-Content %s -Raw) -replace '\\s',''; "
            "$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)); "
            "Invoke-Expression $s" % remote
        )
    finally:
        session.run_ps("Remove-Item %s -Force -ErrorAction SilentlyContinue" % remote)


def is_only_progress(err):
    """True if stderr holds nothing but CLIXML progress records."""
    return err.startswith("#< CLIXML") and 'S="Error"' not in err


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    target = sys.argv[1]
    if sys.argv[2] == "-c":
        script = sys.argv[3]
    else:
        with open(sys.argv[2]) as fh:
            script = fh.read()

    hosts = GROUPS.get(target, [target])
    failed = False
    for host in hosts:
        print("=" * 72)
        print("### %s" % host)
        print("=" * 72)
        try:
            result = run(host, script)
        except Exception as exc:                      # noqa: BLE001
            print("!! CONNECTION FAILED: %s: %s" % (type(exc).__name__, exc))
            failed = True
            continue
        out = result.std_out.decode("utf-8", "replace").rstrip()
        err = result.std_err.decode("utf-8", "replace").rstrip()
        if out:
            print(out)
        if err and not is_only_progress(err):
            print("--- stderr (rc=%d) ---" % result.status_code)
            print(err)
            failed = True
        print()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
