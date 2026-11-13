# scalper

XAUUSD Expert Advisor for MetaTrader 5 with one strategy: **grid waves**. Runs on Kali Linux
through a portable Wine staging build, with an on-chart control panel.

> **Demo and Strategy Tester only.** Positions have no stop loss and losing positions are held,
> so a strong one-way move can lead to a margin call. The EA refuses to open positions on a REAL
> account.

## Strategy (defaults = the user's settings)

- No indicators: trading starts as soon as the EA is running and connected.
- Fixed lot **0.01** per position.
- Waves of **10, then 15, then 20** positions (20 repeats), half buys and half sells, opened together.
- Each position closes as soon as its profit reaches **+0.50**. Losing positions are held until
  they turn profitable.
- The next wave opens when **50%** of the current wave has closed in profit.
- Limits: max **60** open positions; no new positions below **300%** margin level or above
  **0.40** spread; emergency close-all below **100%** margin level.
- Optional (off by default): max holding time (`InpMaxHoldMin`) and basket stop
  (`InpBasketStopPct`, close all when equity is that % below balance).

Every setting is an input; `tools/presets/grid_user.set` holds the same values.
The previous indicator strategies (v6.10) are in git history at commit `2472c77`.

## Layout

```
src/XAUScalper.mq5                 EA: grid engine, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager, execution, journal
tests/RiskTests.mq5                risk maths unit tests (MT5 script)
tools/analyze_trades.py            performance report from the journal (+ unit tests)
tools/presets/grid_user.set        Strategy Tester preset
scripts/                           install, start/stop MT5, auto-start
```

## Setup (Kali + Wine)

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

In MetaEditor (F4 in MT5) open `Experts/XAUScalper.mq5` and compile with F7. Attach
**XAUScalper** to **one** XAUUSD (e.g. `XAUUSDm`) M1 chart, tick *Allow Algo Trading*, and turn
on the **Algo Trading** toolbar button. With auto-start on, wave 1 opens immediately.

## Panel

START, STOP (no new positions; open ones still close at +0.50), CLOSE ALL, EMERGENCY (close all,
lock until the next trading day). Shows balance, equity, day and floating P/L, spread, margin
level, the current wave, open positions (close button per row) and why the bot is not trading.

## Auto-start

The EA starts by itself whenever MT5 is connected. STOP or EMERGENCY is remembered until you press
START. On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

## Journal

`.../MetaQuotes/Terminal/Common/Files/XAUScalper_trades.csv` (tester:
`XAUScalper_tester_trades.csv`).

```bash
python3 tools/analyze_trades.py "<Common/Files>/XAUScalper_trades.csv" --mode demo
```
