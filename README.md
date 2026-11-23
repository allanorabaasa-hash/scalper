# scalper

MetaTrader 5 Expert Advisor for **gold (XAUUSD) and bitcoin (BTCUSD)** that trades **market
structure only, no indicators**, with an on-chart control panel. Runs on Kali Linux through a portable Wine staging build.
Previous strategies are in git history only.

## Strategy (v19.20): M1 market structure, pullback entries + real ticks

Everything is read on the **M1** chart, closed candles only, no indicators.

**Reading the chart: major structure.** On every closed M1 candle the bot reads the last 300
candles left to right like a trader. Swing points are candles higher (lower) than the 3 candles
on each side. In an UP structure the impulse runs to its high; once a swing high forms there,
the pullback has started; a close above that high is a continuation (break of structure) and
the pullback's low becomes the **protected low**. Only a close below the protected low shifts
the structure DOWN. Pullbacks, however deep and however many small swings they break, do not
change the structure: they are what the bot trades. DOWN is mirrored.

**Entries: pullbacks only, never chasing a break.**
1. A break of structure (or a shift) sets the side; the move after it is the impulse.
2. After a batch closes, only a break that happens **after** that close can be traded: no
   re-entry on the same move, the bot waits for a clear new setup.
3. It waits for the **pullback**: price gives back at least **38%** of the impulse (measured from
   the swing that held before the break to the impulse's extreme) without breaking that swing.
4. It waits for the **turn**: a closed candle in the trend's direction that closes beyond the
   previous candle's high (buys) / low (sells), starting from the pullback zone.
5. It enters on the next tick if the real ticks agree. A confirmed setup stays valid for **3
   candles** (time for the tick check, or for MT5 to reconnect), unless price has already run
   more than 0.5 x the stop past the turn candle (no chasing). Stop beyond the pullback's extreme by the
   spread + **half an average candle** (average high-low of the last 20 M1 candles), so normal
   wicks do not hit it.

Filters against ranges (candle sizes only, no indicators):
- **Real moves only:** the move behind the setup must be at least **4 average candles** long;
  small breaks inside a sideways market are ignored.
- **No trading spikes:** if the move contains a candle more than **4x** the normal candle size
  (the average of the 50 candles before the move), or one appeared in the last **30** candles,
  the bot does not trade it: vertical news / liquidation spikes are not trends, and their
  pullbacks tend to keep going. It waits for normal structure.
- **No buying the top / selling the bottom:** no buy within one average candle of the highest
  high of the last **60** candles; no sell within one average candle of the lowest low. In a
  trend the recent high is the impulse's own high, so this filter only applies when the high
  is older than the current move (a real range top).

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
| **Beast** | 5 positions | +5 | back to 5 |

**Daily target per mode:** Slow **5%**, Regular **7%**, Beast **10%** of the account's equity at
the start of the broker's day (all symbols, closed + open). Once reached, no new batches until
the next day; a batch that is open keeps its stops and partials. Inputs, 0 = off. The panel's
DAY P/L tile shows the result against the target (e.g. `+8.20 / +15.00`).

Default mode (input *Mode* = Auto): **gold Slow, bitcoin Beast**, other symbols Regular. The
panel buttons still switch it.

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

**Partial profits, on the broker's server.** Each position of a batch gets its own take profit
when it is opened: about **40% at TP1 (0.7R)**, **40% at TP2 (2R)**, the rest at **TP3 (3R)**
(1 position: TP2; 2: TP1 + TP3; 5: 2 / 2 / 1; 10: 4 / 4 / 2). These close on the broker's
server, so profits are taken even when the power, the PC, MT5 or the internet is off.
While MT5 is online the bot also protects what is left: at TP1 every remaining stop moves to
the entry; at TP2 to TP1. A touch missed while offline is caught up on reconnect (best price
since entry); if price is already back past that level, the rest is closed at market.

Batch of 5, result in R per position: straight to TP3 **+8.4R**; reaches TP2 then back to the
stop with MT5 offline **+4.4R** (online: +6.1R); reaches only TP1 then back to the stop offline
**-1.6R** (online, at breakeven: +1.4R); never reaches TP1 **-5R**.

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
