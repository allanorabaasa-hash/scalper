#!/usr/bin/env bash
# Starts every MT5 terminal: portable copies in C:\MT5\Acc* if present,
# otherwise the default install in Program Files.
set -uo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all

shopt -s nullglob
copies=("$WINEPREFIX"/drive_c/MT5/Acc*/terminal64.exe)

if [ "${#copies[@]}" -gt 0 ]; then
  for exe in "${copies[@]}"; do
    echo "Starting $(basename "$(dirname "$exe")")"
    "$WINE" "$exe" /portable >/dev/null 2>&1 &
    sleep 5
  done
else
  exe="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
  [ -f "$exe" ] || { echo "MT5 not found at $exe"; exit 1; }
  echo "Starting MetaTrader 5"
  "$WINE" "$exe" >/dev/null 2>&1 &
fi

echo "Terminals launching. Press START on each EA panel when ready."
