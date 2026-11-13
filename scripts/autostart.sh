#!/usr/bin/env bash
# Keeps MT5 running whenever the internet is available.
#  1. waits until the internet works
#  2. starts MT5 (scripts/start.sh), which reopens the chart with the EA
#  3. every 60 s: if MT5 is not running and the internet is up, starts it again
# The EA itself (input "Auto-start") begins trading once MT5 is connected.
#
# Runs at login via ~/.config/autostart/xauscalper.desktop (scripts/install-autostart.sh).
# Log: ~/scalper/autostart.log
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO_DIR/autostart.log"
CHECK_EVERY=60

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

online() {
  # Any of these answering means the internet works.
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
    || curl -s --max-time 5 -o /dev/null https://www.google.com
}

mt5_running() { pgrep -f "terminal64.exe" >/dev/null 2>&1; }

# Only one watchdog at a time
exec 9>"/tmp/xauscalper-autostart.lock"
if ! flock -n 9; then
  echo "autostart.sh is already running"
  exit 0
fi

log "watchdog started"
sleep 20   # let the desktop and network manager settle after login
was_online=1

while true; do
  if online; then
    [ "$was_online" -eq 0 ] && log "internet is back"
    was_online=1
    if ! mt5_running; then
      log "MT5 not running: starting it"
      "$REPO_DIR/scripts/start.sh" >> "$LOG" 2>&1
    fi
  else
    [ "$was_online" -eq 1 ] && log "no internet: waiting"
    was_online=0
  fi
  sleep "$CHECK_EVERY"
done
