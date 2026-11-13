# Phases C to G: strategies, regime, coordination, execution, dashboard

Status: **code complete, not yet compiled or run.** MetaEditor and the Strategy Tester run only
on the user's PC. These phases are verified when the steps at the end pass. No result in this
document comes from a backtest or live trading.

EA version: 5.00.

## Architecture

```
XAUScalper.mq5 (EA)
 |- engine: market/risk checks -> regime -> strategy -> signal -> risk manager -> execution
 |- position manager: max hold, stale exit, momentum-loss exit, breakeven, trailing
 |- dashboard, journal hooks, Strategy Tester criterion
 |
 |- Include/XAUScalper/
    RiskMath.mqh         pure risk maths (unit-tested)            Phase B
    RiskManager.mqh      approves and sizes every trade           Phase B
    StrategyMath.mqh     pure pattern maths (unit-tested)         Phase C
    Common.mqh           shared types, regime -> strategy map     Phase C/E
    Levels.mqh           prev day / Asian / prev session / swing levels
    StrategyBase.mqh     base class: closed bars, once per bar    Phase C
    StratPullback.mqh    Strategy 1                               Phase C
    StratBreakout.mqh    Strategy 2                               Phase C
    StratMeanReversion.mqh Strategy 3                             Phase C
    StratSweep.mqh       Strategy 4                               Phase C
    StratMomentum.mqh    Strategy 5                               Phase C
    Regime.mqh           market regime detector                   Phase D
    Filters.mqh          spread, hours, news, volatility, stale   Phase F
    Execution.mqh        verified orders and stop changes         Phase F
    Journal.mqh          CSV journal with R and costs             Phase F/H
tests/RiskTests.mq5, tests/StrategyTests.mq5   MT5 unit-test scripts
tools/analyze_trades.py (+ tests), tools/presets/*.set           Phase H
```

The risk manager is independent of the strategies: strategies only propose direction, stop and
target; they never size or approve a trade.

---

## Phase C: five strategies

**Files:** `StrategyMath.mqh`, `Common.mqh`, `Levels.mqh`, `StrategyBase.mqh`, `Strat*.mqh` (new);
`tests/StrategyTests.mq5` (new).

**Common rules:** closed bars only (shift >= 1); each strategy evaluates once per new bar of its
timeframe (one setup gives at most one signal per bar); every signal has a stop; stops wider than
a maximum x ATR are skipped, never widened to fit.

| # | Strategy | Timeframes | Entry (buy; sell mirrored) | Stop | Target | Early exit |
|---|---|---|---|---|---|---|
| 1 | EMA trend pullback | M15 / M5 / M1 | M15 close > EMA200; M5 EMA20 > EMA50 and not flat (gap >= 0.2 ATR, EMA50 slope >= 0.1 ATR over 5 bars); M5 low touched EMA20 within 6 bars without closing 0.5 ATR below EMA50; RSI14 > 50 and rising; M1 bullish close above previous M1 high | pullback low - 0.3 ATR (0.8-2.5 ATR) | 1.8R | M5 close 0.2 ATR beyond EMA50 |
| 2 | Breakout + retest | M5, levels from D1/M15 | strong candle (body >= 60%, range >= 1 ATR) closes 0.2 ATR beyond a key level; no close back through it (> 0.1 ATR); retest within 0.15 ATR; bullish confirmation above previous high | retest low - 0.2 ATR (max 2.5 ATR) | 2R | trailing from 1.5R |
| 3 | RSI + Bollinger mean reversion | M5 | only if ADX(M5) < 25 and EMA200 nearly flat; low reached lower band (20,2); RSI14 < 30; bullish close back inside the bands | extreme - 0.3 ATR (0.5-2 ATR) | middle band (skipped if < 1R) | time exit |
| 4 | Liquidity sweep + structure shift | M5, levels | wick 0.15-2 ATR below a significant low with a close back above (a wick alone is not a sweep); sweep low holds; first close above the last swing high before the sweep | sweep low - 0.2 ATR (max 3 ATR) | 2.5R | trailing from 2R |
| 5 | Momentum scalping | M5 (input) | EMA9 crossed above EMA21 within 3 bars; RSI7 > 55; ADX14 > 20 and rising; broker tick volume > 20-bar average; close above 5-bar high; candle <= 2 ATR and <= 1.5 ATR from EMA9 | 3-bar low - 0.2 ATR (0.8-2 ATR) | 1.8R | EMA9 back through EMA21 |

