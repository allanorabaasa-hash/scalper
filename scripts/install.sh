#!/usr/bin/env bash
# Copies the EA, its include files and the unit-test script into every MT5
# install inside the Wine prefix, then tries to compile them.
# Usage:  ./scripts/install.sh
set -euo pipefail

WINE="${WINE:-$HOME/wine-staging/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.mt5}"
export WINEDEBUG=-all

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EA_SRC="$REPO_DIR/src/XAUScalper.mq5"
INC_SRC="$REPO_DIR/src/Include/XAUScalper"
TEST_DIR="$REPO_DIR/tests"

[ -x "$WINE" ]    || { echo "Wine not found at $WINE (set WINE=/path/to/wine)"; exit 1; }
[ -f "$EA_SRC" ]  || { echo "Source not found: $EA_SRC"; exit 1; }
[ -d "$INC_SRC" ] || { echo "Include folder not found: $INC_SRC"; exit 1; }

EDITOR_EXE="$(find "$WINEPREFIX/drive_c" -iname 'MetaEditor64.exe' 2>/dev/null | head -n1)"
[ -n "$EDITOR_EXE" ] || { echo "MetaEditor64.exe not found under $WINEPREFIX/drive_c"; exit 1; }

mapfile -t MQL5_DIRS < <(find "$WINEPREFIX/drive_c" -type d -path '*/MQL5/Experts' -printf '%h\n' 2>/dev/null)
[ "${#MQL5_DIRS[@]}" -gt 0 ] || { echo "No MQL5 folder found. Start MT5 once first."; exit 1; }

compile() {   # $1 = .mq5 file, $2 = MQL5 folder
  local src="$1" mql5="$2" base="${1%.mq5}"
  rm -f "$base.ex5" "$base.log"
  local win_src win_mql5
  win_src="$("$WINE" winepath -w "$src" 2>/dev/null | tr -d '\r')"
  win_mql5="$("$WINE" winepath -w "$mql5" 2>/dev/null | tr -d '\r')"
  "$WINE" "$EDITOR_EXE" /compile:"$win_src" /inc:"$win_mql5" /log >/dev/null 2>&1 || true
  if [ -f "$base.ex5" ]; then
    echo "    $(basename "$src"): compiled OK"
  else
    echo "    $(basename "$src"): NOT compiled here. Open it in MetaEditor and press F7."
    if [ -f "$base.log" ]; then
      iconv -f UTF-16LE -t UTF-8 "$base.log" 2>/dev/null | grep -Ei 'error|warning|result' || true
    fi
  fi
}

for mql5 in "${MQL5_DIRS[@]}"; do
  echo "==> $mql5"
  mkdir -p "$mql5/Include/XAUScalper" "$mql5/Scripts/XAUScalper"
  # remove files of the old strategies (v6 and earlier)
  rm -f "$mql5/Include/XAUScalper/"{Strat,Strategy,Regime,Levels,Filters,Common}*.mqh \
        "$mql5/Scripts/XAUScalper/StrategyTests."* 2>/dev/null || true
  cp "$INC_SRC"/*.mqh "$mql5/Include/XAUScalper/"
  cp "$EA_SRC" "$mql5/Experts/XAUScalper.mq5"
  cp "$TEST_DIR"/*.mq5 "$mql5/Scripts/XAUScalper/"
  mkdir -p "$mql5/Profiles/Tester"
  cp "$REPO_DIR"/tools/presets/*.set "$mql5/Profiles/Tester/" 2>/dev/null || true
  echo "    files copied"
  compile "$mql5/Experts/XAUScalper.mq5" "$mql5"
  for t in "$mql5"/Scripts/XAUScalper/*.mq5; do compile "$t" "$mql5"; done
done

echo
echo "Next: in MetaEditor compile (F7) Experts/XAUScalper.mq5,"
echo "then re-attach XAUScalper to ONE XAUUSD M1 chart."
