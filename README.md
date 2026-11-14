# scalper

MetaTrader 5 Expert Advisor for **gold (XAUUSD) and bitcoin (BTCUSD)** that trades **market
structure only, no indicators**, with an on-chart control panel. Runs on Kali Linux through a portable Wine staging build.
Previous strategies are in git history only.

## Strategy (v16.00): M1 market structure + real ticks

Everything is read on the **M1** chart, closed candles only, no indicators.

**Reading the chart.** On every closed candle (and as soon as the bot is attached) it scans the
last 300 candles left to right like a trader: swing points are candles higher (lower) than the
3 candles on each side; a close above the latest unbroken swing high is a bullish break, a close
below the latest unbroken swing low a bearish break. A break against the current structure is a
**shift** (change of character). Result: the current structure (UP / DOWN), when and where it
last broke or shifted, and the swing behind that break.

**Entries.**
- **Fresh break / shift:** if the structure broke or shifted in the last 3 candles (also when
  the bot is just attached to a chart that has already shifted), it trades it at once, as long
  as price has not run more than 0.5 x the stop past the broken level. Stop beyond the swing
  behind the break.
- **Continuation:** in an UP structure, the swing high made by the pullback after the break is
  armed; the live tick that breaks it triggers the buy, stop below the pullback's low. Mirrored.

**Real ticks (when available).** Before any entry, the ticks of the last 15 seconds must agree:
at least 60% of the price-changing ticks in the trade's direction and price moved that way. If
the broker or tester provides no tick data, the check is skipped instead of blocking trades.

**Stop and target.** Stop beyond the pullback's extreme (including the current candle) plus
spread and a small buffer. Target 2 x the stop distance (2R). At +1R every position's stop
moves to entry (breakeven). Trades are skipped when the stop is closer than 0.03% of price or
wider than 0.40% (gold) / 0.80% (bitcoin), or when the spread is more than 25% of the stop.
On M1, gold stops are typically $1.5-4 (0.01 lot: $1.5-4 per position).

**Batches.** Each entry opens a batch of 0.01 positions with the same stop and target.
First batch **5**. Batch closed in profit -> next batch **+5** (10, 15, 20 max).
Batch closed at a loss -> back to **5**. One batch at a time. Safety cap: a batch never risks
more than **15%** of the balance at its stop (fewer positions if needed; input, 0 = off).

**News (high-impact USD, MT5 calendar).**
- 15 min before a release: no new entries; positions in profit move their stop to breakeven.
- After the release (30 min): the range of the 15 minutes before it is the box; the first M1
  close outside the box opens a batch in that direction, stop at the other side of the box.
- The calendar works only live, not in the Strategy Tester.

**Gold or bitcoin.** The same bot works on both: attach it to an XAUUSDm chart, a BTCUSDm chart,
or both. All distances are in % of price or come from the chart's own swings, so nothing needs
converting. Each chart has its own batch size and its own STOP; both share the account's
margin. 0.01 lot of gold = $1 per $1 move; 0.01 lot of bitcoin = $0.01 per $1 move (a $300
BTC stop costs $3 per position). Bitcoin also trades at weekends.

No daily loss limit. Emergency close-all below 100% margin level. Auto-start whenever MT5 is
connected (STOP is remembered per chart). Refuses new trades on a REAL account unless allowed.

## Setup

```bash
cd ~/scalper && git pull
./scripts/install.sh
```

`install.sh` also removes the files and Tester presets of all earlier versions from MT5.
MetaEditor (F4), F7 on `Experts/XAUScalper.mq5`. Attach **XAUScalper** to one XAUUSDm and/or
one BTCUSDm chart (any timeframe), tick *Allow Algo Trading*, turn on **Algo Trading**.
On Kali, `./scripts/install-autostart.sh` starts MT5 at login once the internet is up.

**Test first:** Strategy Tester, XAUScalper, XAUUSDm, M1, custom period, *Every tick based on
real ticks*, deposit 500. Gold: symbol XAUUSDm, preset `structure_gold.set`. Bitcoin: symbol
BTCUSDm, preset `structure_btc.set`. Results go in `docs/VALIDATION.md`.

## Panel

START, STOP (no new batches; open positions keep their SL / TP), CLOSE ALL, EMERGENCY. Shows
balance, equity, day and open P/L, next batch size, next high-impact news, the M1 structure
(and when it last broke or shifted), the armed level, the real-tick reading, the last batch result, positions with SL / TP, and why it is waiting.

## Layout

```
src/XAUScalper.mq5                 EA: structure, batches, news, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (day stats, emergency), execution, journal
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/structure_*.set      Strategy Tester presets (gold, btc)
docs/VALIDATION.md                 test results log
scripts/                           install, start/stop MT5, auto-start
```
