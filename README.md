# scalper

XAUUSD scalping Expert Advisor for MetaTrader 5, with an on-chart control panel.
Runs on Kali Linux through a portable Wine staging build.

> **Status:** Momentum Burst strategy v1. Test in the Strategy Tester and on a **demo account** first.

## Strategy 1 (default): Trend Pullback

Trades with the trend after a pullback, the way discretionary gold scalpers do,
with the stop where the setup is proven wrong instead of a fixed distance.

1. **Trend** (M15): EMA 50 rising and price above it = uptrend (falling and below = downtrend).
   No clear trend = no trades.
2. **Pullback** (M5): within the last 5 bars price dipped back to the EMA 20.
3. **Resumption**: the last closed M5 bar closes back beyond the EMA 20, in the trend direction,
   and breaks the previous bar's high (low). Entry at market.
4. **Stop** beyond the pullback swing plus 0.2 x ATR (skipped if wider than 2 x ATR).
   **Take profit** 1.5 x risk. **Breakeven** once price is 1 x risk in profit.
5. **Filters**: quiet markets (ATR < 0.80), spread above 15% of the stop, and the rollover hours
   (server 21:00-23:00) are skipped. One trade at a time.

Each trade risks a fixed % of balance, so the payoff is: win = +1.5R, loss = -1R.
It is profitable with a win rate above 40%, before costs.

The panel footer explains what it is waiting for (no trend / waiting for pullback / waiting for resumption).

## Strategy 2: Momentum Burst

No indicators, only raw ticks.

1. **Burst detection**: over the last `Burst window` (3 s), price moved at least
   `max(3 x spread, 0.50)` and at least 70% of tick changes went the same way.
2. **Entry** in the burst direction.
3. **Stacking**: add up to `Max stack` (3) positions in the same direction, but only while the
   newest one is already `+0.30` in profit. Never adds to a loser.
4. **Reverse**: an opposite burst closes everything and opens the other way.
5. **Fast exits**: hard SL (1.50) and TP (1.50) on every order, breakeven at +0.30,
   trailing stop from +0.50 (0.30 behind price), and every trade is closed after 20 s.
6. **Brakes**: spread filter, cooldown (2 s), max 20 trades/minute, daily loss limit.

### Profiles

Switch with the strategy button on the panel: PULLBACK -> BURST SAFE -> BALANCED -> AGGRESSIVE -> CUSTOM. The trade journal records which
profile opened each trade.

| | Safe | Balanced | Aggressive |
|---|---|---|---|
| Burst window | 3.0 s | 2.0 s | 1.5 s |
| Move needed | 3x spread, min 0.50 | 2.5x spread, min 0.40 | 2x spread, min 0.30 |
| Min ticks / direction share | 6 / 70% | 5 / 68% | 4 / 65% |
| Max stack | 2 | 3 | 5 |
| Cooldown / max per minute | 3 s / 10 | 1 s / 20 | none / 40 |
| Breakeven / trail start / trail distance | 0.30 / 0.50 / 0.30 | 0.25 / 0.40 / 0.25 | 0.20 / 0.30 / 0.20 |
| Max hold | 20 s | 15 s | 10 s |

*Custom* uses the values from the inputs.

### Trade journal

Every entry and exit is written to `MQL5/Files/XAUScalper_journal.csv`
(entry: burst size, spread, tick count, direction share; exit: profit, hold time, exit reason).
This is the data used to tune the profiles.

The panel footer shows the live burst meter: the current move vs. what is needed to trigger.
All numbers are inputs, so tune them in the Strategy Tester.

### Strategy Tester

The EA starts automatically in the tester. Use *Every tick based on real ticks*, set a
*Delay* similar to your real ping (e.g. 200 ms), and test several weeks of XAUUSD.

## The panel

```
┌──────────────────────────────────────────────────────┐
│ XAU SCALPER                              [ RUNNING ] │
│ Account 1234567 | Exness-MT5Trial | XAUUSDm | Magic  │
│ BALANCE        EQUITY          TODAY P/L             │
│ FLOATING P/L   SPREAD          SESSION               │
│ [START] [STOP] [CLOSE ALL]           [BUY] [SELL]    │
│ OPEN POSITIONS (n)                                   │
│ TICKET  TYPE  LOTS  OPEN   SL   TP        P/L   [X]  │
│ ...                                                  │
│ last action message                                  │
│ why the bot is / isn't trading right now             │
└──────────────────────────────────────────────────────┘
```

