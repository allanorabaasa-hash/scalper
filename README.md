# scalper

MetaTrader 5 Expert Advisor for XAUUSD with an on-chart control panel, plus a Python backtest
with the same rules. Runs on Kali Linux through a portable Wine staging build. Previous
strategies are in git history only.

## Strategy (v12.00): Controlled Grid with early profits and early loss cuts

| Rule | Setting (input) |
|---|---|
| Direction | Daily EMA 21 > EMA 55: buy grids only; below: sell grids only (last completed daily candles) |
| No new grid | daily EMAs crossing or flat (gap < 0.10 x daily ATR 14) |
| Grid | first 0.01 position at once; one more 0.01 every **$3.00** against the last level; max **8** levels; lot never increased |
| Individual take profit | each position closes at **+$4** (set on the broker's server) |
| Early loss cut | each position closes at **-$5**, that position only (set on the broker's server) |
| Basket take profit | total floating **+$12**: close all |
| Hard basket stop | total floating **-$18**: close all |
| Grid end | when it has no open positions; the next grid starts right away, until STOP |
| One grid | one at a time, never opposite |
| Daily loss limit | day down **4%** (closed + open): no new grid until the next server day |

Every position carries its own TP and loss cut on the broker's server, so they work even when
MT5 or the internet is down. The basket rules need MT5 running.

Notes on how the rules interact (no rule changed):
- Each position is cut at -$5, so the floating loss rarely reaches -$18; but cut losses add up:
  a grid that uses all 8 levels against the trend can lose 8 x $5 = **$40 (8%)**.
- With +$4 wins and -$5 cuts, positions need to win more than 5 / 9 = **56%** (plus spread).
- A position at +$4 closes before the basket can reach +$12, so the basket TP fires rarely.

## MT5 setup (Kali + Wine)

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

MetaEditor (F4), F7 on `Experts/XAUScalper.mq5` and `Scripts/XAUScalper/ExportBars.mq5`.
Attach **XAUScalper** to one XAUUSDm chart (any timeframe), tick *Allow Algo Trading*, turn on
**Algo Trading**. Strategy Tester preset: `tools/presets/grid.set`.

## Python backtest

1. In MT5 run **ExportBars** on the XAUUSDm chart (timeframe M1). It writes `XAUUSDm_M1.csv`
   and `XAUUSDm_D1.csv` to Common/Files.
2. ```bash
   COMMON=$(find ~/.mt5/drive_c/users -type d -path '*MetaQuotes/Terminal/Common/Files' | head -1)
   python3 tools/backtest_grid.py --bars "$COMMON/XAUUSDm_M1.csv" --daily "$COMMON/XAUUSDm_D1.csv"
   python3 tools/backtest_grid.py ... --daily-loss 0 --from 2026-08-01 --grids-out grids.csv
   python3 -m unittest tools/test_backtest_grid.py
   ```

Inside a candle the backtest assumes the worst extreme comes first (conservative), fires every
trigger in the order the price reaches it, and charges the spread (`--spread`, default 0.25).

## Panel

START, STOP (no new grids or levels; open positions keep their TP / loss cut), CLOSE ALL,
EMERGENCY. Shows balance, equity, day P/L, grid floating P/L, daily trend, grid level and the
next level price, positions with their TP / loss-cut prices, and why the bot is waiting.

## Auto-start

The EA starts by itself whenever MT5 is connected; STOP or EMERGENCY is remembered until START.
On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

## Layout

```
src/XAUScalper.mq5                 EA: grid engine, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (day stats, emergency), execution, journal
src/Scripts/ExportBars.mq5         exports bars for the Python backtest
tools/backtest_grid.py             Python backtest (+ tests)
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/grid.set             Strategy Tester preset
scripts/                           install, start/stop MT5, auto-start
```
