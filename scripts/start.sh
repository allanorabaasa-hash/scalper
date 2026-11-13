#!/usr/bin/env bash
# Starts every MT5 terminal that is not already running: portable copies in
# C:\MT5\Acc* if present, otherwise the default install in Program Files.
set -uo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all

shopt -s nullglob
copies=("$WINEPREFIX"/drive_c/MT5/Acc*/terminal64.exe)

running() {   # $1 = folder name that identifies the terminal in its command line
  pgrep -f "terminal64.exe" >/dev/null 2>&1 || return 1
  [ -z "$1" ] && return 0
  pgrep -af "terminal64.exe" | grep -q "$1"
}

if [ "${#copies[@]}" -gt 0 ]; then
  for exe in "${copies[@]}"; do
    name="$(basename "$(dirname "$exe")")"
    if running "$name"; then
      echo "$name already running"
      continue
    fi
    echo "Starting $name"
    "$WINE" "$exe" /portable >/dev/null 2>&1 &
    sleep 5
  done
else
  exe="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
  [ -f "$exe" ] || { echo "MT5 not found at $exe"; exit 1; }
  if running ""; then
    echo "MetaTrader 5 already running"
  else
    echo "Starting MetaTrader 5"
    "$WINE" "$exe" >/dev/null 2>&1 &
  fi
fi