| Control | What it does |
|---|---|
| **START** | Bot begins looking for trades (when all safety checks pass) |
| **STOP** | No new trades. Open positions keep their SL/TP |
| **CLOSE ALL** | Closes every position this EA opened on the chart's symbol (asks to confirm) |
| **BUY / SELL** | Manual test trade using the EA's lot sizing and SL/TP |
| **X** on a row | Closes that one position |

Status: `STOPPED`, `RUNNING`, `PAUSED` (after a connection drop), `LOCKED` (daily limit hit), `OFFLINE` (no broker connection).

## Safety built in

- Every order is sent **with a stop loss** (the broker holds it, so it works even if the PC is off).
- Trades **any time** by default. Optional session hours (PC local time) with close-at-session-end.
- **Daily loss limit** (default 3%) and optional daily profit target: closes all, stops, locks until the next day.
- **Spread filter**, **max open positions**, **cooldown** between trades.
- **Connection drop**: no trades while offline; after reconnecting the bot goes to `PAUSED` until you press START.
- Always starts as `STOPPED` when MT5 opens (e.g. after a power cut).

## Setup (Kali + Wine)

Wine: portable Wine staging 11.21 in `~/wine-staging`, MT5 prefix in `~/.mt5`.

```bash
git clone https://github.com/allanorabaasa-hash/scalper.git ~/scalper
cd ~/scalper
chmod +x scripts/*.sh
./scripts/install.sh      # copies + compiles the EA into every MT5 install
```

If `install.sh` can't compile, open `src/XAUScalper.mq5` in MetaEditor (F4 in MT5) from
`MQL5/Experts` and press **F7**.

In MT5:
1. Turn on the **Algo Trading** button in the toolbar.
2. Open an **XAUUSD** chart (any timeframe, M1 recommended).
3. Navigator → Expert Advisors → drag **XAUScalper** onto the chart.
4. **Common** tab: tick *Allow Algo Trading*. **Inputs** tab: adjust settings. OK.
5. Press **START** on the panel.

Daily routine: `./scripts/start.sh` in the morning, press START on each panel;
in the evening press STOP (the EA also closes at session end), then `./scripts/stop.sh`.

## Small accounts ($10 and up)

Use an **Exness Standard Cent** account (gold symbol usually `XAUUSDc`). Balances are in
US cents, so $10 shows as 1,000 USC and the minimum lot is 100x smaller than on a
Standard account. On a Standard account the minimum 0.01 lot loses $1.50 per stop-out,
which is 15% of a $10 account.

The EA protects small accounts by:
- sizing every trade from **Risk %** of balance (default 1%),
- using the minimum lot only if its risk stays under **5%**, otherwise skipping the trade,
- never using more than half the free margin,
- the daily loss limit.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| Lot mode | Risk % | Fixed lots, or size by % of balance |
| Risk % per trade | 1.0 | Used in Risk % mode |
| Max risk at min lot | 5.0 | Small accounts: min lot allowed only up to this risk |
| Margin buffer | 50 | % of free margin always kept unused |
| Stop loss distance | 2.00 | Price distance (2.00 = $2 move in gold) |
| Take profit distance | 2.00 | 0 = none |
| Max spread | 0.35 | In price; skips trades when wider |
| Max daily loss % | 3.0 | 0 = off |
| Use session | false | true = only trade between the session hours (PC local time) |
| Magic number | 20261112 | Use a different one per EA/chart if running more than one |

Only positions opened by this EA (same symbol + magic number) appear in the panel and are counted.

## Multiple accounts

Make one portable copy of MT5 per account in `~/.mt5/drive_c/MT5/Acc1`, `Acc2`, ...,
log into a different account in each, run `./scripts/install.sh` (it finds every copy),
and attach the EA in each terminal. `start.sh` launches all copies.
