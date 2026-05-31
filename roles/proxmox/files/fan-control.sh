#!/usr/bin/env bash
# Thermal/power-aware BMC fan controller for Lenovo ThinkSystem SR655 (EPYC 7B13).
# Idle-quiet, ramps on CPU Tctl AND CPU package power so sudden bursts can't throttle.
# Manual duty (0-100%) via:  ipmitool raw 0x3c 0x30 0x00 0x00 <duty>
#   calibration: 6%=~3700rpm  20%=~6700rpm  45%=~12200rpm  100%=~23000rpm
#
# Deploy:  install to /usr/local/sbin/fan-control.sh (chmod 755),
#          unit to /etc/systemd/system/fan-control.service, then
#          systemctl daemon-reload && systemctl enable --now fan-control.service
# Restore BMC auto control:  reboot, or  ipmitool mc reset cold
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

IPMI="ipmitool raw 0x3c 0x30 0x00 0x00"
POLL=5            # seconds between checks
MIN_DUTY=6        # never below this (~3700 rpm, quiet)
SAFE_DUTY=30      # applied on exit/stop as fail-safe (~9000 rpm)
DOWN_HOLD=4       # cycles a lower target must persist before stepping down (anti-hunt)
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj

# Resolve k10temp Tctl path by NAME (hwmon index can change across reboots)
K10=""
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = "k10temp" ] && { K10="$h"; break; }
done

# CPU Tctl (C) -> fan duty (%)
temp_duty() {
  local t=$1
  if   [ "$t" -ge 93 ]; then echo 100
  elif [ "$t" -ge 90 ]; then echo 60
  elif [ "$t" -ge 86 ]; then echo 40
  elif [ "$t" -ge 82 ]; then echo 25
  elif [ "$t" -ge 77 ]; then echo 15
  else echo "$MIN_DUTY"; fi
}

# Package power (W) -> minimum duty (leading indicator: pre-ramp on load before temp climbs)
power_duty() {
  local w=$1
  if   [ "$w" -ge 200 ]; then echo 60
  elif [ "$w" -ge 175 ]; then echo 40
  elif [ "$w" -ge 140 ]; then echo 25
  elif [ "$w" -ge 100 ]; then echo 15
  else echo 0; fi
}

apply() { $IPMI "$1" >/dev/null 2>&1; }

cleanup() { trap - TERM INT EXIT; echo "stopping -> fail-safe duty=${SAFE_DUTY}"; apply "$SAFE_DUTY"; exit 0; }
trap cleanup TERM INT EXIT

cur=-1; down=0; prev_e=""; prev_t=""
echo "started (k10temp=${K10:-NONE} poll=${POLL}s min=${MIN_DUTY}%)"

while true; do
  # --- CPU temperature (Tctl) ---
  t=63
  if [ -n "$K10" ] && [ -r "$K10/temp1_input" ]; then
    t=$(( $(cat "$K10/temp1_input") / 1000 ))
  else
    r=$(ipmitool sensor reading "CPU_Temp" 2>/dev/null | awk -F'|' '{gsub(/[^0-9]/,"",$2); print $2}')
    [ -n "$r" ] && t=$r
  fi

  # --- CPU package power from RAPL energy delta ---
  w=0
  if [ -r "$RAPL" ]; then
    e=$(cat "$RAPL"); now=$(date +%s)
    if [ -n "$prev_e" ] && [ "$now" -gt "$prev_t" ]; then
      de=$(( e - prev_e )); dt=$(( now - prev_t ))
      [ "$de" -ge 0 ] && w=$(( de / (dt * 1000000) ))
    fi
    prev_e=$e; prev_t=$now
  fi

  # --- target = worst-case of temp and power curves ---
  td=$(temp_duty "$t"); pd=$(power_duty "$w")
  target=$td; [ "$pd" -gt "$target" ] && target=$pd
  [ "$target" -lt "$MIN_DUTY" ] && target=$MIN_DUTY

  # --- hysteresis: ramp UP now, ramp DOWN only after DOWN_HOLD steady cycles ---
  if   [ "$target" -gt "$cur" ]; then down=0
  elif [ "$target" -lt "$cur" ]; then
    down=$(( down + 1 ))
    if [ "$down" -lt "$DOWN_HOLD" ]; then target=$cur; else down=0; fi
  else down=0; fi

  if [ "$target" -ne "$cur" ]; then
    apply "$target"
    echo "duty ${cur}% -> ${target}%  (Tctl=${t}C pkg=${w}W)"
    cur=$target
  else
    apply "$cur"   # keepalive so the BMC doesn't revert to its own (loud) auto curve
  fi

  sleep "$POLL"
done
