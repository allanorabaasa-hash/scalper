# scalper

MetaTrader 5 Expert Advisor for XAUUSD with an on-chart control panel, plus a Python backtest
with the same rules. Runs on Kali Linux through a portable Wine staging build. Previous
strategies are in git history only.

## Strategy (v11.00)

| Rule | Setting (input) |
|---|---|
| Direction | Daily EMA 21 > EMA 55: buy only; below: sell only (last completed daily candles) |
| No new trade | daily EMAs crossing or flat (gap < 0.10 x daily ATR 14) |
| Trade | one **0.01** position at a time; **nothing is ever added to a losing position** |
| Take profit | **+$50** (a $50 move for 0.01 lot of gold), on the broker's server |
| Stop loss | **-$20** (a $20 move), on the broker's server: works even if MT5 or the internet is down |
| Repeat | a new trade opens right after each close, until you press STOP |
| Daily loss limit | **off** for testing (input *Daily loss limit %*, e.g. 4) |

Break-even needs a win rate above 20 / (20 + 50) = **29%** (a bit more after the spread).
The EA refuses new trades on a REAL account unless *Allow trading on a REAL account* is on.

## MT5 setup (Kali + Wine)

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

MetaEditor (F4), F7 on `Experts/XAUScalper.mq5` and `Scripts/XAUScalper/ExportBars.mq5`.
Attach **XAUScalper** to one XAUUSDm chart (any timeframe), tick *Allow Algo Trading*, turn on
**Algo Trading**. Strategy Tester preset: `tools/presets/trend.set`.

## Python backtest

1. In MT5 run **ExportBars** on the XAUUSDm chart (timeframe M1). It writes `XAUUSDm_M1.csv`
   and `XAUUSDm_D1.csv` to Common/Files.
2. ```bash
   COMMON=$(find ~/.mt5/drive_c/users -type d -path '*MetaQuotes/Terminal/Common/Files' | head -1)
   python3 tools/backtest_trend.py --bars "$COMMON/XAUUSDm_M1.csv" --daily "$COMMON/XAUUSDm_D1.csv"
   python3 tools/backtest_trend.py ... --tp 50 --sl 20 --daily-loss 4 --from 2026-08-01 --trades-out trades.csv
   python3 -m unittest tools/test_backtest_trend.py
   ```

When a candle touches both the stop and the target, the backtest assumes the stop came first
(conservative), and it charges the spread (`--spread`, default 0.25).

## Panel

START, STOP (no new trades; the open trade keeps its SL and TP), CLOSE ALL, EMERGENCY. Shows
balance, equity, day P/L, open P/L, daily trend, trades won/lost, the open position with its
stop loss and take profit, and why the bot is waiting.

## Auto-start

The EA starts by itself whenever MT5 is connected; STOP or EMERGENCY is remembered until START.
On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

## Layout

```
src/XAUScalper.mq5                 EA: trade engine, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (day stats, emergency), execution, journal
src/Scripts/ExportBars.mq5         exports bars for the Python backtest
tools/backtest_trend.py            Python backtest (+ tests)
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/trend.set            Strategy Tester preset
scripts/                           install, start/stop MT5, auto-start
```