**Added in v5.40 (user request):**

| # | Strategy | Timeframes | Entry (buy; sell mirrored) | Stop | Target |
|---|---|---|---|---|---|
| 6 | Fair value gap retracement | M5, M15 trend | M15 close > EMA200 and EMA50 > EMA200; bullish FVG (C low > A high) of >= 0.3 ATR with a displacement candle body >= 1 ATR, formed within 20 bars; first retest: last bar dips into the gap, closes bullish above its middle; no close below the gap since | gap bottom / bar low - 0.3 ATR (0.6-2.5 ATR) | 2R |
| 7 | Support/resistance bounce | M5, levels | 3 bars closed above the level, last bar touched it (0.15 ATR above to 0.3 ATR below) and closed back above with a rejection wick >= 50% or a bullish engulfing; no buys when M15 ADX > 30 with EMA50 < EMA200 | level / bar low - 0.2 ATR (0.5-2 ATR) | 2R |

In Auto mode the regime map is unchanged (6 and 7 are not mapped to a regime yet); they run in
All mode and in their own single-strategy modes.

Key levels: previous day high/low, Asian session high/low (after it closes), previous completed
session high/low, latest M15 swing high/low (strength 3). Session hours are inputs (server time).

**Tests:** `StrategyTests.mq5`, 34 checks (29 + FVG and rejection-wick checks in v5.40) (swings, crosses, strong candle, sweep depth rules,
highest/lowest/average/percentile, session range). Expected values were cross-checked with an
independent Python implementation. Not yet run in MT5.

**Remaining issues:** strategy logic is untested on market data; parameters are starting values
from the spec, not optimised.

---

## Phase D: market regime detector

**File:** `Regime.mqh` (new). M15, closed bars, recomputed once per new M15 bar.

| Regime | Conditions (score = share true) | Strategy |
|---|---|---|
| Dangerous | ATR(14) > 2.5 x its 50-bar average | none: wait |
| Reversal | prev-day/Asian high or low swept in the last 4 bars; ADX < 30; price within 2.5 ATR of EMA50 | 4 Sweep |
| Breakout | Bollinger width in lowest 20% recently; close outside the bands; width expanding | 2 Breakout |
| Momentum | ADX > 30; ADX rising; bar body >= 1.2 ATR; body direction = EMA50 slope | 5 Momentum |
| Trending | ADX >= 22; EMA50/EMA200 and price aligned; EMA50 slope >= 0.2 ATR | 1 Pullback |
| Ranging | ADX < 18; band width below median; price within 1 ATR of EMA50; EMA50 flat | 3 Mean reversion |
| Unclear | nothing reaches the minimum score (0.75) | none: wait |

Priority: Dangerous > Reversal > Breakout > Momentum > Trending > Ranging. **The score counts
agreeing rules; it is not a probability of winning.** Regime changes are logged.

**Remaining issues:** thresholds are untested; the regime can change at most every 15 minutes.

---

## Phase E: strategy coordination

**File:** `XAUScalper.mq5`.

- **Auto mode:** only the strategy mapped to the current regime is evaluated. Unclear or
  dangerous regime: no strategy, the panel says why.
- **Single-strategy modes** (input *Mode*) for testing each strategy independently (spec 9).
- **Enable switches** per strategy: strategies that fail validation can be turned off; in Auto
  their regime then waits.
- **No conflicts:** one strategy at a time, max 1 position by default, and a signal opposite to an
  open position is rejected ("conflicting open position").

