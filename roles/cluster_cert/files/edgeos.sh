#!/usr/bin/env bash
# Install a certificate as the web interface certificate of an EdgeOS device
# (an EdgeRouter), over SSH from the control node.
#
# EdgeOS has only Python 2, and Ansible does not run modules with Python 2, so
# the role does not connect to the device itself. This script does the work
# with ssh and the EdgeOS configuration commands.
#
# Usage:
#   edgeos.sh <user@host> <certificate> <key> <file-name>
#
#   certificate  the certificate that the device serves (serve.crt)
#   key          its private key (tls.key)
#   file-name    the file in /config/auth that holds both, for example
#                cluster-cert.pem
#
# The web server (lighttpd) reads the file that `service gui cert-file` names.
# The first time, the script sets that option, and the commit restarts the web
# server. After that, the script replaces the file and restarts the web server.
# /config/auth stays through a firmware upgrade.
#
# If the web server does not run with the new file, the script puts back what
# was there before (the old file, or the EdgeOS certificate) and fails.
#
# Each command string sent to the device is one line, with ";" between the
# commands. vbash, the EdgeOS login shell, makes ssh report exit status 1 for a
# command string of several lines, even when each command in it succeeds.
#
# To go back to the EdgeOS certificate, on the device: `configure`,
# `delete service gui cert-file`, `commit`, `save`.
set -euo pipefail

target=$1 crt=$2 key=$3 name=$4
case "$name" in
  "" | */* | *[!A-Za-z0-9._-]*)
    echo "edgeos.sh: the file name must be a plain file name, not '$name'" >&2
    exit 2 ;;
esac
path="/config/auth/$name"

ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" "$@"; }

# Run EdgeOS configuration commands (the arguments) in one session, then
# commit and save. Fails if a command or the commit fails.
configure() {
  local cmds="C=/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper; \$C begin" c
  for c in "$@"; do cmds+="; \$C $c || { \$C end; exit 1; }"; done
  ssh_ "$cmds; \$C commit || { \$C end; exit 1; }; \$C save >/dev/null; \$C end"
}

cert_file() { ssh_ "cli-shell-api returnActiveValue service gui cert-file" || true; }

# The new file is in use when lighttpd runs and the option names it. lighttpd
# stops at once if it cannot use the file, so a short wait is enough.
in_use() {
  local _
  for _ in 1 2 3 4 5; do
    if [ "$(ssh_ "systemctl is-active lighttpd" || true)" = active ] && [ "$(cert_file)" = "$path" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# The key, then the certificate, as in the EdgeOS default file, in one file that
# only root can read. It is written next to the old file and then moved in, so
# the web server never reads half a file. The old file stays as .prev until the
# new one is in use.
cat "$key" "$crt" | ssh_ "sudo sh -c 'umask 077; if [ -f $path ]; then cp -p $path $path.prev; fi; cat > $path.new && mv -f $path.new $path'"

before=$(cert_file)
if [ "$before" = "$path" ]; then
  ssh_ "sudo /bin/systemctl restart lighttpd" || true
  done_message="REPLACED $path and restarted the web server"
else
  configure "set service gui cert-file $path" || true
  done_message="INSTALLED $path as service gui cert-file (before: ${before:-the EdgeOS certificate})"
fi

if in_use; then
  ssh_ "sudo rm -f $path.prev"
  echo "$done_message"
  exit 0
fi

echo "edgeos.sh: the web server does not use the new certificate; putting back what was there before" >&2
if [ "$before" = "$path" ]; then
  ssh_ "sudo sh -c 'if [ -f $path.prev ]; then mv -f $path.prev $path; fi'; sudo /bin/systemctl restart lighttpd" || true
elif [ -n "$before" ]; then
  configure "set service gui cert-file $before" || true
else
  configure "delete service gui cert-file" || true
fi
if [ "$(ssh_ "systemctl is-active lighttpd" || true)" != active ]; then
  echo "edgeos.sh: the web server is still not running: look at 'systemctl status lighttpd' on the device" >&2
fi
exit 1
