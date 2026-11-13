# scalper

MetaTrader 5 Expert Advisor for XAUUSD (works on any symbol) with an on-chart control panel,
plus a Python backtester with the same rules. Runs on Kali Linux through a portable Wine
staging build.

## Basket mode (default, v9.00)

Modelled on the "gold trading, automated" bot from the video (its code is not public; this
copies the behaviour visible in it). Demo only: positions have no individual stop loss.

| Rule | Default |
|---|---|
| Direction | on each new M5 bar: EMA 21 above EMA 55 and close above EMA 21 = BUY; mirror = SELL; else wait |
| Basket | 10 positions, all in that direction, opened together when no basket is open |
| Lot | 0.01 per position for every $200 of balance (compounds as the balance grows), max 5 lots |
| Exit | the whole basket closes together at **+4%** of the balance, or at **-8%** (loss limit) |
| Guard | no more positions below 300% margin level or without free margin; emergency close-all below 100% |

With $500: 0.02 lot x 10 = 0.20 lot, about $20 per $1 move in gold: the basket closes at
+$20 (about $1 in your favour) or -$40 (about $2 against). All are inputs.

*Mode = EMA 21/55 trend* switches to the strategy below.

## Strategy: EMA 21/55 trend

| Rule | Setting |
|---|---|
| Timeframe | input `InpTF`: **M5** by default; M1 or H4 (the original) also possible |
| Long | EMA 21 crosses above EMA 55 on a closed candle, and the candle closes above both EMAs: buy at that close |
| Short | EMA 21 crosses below EMA 55 on a closed candle, and the candle closes below both EMAs: sell at that close |
| Daily filter | only in the direction of the last completed D1 candle's EMA 21 vs EMA 55 |
| ATR filter | skip when ATR(14) is below 50% of its 100-bar average ("extremely low"; input) |
| Stop | 1.5 x ATR(14) of the signal candle, on the broker's server |
| Trailing | once the best price is 1 x ATR in profit, the stop follows it at 2 x ATR (never moves back) |
| Exit | stop / trailing stop, or an opposite signal. No take profit |
| Size | 1% of equity at the stop. If even the minimum lot (0.01) risks more than 1%, the trade is **skipped** |

One position at a time per symbol. The panel shows the daily trend, ATR, both EMAs, the last
signal and whether it was taken or why it was skipped.

**Minimum lot on a $500 account:** 1% = $5. With 0.01 lot of gold, $1 of price = $1, so a stop
wider than $5 (ATR above about 3.3) cannot be sized at 1% and the signal is skipped. On H4 the
ATR is far larger, so on a $500 Standard account almost every H4 signal is skipped; M1/M5 stops
are small enough most of the time.

The previous strategies are in git history: grid waves at commit `9b08219`/v7.10, indicator
strategies at `2472c77`.

## Python backtest

`tools/backtest_ema_trend.py` (pandas + numpy only) uses exactly the same rules.

1. In MT5, run the script **ExportBars** on the XAUUSDm chart (choose M5, M1 or H4). It writes
   `XAUUSDm_M5.csv` and `XAUUSDm_D1.csv` to the Common/Files folder:
   ```bash
   COMMON=$(find ~/.mt5/drive_c/users -type d -path '*MetaQuotes/Terminal/Common/Files' | head -1)
   ```
2. Run:
   ```bash
   python3 tools/backtest_ema_trend.py --bars "$COMMON/XAUUSDm_M5.csv" --daily "$COMMON/XAUUSDm_D1.csv"
   python3 tools/backtest_ema_trend.py --bars "$COMMON/XAUUSDm_M5.csv" --daily "$COMMON/XAUUSDm_D1.csv" \
           --from 2026-08-01 --trades-out trades.csv
   python3 tools/backtest_ema_trend.py --demo      # synthetic prices: checks the code runs
   python3 -m unittest tools/test_backtest_ema_trend.py
   ```
   Options: `--balance 500 --risk 1 --spread 0.25 --min-atr-ratio 0.5 --from --to`.

It prints trades, net profit, return, win rate, profit factor, average win/loss, expectancy
($ and R), max drawdown, max losses in a row, exits by reason, results by side, and how many
signals were skipped and why.

## MT5 setup (Kali + Wine)

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

In MetaEditor (F4) compile with F7: `Experts/XAUScalper.mq5` and `Scripts/XAUScalper/ExportBars.mq5`.
Attach **XAUScalper** to one XAUUSDm chart (any chart timeframe; the EA uses `InpTF`), tick
*Allow Algo Trading*, turn on **Algo Trading**. Strategy Tester presets: `tools/presets/ema_trend_*.set`.

The EA refuses new trades on a REAL account unless *Allow trading on a REAL account* is on.

## Panel

START, STOP (no new trades; the open trade keeps its stop and trailing), CLOSE ALL, EMERGENCY
(close all, lock until the next trading day). Balance, equity, day P/L, daily trend, ATR, spread,
EMAs, last signal, open positions with their stop, and why the bot cannot trade.

## Auto-start

The EA starts by itself whenever MT5 is connected; STOP or EMERGENCY is remembered until START.
On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

## Journal

`.../MetaQuotes/Terminal/Common/Files/XAUScalper_trades.csv` (tester:
`XAUScalper_tester_trades.csv`); `python3 tools/analyze_trades.py <file> --mode demo`.

## Layout

```
src/XAUScalper.mq5                 EA: strategy, trailing, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (sizing, emergency), execution, journal
src/Scripts/ExportBars.mq5         exports bars to CSV for the Python backtest
tools/backtest_ema_trend.py        Python backtest (+ tests)
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/ema_trend_*.set      Strategy Tester presets (M1, M5, H4)
tests/RiskTests.mq5                risk maths unit tests
scripts/                           install, start/stop MT5, auto-start
```
