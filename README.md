# scalper

MetaTrader 5 Expert Advisor for XAUUSD: **Controlled Directional Grid**, with an on-chart control
panel and a Python backtest with the same rules. Runs on Kali Linux through a portable Wine
staging build. Previous strategies are in git history only.

## Strategy (v10.00)

| Rule | Setting (input) |
|---|---|
| Direction | Daily EMA 21 > EMA 55: buy grids only; below: sell grids only (last completed daily candles) |
| No new grid | daily EMAs crossing (gap changed sign) or flat (gap < 0.10 x daily ATR 14) |
| Grid | first 0.01 position at once; one more 0.01 every **$4.50** against the grid; max **5** levels; lot never increased |
| Basket take profit | total floating profit **+$20**: close all |
| Basket stop | total floating loss **-$30** (6% of $500): close all |
| Hard stop | price **$18** beyond the last level: close all |
| One grid | one grid at a time, never opposite grids |
| Daily loss limit | day down **4%** (closed + open): no new grid until the next server day |
| Continuous | a new grid starts right after each close, until you press STOP |

**Why the -$30 basket stop:** 0.01 lot of gold = $1 per $1. Five levels $4.50 apart with the hard
stop $18 beyond level 5 lose $18 + 22.5 + 27 + 31.5 + 36 = **$135 (27%)**. The basket stop keeps
the worst grid at about $30 (6%); in practice it closes the grid soon after level 4 fills, so
level 5 and the $18 hard stop are rarely reached. Set *Basket stop* to 0 to run the rules
without it. Note: one basket stop (-$30) is more than the 4% daily limit ($20), so after a
losing grid the bot waits for the next day.

The EA refuses new trades on a REAL account unless *Allow trading on a REAL account* is on.

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
   python3 tools/backtest_grid.py ... --basket-stop 0        # rules as written, no -$30 stop
   python3 tools/backtest_grid.py ... --from 2026-08-01 --grids-out grids.csv
   python3 -m unittest tools/test_backtest_grid.py
   ```

Inside a candle the backtest assumes the worst extreme comes first (conservative), and charges
the spread (`--spread`, default 0.25).

## Panel

START, STOP (no new grids or levels; the open grid still closes at TP or stops), CLOSE ALL,
EMERGENCY. Shows balance, equity, day P/L against the 4% limit, grid floating P/L, daily trend,
the next level or hard-stop price, grid levels, and why the bot is waiting.

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
