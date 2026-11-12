#!/usr/bin/env bash
# Copies XAUScalper.mq5 into every MT5 install inside the Wine prefix and compiles it.
# Usage:  ./scripts/install.sh
set -euo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/src/XAUScalper.mq5"

[ -x "$WINE" ] || { echo "Wine not found at $WINE (set WINE=/path/to/wine)"; exit 1; }
[ -f "$SRC" ]  || { echo "Source not found: $SRC"; exit 1; }

EDITOR_EXE="$(find "$WINEPREFIX/drive_c" -iname 'MetaEditor64.exe' 2>/dev/null | head -n1)"
[ -n "$EDITOR_EXE" ] || { echo "MetaEditor64.exe not found under $WINEPREFIX/drive_c"; exit 1; }

mapfile -t EXPERT_DIRS < <(find "$WINEPREFIX/drive_c" -type d -path '*/MQL5/Experts' 2>/dev/null)
[ "${#EXPERT_DIRS[@]}" -gt 0 ] || { echo "No MQL5/Experts folder found. Start MT5 once first."; exit 1; }

for dir in "${EXPERT_DIRS[@]}"; do
  echo "==> $dir"
  cp "$SRC" "$dir/XAUScalper.mq5"
  rm -f "$dir/XAUScalper.ex5" "$dir/XAUScalper.log"

  win_src="$("$WINE" winepath -w "$dir/XAUScalper.mq5" 2>/dev/null | tr -d '\r')"
  win_mql5="$("$WINE" winepath -w "$(dirname "$dir")" 2>/dev/null | tr -d '\r')"

  "$WINE" "$EDITOR_EXE" /compile:"$win_src" /inc:"$win_mql5" /log >/dev/null 2>&1 || true

  if [ -f "$dir/XAUScalper.ex5" ]; then
    echo "    compiled OK"
  else
    echo "    COMPILE FAILED. Log:"
    if [ -f "$dir/XAUScalper.log" ]; then
      iconv -f UTF-16LE -t UTF-8 "$dir/XAUScalper.log" 2>/dev/null | grep -Ei 'error|warning|result' || true
    else
      echo "    (no log produced; open the file in MetaEditor and press F7)"
    fi
  fi
done

echo "Done. In MT5: Navigator > Expert Advisors > right-click > Refresh, then drag XAUScalper onto an XAUUSD chart."
