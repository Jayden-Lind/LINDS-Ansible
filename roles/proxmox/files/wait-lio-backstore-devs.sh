#!/bin/bash
# Wait for every block-backstore device path referenced in the LIO
# saveconfig.json to exist before `targetctl restore` runs.
#
# Why: ZFS zvol /dev links (especially from pools imported late, e.g. by
# Proxmox storage activation) can appear seconds after
# rtslib-fb-targetctl.service starts. targetctl then silently skips the
# missing block backstores AND their LUN mappings ("not a TYPE_DISK block
# device"), leaving iSCSI targets with 0 LUNs until `targetctl restore`
# is re-run by hand. This bit the democratic-csi PVCs on 2026-07-11.
set -u

CONFIG=/etc/rtslib-fb-target/saveconfig.json
TIMEOUT=${1:-180}

[ -f "$CONFIG" ] || exit 0

mapfile -t devs < <(python3 - "$CONFIG" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
for so in cfg.get("storage_objects", []):
    dev = so.get("dev", "")
    if isinstance(dev, str) and dev.startswith("/dev/"):
        print(dev)
EOF
)

deadline=$((SECONDS + TIMEOUT))
for dev in "${devs[@]}"; do
    until [ -e "$dev" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ERROR: timed out after ${TIMEOUT}s waiting for ${dev};" \
                 "targetctl restore will skip its backstore and LUNs." \
                 "Fix the device and run 'targetctl restore' manually." >&2
            # Exit 0 so restore still brings up whatever is available.
            exit 0
        fi
        sleep 2
    done
done
echo "all $((${#devs[@]})) backstore devices present"
