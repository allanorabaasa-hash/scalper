# scalper

MetaTrader 5 Expert Advisor for **gold (XAUUSD) and bitcoin (BTCUSD)** that trades **market
structure only, no indicators**, with an on-chart control panel. Runs on Kali Linux through a portable Wine staging build.
Previous strategies are in git history only.

## Strategy (v18.20): M1 market structure, pullback entries + real ticks

Everything is read on the **M1** chart, closed candles only, no indicators.

**Reading the chart.** On every closed candle (and as soon as the bot is attached) it scans the
last 300 candles left to right like a trader: swing points are candles higher (lower) than the
3 candles on each side; a close above the latest unbroken swing high is a bullish break, a close
below the latest unbroken swing low a bearish break. A break against the current structure is a
**shift** (change of character). Result: the current structure (UP / DOWN), when and where it
last broke or shifted, and the swing behind that break.

**Entries: pullbacks only, never chasing a break.**
1. A break of structure (or a shift) sets the side; the move after it is the impulse.
2. After a batch closes, only a break that happens **after** that close can be traded: no
   re-entry on the same move, the bot waits for a clear new setup.
3. It waits for the **pullback**: price gives back at least **50%** of the impulse (measured from
   the swing that held before the break to the impulse's extreme) without breaking that swing.
4. It waits for the **turn**: a closed candle in the trend's direction that closes beyond the
   previous candle's high (buys) / low (sells), starting from the pullback zone.
5. It enters on the next tick if the real ticks agree. Stop beyond the pullback's extreme.

Swing points: on M1 the next candle often opens at a candle's extreme, so a newer candle may
equal a swing's high/low; older candles must be strictly beyond it.

**Real ticks (when available).** Before any entry, the ticks of the last 15 seconds must agree:
at least 60% of the price-changing ticks in the trade's direction and price moved that way. If
the broker or tester provides no tick data, the check is skipped instead of blocking trades.

**Stop and target.** Stop beyond the pullback's extreme (including the current candle) plus
spread and a small buffer. Target 2 x the stop distance (2R). At +1R every position's stop
moves to entry (breakeven). Trades are skipped when the stop is closer than 0.03% of price or
wider than 0.40% (gold) / 0.80% (bitcoin), or when the spread is more than 25% of the stop.
On M1, gold stops are typically $1.5-4 (0.01 lot: $1.5-4 per position).

**Modes and batches.** Each entry opens a batch of positions with the same stop and target, all
sent at once so they fill within about a second. Input **Mode**:

| Mode | First batch | After a winning batch | After a losing batch |
|---|---|---|---|
| Slow | 1 position | +1 | -1 (never below 1) |
| Regular | 2 positions | +2 | -2 (never below 2) |
| **Beast** (default) | 5 positions | +5 | back to 5 |

A batch that ends at about zero (breakeven exits, spread: within 20% of the batch's risk) is
neither a win nor a loss: the size stays the same, it never increases on a 0 result. Max 20
positions per batch; a batch never risks more than 15% of the balance at its stop (fewer
positions if needed). **Lot size** is an input (*Lot size per position*, default 0.01).
Changing the mode starts again from that mode's first size.

**Switch while running, on the panel:** the **SLOW / REGULAR / BEAST** buttons (the active one
is blue) and the **LOT** box with - / + (or type a lot and press Enter). Changes apply from the
next batch, are remembered across restarts, and are per chart and per account. A value changed
later in the EA's Inputs dialog takes over from the panel's.

**Risk : reward is strictly 1 : 3.** After each fill the target is set to exactly 3 x the real
distance between the fill price and the stop.

**Partial profits** (input *Smart exit*, on). TP1 = 0.7R, TP2 = 2R, TP3 = 3R (the target); TP1 and
TP2 are inputs.
1. Price touches **TP1**: every stop moves to its entry (breakeven).
2. Price bounces back through TP1 (by 0.1R): **half** the positions close there; the rest stay
   at breakeven.
3. Price reaches **TP2**: half of the remaining positions close; the rest's stop moves to TP1.
4. The remainder closes at **TP3**, or at **TP1** if price comes back.

Example, buy batch of 5 at 100, stop 98 (TP1 101.4, TP2 104, TP3 106), result in R per position:
straight to TP3 +13R; TP1, bounce, back to entry about +1.4R; TP1, bounce, TP2, TP3 about +9.4R; TP1,
bounce, TP2, back to TP1 about +4.8R; never reaches TP1 -5R. One position cannot be halved: in Slow
mode it is managed by the stops (entry at TP1, TP1 at TP2) and the TP3 target.

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

## Several accounts, each with its own mode

One MT5 terminal can be logged into one account at a time, so each extra account gets its own
portable copy of MT5:

```bash
./scripts/add-account.sh 2      # creates C:\MT5\Acc2 and opens it: log in to account 2 there
./scripts/add-account.sh 3      # and so on
./scripts/add-account.sh --list
```

Your normal MT5 is account 1. In every terminal attach XAUScalper and pick its own **Mode** and
**Lot size** (e.g. account 1 Beast, account 2 Regular, account 3 Slow). `start.sh` and the
login watchdog (`install-autostart.sh`) start every account's terminal when the internet is up
and restart any that closes; `install.sh` updates the EA in all of them; `stop.sh` closes all.

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

START, STOP (no new batches; open positions keep their SL / TP), CLOSE ALL, EMERGENCY, the mode
buttons and the lot box. Shows
balance, equity, day and open P/L, next batch size, next high-impact news, the M1 structure
(and when it last broke or shifted), the armed level, the real-tick reading, the last batch result, positions with SL / TP, and why it is waiting.

## Layout

```
src/XAUScalper.mq5                 EA: structure, batches, news, panel, journal hooks
src/Include/XAUScalper/*.mqh       risk manager (day stats, emergency), execution, journal
tools/analyze_trades.py            report from the EA journal (+ tests)
tools/presets/structure_*.set      Strategy Tester presets (gold, btc)
docs/VALIDATION.md                 test results log
scripts/                           install, add-account, start/stop MT5, auto-start
```
