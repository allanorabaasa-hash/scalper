#!/usr/bin/env bash
# Stops the autostart watchdog and shuts down all MT5 terminals in the Wine prefix.
# Killing a terminal does NOT close open positions: their SL/TP stay on the broker's
# server. Press STOP (and CLOSE ALL if wanted) on the EA panel first.
# The watchdog starts again at the next login (or run scripts/autostart.sh).
set -uo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"

read -r -p "Shut down MT5 now? Open positions keep their SL/TP. [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

pkill -f "scripts/autostart.sh" && echo "Autostart watchdog stopped." || true
pkill -f terminal64.exe && echo "MT5 terminals closed." || echo "No MT5 terminals running."
