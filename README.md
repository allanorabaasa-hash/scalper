# scalper

MetaTrader 5 Expert Advisor for XAUUSD that trades **market structure only, no indicators**,
with an on-chart control panel. Runs on Kali Linux through a portable Wine staging build.
Previous strategies are in git history only.

## Strategy (v14.00)

**Side (H1 structure).** Swing points: a candle whose high (low) is above (below) the 3 candles
on each side. Higher highs + higher lows, and price above the last higher low = **buy side**.
Lower highs + lower lows, and price below the last lower high = **sell side**. Anything else =
range / unclear: no trade.

**Entry (M15 pullback + break of structure).** On the buy side the bot waits for a pullback
(M15 makes a lower high). The first M15 close back above that lower high is the entry: the
pullback is over and the trend resumes. Sell side mirrored.

**Stop and target.** Stop below the pullback's lowest low (above the highest high for sells)
plus spread and a small buffer: where the idea is wrong. Target 2 x the stop distance (2R).
At +1R every position's stop moves to entry (breakeven). Trades are skipped when the stop is
closer than 0.03% or wider than 0.40% of price (gold: about $1.2 / $16), or the spread is more
than 25% of the stop.

**Batches.** Each entry opens a batch of 0.01 positions with the same stop and target.
First batch **5**. Batch closed in profit -> next batch **+5** (10, 15, 20 max).
Batch closed at a loss -> back to **5**. One batch at a time. Safety cap: a batch never risks
more than **15%** of the balance at its stop (fewer positions if needed; input, 0 = off).

**News (high-impact USD, MT5 calendar).**
- 15 min before a release: no new entries; positions in profit move their stop to breakeven.
- After the release (30 min): the range of the 15 minutes before it is the box; the first M1
  close outside the box opens a batch in that direction, stop at the other side of the box.
- The calendar works only live, not in the Strategy Tester.

No daily loss limit. Emergency close-all below 100% margin level. Auto-start whenever MT5 is
connected (STOP is remembered per chart). Refuses new trades on a REAL account unless allowed.

## Setup

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

MetaEditor (F4), F7 on `Experts/XAUScalper.mq5`. Attach **XAUScalper** to one XAUUSDm chart
(any timeframe), tick *Allow Algo Trading*, turn on **Algo Trading**.
On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

**Test first:** Strategy Tester, XAUScalper, XAUUSDm, M1, custom period, *Every tick based on
real ticks*, deposit 500, preset `tools/presets/structure.set`.

## Panel

START, STOP (no new batches; open positions keep their SL / TP), CLOSE ALL, EMERGENCY. Shows
balance, equity, day and open P/L, next batch size, next high-impact news, the H1 structure,
the M15 swing high/low, the last batch result, positions with SL / TP, and why it is waiting.

## Layout

```
src/XAUScalper.mq5                 EA: structure, batches, news, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (day stats, emergency), execution, journal
src/Scripts/ExportBars.mq5         exports bars to CSV
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/structure.set        Strategy Tester preset
scripts/                           install, start/stop MT5, auto-start
```
