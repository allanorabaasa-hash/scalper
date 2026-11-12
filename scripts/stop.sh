#!/usr/bin/env bash
# Shuts down all MT5 terminals in the Wine prefix.
# Press STOP (and CLOSE ALL if wanted) on each EA panel first:
# killing a terminal does NOT close open positions. Their SL/TP stay on the broker's server.
set -uo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"

read -r -p "Have you stopped the bot on every panel? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

pkill -f terminal64.exe && echo "MT5 terminals closed." || echo "No MT5 terminals running."
