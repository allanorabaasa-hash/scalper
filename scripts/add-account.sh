#!/usr/bin/env bash
# Creates another MT5 terminal for another trading account.
# One MT5 terminal can be logged into only one account at a time, so every extra account gets
# its own portable copy of MT5 in C:\MT5\Acc<N> (its own login, charts, EA settings and mode).
#
#   ./scripts/add-account.sh 2        creates C:\MT5\Acc2 and opens it so you can log in
#   ./scripts/add-account.sh --list   shows the account terminals
#
# Your normal MT5 (Program Files) stays account 1. start.sh / autostart.sh start all of them.
set -euo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
BASE="$WINEPREFIX/drive_c/MT5"

if [ "${1:-}" = "--list" ]; then
  echo "Account 1: $SRC"
  for d in "$BASE"/Acc*; do [ -d "$d" ] && echo "$(basename "$d"): $d"; done
  exit 0
fi

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 2 ] || { echo "Usage: $0 <number 2 or higher>   (or --list)"; exit 1; }
[ -f "$SRC/terminal64.exe" ] || { echo "MT5 not found in $SRC"; exit 1; }
DEST="$BASE/Acc$N"
[ -e "$DEST" ] && { echo "$DEST already exists."; exit 1; }

echo "Copying MT5 to $DEST ..."
mkdir -p "$BASE"
cp -r "$SRC" "$DEST"
# a fresh copy must not inherit account 1's login, charts or settings
rm -rf "$DEST/config" "$DEST/profiles/charts" "$DEST/logs" "$DEST/MQL5/Logs" 2>/dev/null || true

echo "Installing the EA into the new terminal ..."
"$REPO_DIR/scripts/install.sh" >/dev/null 2>&1 || true

echo "Opening Acc$N. In it:"
echo "  1. File -> Login to Trade Account -> log in to the account for this terminal"
echo "  2. open the chart (XAUUSDm or BTCUSDm), attach XAUScalper, choose its Mode and Lot size"
echo "  3. turn on Algo Trading"
"$WINE" "$DEST/terminal64.exe" /portable >/dev/null 2>&1 &
