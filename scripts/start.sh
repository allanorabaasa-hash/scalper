#!/usr/bin/env bash
# Starts every MT5 terminal that is not already running:
#   account 1 = the normal install in Program Files
#   accounts 2, 3, ... = portable copies in C:\MT5\Acc<N> (created with scripts/add-account.sh)
set -uo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all

shopt -s nullglob
main="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"

running() {   # $1 = regex that identifies the terminal's folder (Wine may show Windows or Unix paths)
  pgrep -af "terminal64.exe" 2>/dev/null | grep -qE "$1"
}

start_one() {   # $1 = exe, $2 = name, $3 = extra flag, $4 = folder regex
  if running "$4"; then
    echo "$2 already running"
    return
  fi
  echo "Starting $2"
  "$WINE" "$1" $3 >/dev/null 2>&1 &
  sleep 5
}

[ -f "$main" ] && start_one "$main" "MetaTrader 5 (account 1)" "" 'MetaTrader 5[/\\]terminal64'
for exe in "$WINEPREFIX"/drive_c/MT5/Acc*/terminal64.exe; do
  name="$(basename "$(dirname "$exe")")"
  start_one "$exe" "$name" "/portable" "${name}[/\\]terminal64"
done
