#!/bin/bash
# WAN refresh & stabilization for UDM Pro Max + Zyxel passthrough
# Triggers on schedule or when WAN health is bad

LOGFILE="/mnt/data/wan-refresh.log"
IFACE="eth8"
PING_TARGET="8.8.8.8"
DATE() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "[$(DATE)] $1" >> "$LOGFILE"; }

# --- 0) Quick health check ---
log "Health check started..."
if ping -c 3 -W 1 "$PING_TARGET" >/dev/null 2>&1; then
  log "WAN healthy (ping ok). Skipping refresh."
  echo "----------------------------------------" >> "$LOGFILE"
  exit 0
fi
log "WAN check FAILED. Proceeding..."

# --- 1) Snapshot original IP ---
OGIP=$(ip addr show "$IFACE" | awk '/inet / {print $2}')
log "Original WAN IP (OGIP): ${OGIP:-NONE}"

# --- 2) Release/Renew via udhcpc ---
PID=$(pidof udhcpc)
if [ -n "$PID" ]; then
  log "udhcpc PID: $PID (sending release/renew)"
  kill -SIGUSR2 "$PID"; sleep 2
  kill -SIGUSR1 "$PID"
else
  log "ERROR: udhcpc not found!"
fi

# helper: wait for an IP on IFACE
wait_for_ip() {
  for i in {1..60}; do
    NEWIP=$(ip addr show "$IFACE" | awk '/inet / {print $2}')
    [ -n "$NEWIP" ] && return 0
    sleep 2
  done
  return 1
}

# helper: require N consecutive successful pings to declare "stable"
require_stable_pings() {
  local need=$1 ok=0 tries=0
  while [ $tries -lt 60 ]; do
    if ping -c 1 -W 1 "$PING_TARGET" >/dev/null 2>&1; then
      ok=$((ok+1))
      [ $ok -ge $need ] && return 0
    else
      ok=0
    fi
    tries=$((tries+1))
    sleep 1
  done
  return 1
}

# --- 3) Wait for IP then test stability ---
if wait_for_ip; then
  NEWIP=$(ip addr show "$IFACE" | awk '/inet / {print $2}')
  log "WAN has NEW IP: $NEWIP"
  if [ "$OGIP" = "$NEWIP" ]; then
    log "Result: IP is the SAME."
  else
    log "Result: IP CHANGED (OGIP=$OGIP → NEWIP=$NEWIP)"
  fi

  log "Stability check: requiring 5 consecutive good pings..."
  if require_stable_pings 5; then
    log "WAN stable after renew. Done."
    echo "----------------------------------------" >> "$LOGFILE"
    exit 0
  else
    log "Stability check FAILED after renew. Proceeding to link bounce..."
  fi
else
  log "No IP acquired after renew attempt. Proceeding to link bounce..."
fi

# --- 4) Bounce the link (fix ARP/route lag) ---
log "Bouncing $IFACE..."
ip link set dev "$IFACE" down
sleep 3
ip link set dev "$IFACE" up

if wait_for_ip && require_stable_pings 5; then
  NEWIP=$(ip addr show "$IFACE" | awk '/inet / {print $2}')
  log "WAN stable after link bounce. Current IP: $NEWIP"
  echo "----------------------------------------" >> "$LOGFILE"
  exit 0
fi

# --- 5) Last resort: reboot ---
log "ERROR: Still unstable/no IP after bounce. Rebooting UDM..."
echo "----------------------------------------" >> "$LOGFILE"
/sbin/reboot