---

## Phase F: execution and position management

**Files:** `Execution.mqh`, `Filters.mqh`, `Journal.mqh` (new), `XAUScalper.mq5`.

Engine order on every tick while RUNNING: platform permissions and live guard, market filters,
risk manager (`CanOpen`), regime, strategy, conflict check, cost check, sizing (`SizeTrade`),
execution, verification, journal.

**Execution:**
- executed only with retcode DONE/PLACED **and** a deal ticket;
- the position is re-read: if the broker did not attach the stop, it is set, and if that fails
  the position is closed;
- slippage beyond the limit is logged;
- duplicate guard while an order is in flight, plus one signal per bar and the risk manager's
  spacing;
- if the broker's minimum stop distance widens the stop, the size is computed on the wider stop
  and the target keeps the same R multiple.

**Cost check:** a signal is rejected when the spread exceeds 25% of the target distance.

**Position management** (once per second, also when STOPPED): max holding time; stale-trade
exit (not at 0.2-0.3R after a set time); momentum-loss exit (Strategies 1 and 5) once per M1 bar;
breakeven at 1R (not earlier); ATR trailing for Strategies 2, 4 and 5. Stops only move in the
trade's favour and respect the stops and freeze levels; failures are shown and retried after 10 s.

**Filters:**
- max spread 0.40 and spread <= 20% of ATR(M5);
- rollover hours (server 21:00-23:00), Friday from 19:00, Monday before 01:00;
- **news:** MT5 economic calendar, high-impact USD events, 30 min before/after. It is reported as
  *unavailable* in the Strategy Tester or when the calendar fails, never shown as active. An
  option blocks trading when data is unavailable;
- abnormal volatility: an M1 bar over 4 x ATR(M1) pauses entries for 15 min;
- stale prices: no tick for 60 s.

**Live guard:** on a REAL account the EA refuses new entries unless *Allow trading on a REAL
account* is set (spec rule 14).

**Journal:** `Common/Files/XAUScalper_trades.csv` (tester: `XAUScalper_tester_trades.csv`), one
OPEN and one CLOSE row per trade with strategy, regime, stop, target, ATR, risk in money and %,
spread cost, net profit, commission, holding time, R multiple and exit reason.

**Remaining issues:** execution has not been exercised on a broker yet; the news filter does not
work in the tester, so backtests include news periods.

---

## Phase G: dashboard

**File:** `XAUScalper.mq5` (panel).

Shows: START / STOP / CLOSE ALL / EMERGENCY, connection status, broker / account / mode
(demo/real), balance, equity, day P/L, floating P/L, drawdown today, spread, risk status (risk per
trade, share of daily loss limit used, losses in a row, trades today), market regime and score,
active strategy, news status, last tick age, open positions (close button per row), last three
trades, per-strategy performance (last 30 days: trades, win %, net, profit factor), the last
action and **why the bot is not trading** (e.g. spread too high, minimum lot too large, regime
uncertain, conflicting position, daily loss limit, news, cooldown).

---

## How to verify phases C to G

1. `cd ~/scalper && git pull && ./scripts/install.sh`
2. MetaEditor: compile `Experts/XAUScalper.mq5`, `Scripts/XAUScalper/RiskTests.mq5`,
   `Scripts/XAUScalper/StrategyTests.mq5`. Expect **0 errors**. Send any errors to be fixed.
3. Run both scripts on any chart: **RiskTests 30 passed, StrategyTests 29 passed, 0 failed**.
4. Attach the EA to XAUUSD (demo). The panel must show regime, news status and strategy lines.
5. Strategy Tester, one quick run per preset (`s1_pullback.set` ... `s5_momentum.set`, last
   month, *Every tick based on real ticks*): every strategy must open at least a few trades with
   stops and targets, and the journal file must appear in `Common/Files`.

Phase H (backtests) starts when all five steps pass. Its procedure is in `docs/VALIDATION.md`.
