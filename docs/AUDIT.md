# Phase A: Audit of XAUScalper v3.0

Date: 2026-11-13. Code audited: `src/XAUScalper.mq5` at commit `9068df8` (1,926 lines).

## Scope and evidence

- **Codebase:** one MQL5 Expert Advisor (`src/XAUScalper.mq5`) plus shell scripts.
  There are no Python files, no database and no config files: settings are EA inputs,
  history comes from MT5, and trades are logged to `MQL5/Files/XAUScalper_journal.csv`.
- **Test evidence available:** two live demo results seen on the panel (Exness, XAUUSDm,
  spread about 0.24):
  - Burst strategy, $50 account: 48 trades, 31% winners, losing.
  - Burst strategy, $5,000 account: 50 trades, 32% winners, -39.45 for the day.
- **Not available yet:** no Strategy Tester backtest has been run, and the journal file was
  not reachable during this audit. **No strategy in the bot has statistical evidence of an edge.**
- The code could not be compiled here (MetaEditor runs on the user's PC). Findings are
  from reading the code; line numbers refer to the commit above.

## Summary

The bot's plumbing is mostly sound: every order carries a stop loss, STOP leaves positions
alone, it starts STOPPED after a restart, it uses real broker account data, and indicators
use closed candles. **The money is lost in the strategy layer and the risk defaults**: the
default strategy has no edge by construction, risk is not tied to equity, the daily loss
protection is switched off, and the small-account lot rule breaks the "never raise the lot
to the broker minimum" requirement.

## Findings

Severity: **Critical** = loses money or breaks a hard rule by design; **High** = significant
risk or loss; **Medium** = wrong in some situations; **Low** = cosmetic or minor.

| # | Sev. | Where | Finding | Evidence | Fix (phase) |
|---|---|---|---|---|---|
| A1 | Critical | `MomentumDir` L702, `RunContinuous` L725 | **Default strategy (Continuous) has negative expectancy by construction.** Direction = sign of the last 5 s of price, which is noise. Buys fill at ask, so the bid only has to fall 0.76 to hit the $1 SL but must rise 2.24 to hit the $2 TP. For a random walk, P(TP first) = 0.76 / 3.00 = 25.3%, and expectancy = 0.253 x 2 - 0.747 x 1 = **-0.24 per trade at 0.01 lot: exactly the spread**. Break-even needs 33% winners; noise gives about 25%. | Math above; spread from panel | Retire as a trading strategy (B) |
| A2 | Critical | `RunContinuous` L725, `MaxOpenFromEquity` L694 | Opens a new trade 1 s after any close, up to 0.1% of equity (5 at $5,000), all from the same 5 s noise reading, so the positions are correlated. Multiplies A1 and ignores "max 1 position" and "avoid unnecessary trading". | Code | Max simultaneous positions = 1 by default, daily trade cap (B) |
| A3 | Critical | `CalcLots` L1212, min-lot fallback L1248 | **Raises the lot to the broker minimum** when risk-based size is smaller, accepting up to 5% risk per trade (`InpMaxRiskAtMinLot`). Directly violates "never automatically increase lot size to satisfy minimum volume". | Code | Reject the trade instead (B) |
| A4 | Critical | Input L62, `ChangeLots` | Default lot mode is **Fixed** (panel lot). Risk per trade is not a % of equity, so it does not shrink when the account shrinks. | Code | Default to risk % of equity, 0.5% (B) |
| A5 | Critical | Input L79, `CheckDailyLimits` L1120 | **Daily loss limit is off by default** (0%). Nothing stops a losing day. | Code; -39.45 day | Default 2%, always on outside testing (B) |
| A6 | Critical | Account sizing | **A $25 Standard account cannot trade gold under the requested rules.** Min lot 0.01 = $1 per $1 move. 0.5% of $25 = $0.125 risk, but the spread alone (0.24) costs $0.24 at entry, so no valid stop fits. With A3 fixed, the bot would correctly reject every trade. With a 3.00 stop at min lot, 0.5% risk needs about **$600** equity. A Cent account (min lot 100x smaller) makes $25 workable. | Broker spec; screenshot spread | User decision needed (B) |
| A7 | High | `RunBurst` L383, `ManageBurst` L412 | Burst strategy trades tick noise. With wins and losses both smaller than about 3x the spread, costs dominate. | 48 and 50 trades at 31-32% win, both losing | Replace with the spec's momentum strategy on closed bars (C) |
| A8 | High | — | No consecutive-loss limit and no daily trade cap (only a per-minute cap for Burst). | Code | Add both, configurable (B) |
| A9 | High | `BlockReasonBase` L1076 | Spread filter is a fixed 0.35 for Continuous/Burst; no spread-to-ATR or spread-to-stop check (only Pullback has one, L611). Commission is never part of entry decisions. | Code | Spread vs ATR and vs stop for every strategy (F) |
| A10 | High | — | **No news filter** and no abnormal-volatility filter. Only Pullback skips rollover hours (L502). | Code | Configurable news window plus volatility filter; report honestly when no calendar data (F) |
| A11 | High | Whole project | No backtest or walk-forward evidence for any strategy. | No tester reports | Phase H |
| A12 | Medium | `ManageBurst` L412, L486, `CloseSide` L367 | Results of `PositionClose` and `PositionModify` are not checked in three places, so failed exits or stop moves are silent. | Code | Check every broker response and log failures (F) |
| A13 | Medium | `CloseSide` L367, then `OpenTradeEx` | Burst reversal opens the new trade without confirming the old ones closed, so failures leave both sides open (hedge account). | Code | Confirm closes before reversing (F) |
| A14 | Medium | Global L140 | Daily-limit lock lives only in memory, so restarting MT5 unlocks it the same day. | Code | Persist the lock and daily baseline (B) |
| A15 | Medium | Stop modifications | Broker freeze level (`SYMBOL_TRADE_FREEZE_LEVEL`) is never checked before modifying stops; stops level is. | No "FREEZE" in code | Check both (F) |
| A16 | Medium | Architecture | One 1,926-line file mixes UI, risk and three strategies; risk is not independent of strategies. | File | Split into `.mqh` modules: risk, regime, strategies, execution, panel (B-E) |
| A17 | Medium | `DoManual` L1017 | Manual BUY/SELL can open opposite to bot positions (hedge account), bypassing coordination. | Code | Route manual trades through the risk manager (F) |
| A18 | Low | `PullbackSignal` L512 | Pullback is the soundest logic (closed bars, trend filter, structure stop, 1.5R target, spread vs stop) but uses one EMA for trend and has no RSI or M1 confirmation as the spec asks. | Code | Becomes Strategy 1 (C) |
| A19 | Low | `OnTradeTransaction` L1562 | Journal `tag` on CLOSE rows is never filled (always empty). | Code | Fix (F) |
| A20 | Low | Stats | Win rate is shown, but not average win/loss, expectancy, profit factor or drawdown, which matter more. | Panel | Dashboard (G) |

## The 15 audit questions

| # | Question | Answer |
|---|---|---|
| 1 | Why does it enter losing trades? | Default and Burst strategies trade price noise with costs of about 1 spread per trade (A1, A2, A7). |
| 2 | Indicators correct? | Pullback EMAs/ATR use standard MT5 handles, reading closed bars from shift 1. Correct. |
| 3 | Incomplete candles? | No. Pullback reads shift 1 and evaluates once per new bar. Continuous/Burst use ticks, not candles. |
| 4 | Repeated entries from one signal? | Pullback: no (once per bar). Continuous: yes, by design, repeatedly re-enters (A2). |
| 5 | Against the dominant trend? | Continuous and Burst have no trend filter. Pullback does. |
| 6 | Stops too tight or wide? | Continuous: $1 stop is only about 4x the spread, so noise hits it. Burst loss cut is about 2x spread. |
| 7 | Take profits realistic? | Pullback 1.5R is reasonable. Continuous 2.00 needs a 2.24 bid move from a noise entry. |
| 8 | Lot size correct? | Formula uses broker tick value/size correctly, but the min-lot fallback and fixed default are wrong (A3, A4). |
| 9 | Spread/commission/slippage? | Partly: fixed spread cap; spread vs stop only in Pullback; commission not in decisions (A9). |
| 10 | News? | No protection (A10). |
| 11 | Conflicting strategies? | No: only one strategy runs at a time. Manual trades can conflict (A17). |
| 12 | Duplicate execution? | Mostly guarded (synchronous orders, position count, spacing). Burst reversal is unverified (A13). |
| 13 | Trailing/breakeven correct? | Stops only move in the trade's favour and respect stops level; freeze level unchecked (A15); some results unchecked (A12). |
| 14 | Daily drawdown protection? | Exists but off by default (A5) and not persisted (A14). |
| 15 | Real broker data? | Yes: balance, equity, symbol specs and history all come from MT5. |

## Things that work and will be kept

- Stop loss attached to every order (broker-side, survives PC/internet loss).
- STOP stops new entries and leaves open positions on their SL/TP.
- Always starts STOPPED after a terminal restart; pauses after a connection drop.
- Position filter by symbol + magic number.
- Daily P/L from broker history at the broker's day boundary, including commission and swap.
- Panel, lot rounding to broker step, CSV journal.

## Technology note

The requirements mention Python. The bot stays in **MQL5**: it runs inside MT5, has the lowest
order latency, and can be backtested on real Exness ticks in the MT5 Strategy Tester. The MT5
Python package only runs on Windows Python, which under Wine adds a fragile layer and cannot use
the Strategy Tester.

## Proposed order of work

1. **Phase B (next):** risk manager as its own module: 0.5% equity risk, reject when min lot is
   too large, daily loss 2%, 3 consecutive losses, 10 trades/day, 1 position, persisted daily state.
   Continuous and Burst removed from the default flow.
2. **Phases C-E:** the five strategies as separate modules, regime detector, coordinator.
3. **Phases F-G:** execution checks, news/volatility filters, dashboard.
4. **Phase H:** Strategy Tester backtests with real ticks, out-of-sample and walk-forward. Only
   strategies that pass stay enabled.

## Backups

Every change is a git commit, so any earlier version can be restored with `git checkout <commit>`.
The last version before the audit is commit `9068df8` (v3.0).
