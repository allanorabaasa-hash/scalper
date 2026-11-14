# scalper

MetaTrader 5 Expert Advisor for XAUUSD with an on-chart control panel, plus a Python backtest
with the same rules. Runs on Kali Linux through a portable Wine staging build. Previous
strategies are in git history only.

## Strategy (v13.00): Controlled Grid for Gold or Bitcoin

Input **Market**: *Auto* (from the chart symbol), *Gold* or *Bitcoin*. Each market has its own
settings. Attach the bot to the chart of the market you want; attach it to both charts to run
both (each trades only when its own daily trend is valid; they share the account's margin and
the daily loss limit; STOP on one chart does not stop the other).

| Rule | Gold (XAUUSDm) | Bitcoin (BTCUSDm) |
|---|---|---|
| Direction | Daily EMA 21 vs EMA 55 of that symbol; no new grid if flat or crossing | same |
| Lot per level (fixed) | 0.01 | 0.02 |
| Grid spacing | $3 move | $150 move |
| Max levels | 8 | 8 |
| Each position: take profit | +$4 (a $4 move) | +$4 (a $200 move) |
| Each position: loss cut | -$3 (a $3 move) | -$3 (a $150 move) |
| Basket take profit / hard stop | +$12 / -$18 | +$12 / -$18 |
| Daily loss limit | 4% | 4% (shared) |

Bitcoin moves about 50x more than gold in dollars, so the Bitcoin settings are scaled to its
size: the money per win and per loss is the same as on gold. With 0.01 lot and the gold
settings, BTC's $6 spread was larger than the $3 spacing and all 8 levels opened at once. A
guard now blocks new positions whenever the spread is more than half the spacing.

Every position carries its own TP and loss cut on the broker's server, so they work even when
MT5 or the internet is down. The basket rules need MT5 running.

Notes on how the rules interact (no rule changed):
- Each position is cut early, so the floating loss rarely reaches -$18; but cut losses add up:
  a grid that uses all 8 levels against the trend can lose 8 x $3 = **$24** (8 x $5 = $40 at a -$5 cut).
- With +$4 wins and -$3 cuts, positions need to win more than 3 / 7 = **43%** (56% at -$5).
- Compare cut sizes in the Strategy Tester with `grid_cut5.set`, `grid_cut4.set`, `grid_cut3.set`, `grid_cut2.5.set`.
- A position at +$4 closes before the basket can reach +$12, so the basket TP fires rarely.

## MT5 setup (Kali + Wine)

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

MetaEditor (F4), F7 on `Experts/XAUScalper.mq5` and `Scripts/XAUScalper/ExportBars.mq5`.
Attach **XAUScalper** to one XAUUSDm chart (any timeframe), tick *Allow Algo Trading*, turn on
**Algo Trading**. Strategy Tester presets: `tools/presets/grid.set` (gold), `tools/presets/btc.set` (bitcoin).

## Python backtest

1. In MT5 run **ExportBars** on the XAUUSDm chart and on the BTCUSDm chart (timeframe M1). It writes `XAUUSDm_M1.csv`
   and `XAUUSDm_D1.csv` to Common/Files.
2. ```bash
   COMMON=$(find ~/.mt5/drive_c/users -type d -path '*MetaQuotes/Terminal/Common/Files' | head -1)
   python3 tools/backtest_grid.py --bars "$COMMON/XAUUSDm_M1.csv" --daily "$COMMON/XAUUSDm_D1.csv"
   python3 tools/backtest_grid.py ... --daily-loss 0 --from 2026-08-01 --grids-out grids.csv
   python3 tools/backtest_grid.py --market btc --bars "$COMMON/BTCUSDm_M1.csv" --daily "$COMMON/BTCUSDm_D1.csv"
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
tools/presets/grid.set, btc.set    Strategy Tester presets
scripts/                           install, start/stop MT5, auto-start
```
