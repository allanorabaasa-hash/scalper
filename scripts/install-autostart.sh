#!/usr/bin/env bash
# Registers scripts/autostart.sh to run when you log in to the Kali desktop.
#   ./scripts/install-autostart.sh            install
#   ./scripts/install-autostart.sh --remove   uninstall
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP="$HOME/.config/autostart/xauscalper.desktop"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$DESKTOP"
  pkill -f "scalper/scripts/autostart.sh" 2>/dev/null || true
  echo "Autostart removed."
  exit 0
fi

chmod +x "$REPO_DIR"/scripts/*.sh
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=XAUScalper autostart
Comment=Start MetaTrader 5 when the internet is available and keep it running
Exec=$REPO_DIR/scripts/autostart.sh
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=false
EOF

echo "Installed: $DESKTOP"
echo "It runs at every login. Start it now without logging out:"
echo "  nohup $REPO_DIR/scripts/autostart.sh >/dev/null 2>&1 &"
