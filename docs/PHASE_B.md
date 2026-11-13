# Phase B: Risk management

Status: **code complete, not yet verified** (the EA itself was extended in Phases C-G; the risk manager is unchanged). It has not been compiled or run, because MetaEditor
runs only on the user's PC. Phase B is complete once the steps under "How to verify" pass.

## Modified files

| File | Change |
|---|---|
| `src/Include/XAUScalper/RiskMath.mqh` | **New.** Pure calculations (no MT5 state): position size, consecutive losses, trading-day start, daily loss/target, drawdown. |
| `src/Include/XAUScalper/RiskManager.mqh` | **New.** Independent risk manager (`CRiskManager`): approves and sizes every trade, tracks the day, saves its state. |
| `src/XAUScalper.mq5` | v4.00. Removed Continuous, Burst, profiles, manual lot box, fixed-lot mode and manual BUY/SELL. Every entry goes through the risk manager. Panel shows risk status, rejection reasons and an EMERGENCY button. |
| `tests/RiskTests.mq5` | **New.** Unit tests for RiskMath (30 checks). |
| `scripts/install.sh` | Installs include files and the test script as well as the EA. |

Backup: the previous version is commit `9068df8` (v3.0) in git history.

## What changed, by audit finding

| Audit | Fix |
|---|---|
| A1, A2 (Continuous) | Removed. |
| A7 (Burst) | Removed. The spec's momentum strategy comes in Phase C. |
| A3 (lot raised to the minimum) | Sizing never rounds up. If the risk-based size is below the broker minimum, the trade is **rejected**, unless the user allows the minimum lot up to a set risk (see below). |
| A4 (fixed lots) | Size = % of **current equity** / loss per lot at the stop, using the broker's tick size, tick value (which includes the contract size), minimum, maximum and step. Rounded down to the step. |
| A5 (daily loss off) | Daily loss limit on, 2% of the day's starting equity. |
| A8 | Max 3 losses in a row per day, max 10 trades per day, max 1 open position, 60 s minimum between trades, 15 min pause after a loss. All are inputs. |
| A12 (unchecked results) | Breakeven modification and close results are checked and logged. An order counts as executed only with a DONE/PLACED retcode **and** a deal ticket. |
| A14 (lock lost on restart) | Day start, starting equity and locks are saved in terminal global variables. Trade counts and the loss streak are rebuilt from broker history, so a restart cannot reset them. |
| A15 (freeze level) | Breakeven checks the stops level and the freeze level. |
| A17 (manual trades) | Manual BUY/SELL removed. |
| A19 (journal tag) | The strategy name goes into the order comment and is read back on close. New log file: `XAUScalper_trades.csv`. |

## Risk rules (all configurable inputs)

| Input | Default | Behaviour |
|---|---|---|
| Risk per trade | 0.5% of equity | Size from equity, stop distance and broker specs. |
| Min-lot allowance | **10%** | User decision (option C): when 0.5% is below the broker minimum lot, the minimum lot is used only if its risk is at most 10% of equity; otherwise the trade is rejected. **0 = strict spec behaviour (always reject).** |
| Daily loss limit | 2% | Measured on equity vs the day's start. Locks new entries until the next broker day once reached with no position open. An open trade stays on its own SL/TP. |
| Daily profit target | off | Optional: stops new entries; never forces trades. |
| Max losses in a row | 3 | Per trading day. |
| Max trades per day | 10 | Counts entries. |
| Max open positions | 1 | |
| Spacing / cooldown | 60 s / 15 min | Between entries / after a losing trade. |
| Emergency | 15% equity drawdown or margin level < 150%, or the EMERGENCY button | Locks until next day; policy: close all bot positions (default) or keep them. |
| Margin buffer | 50% | Trade rejected if it needs more than half the free margin. |

Never used: martingale, grid, doubling after losses, widening stops. Stops only move towards profit.

The trading day is the broker's server day (`TimeTradeServer()`, 00:00 server time).
If the EA starts mid-day with no saved state, the day's starting equity is estimated as
balance minus this EA's realised result today.

### Consequence of option C on a $25 Standard account

At 0.01 lot, gold moves $1 per $1. Typical stops of $2-2.50 risk 8-10% of $25; stops over
$2.50 are rejected. One such loss exceeds the 2% daily limit, so **on $25 the bot takes at
most one losing trade per day**. Three losses in a row take about 25-30% of the account.
On a $5,000 demo the same settings risk 0.5% per trade with proper sizing.

## Test results

- Expected values for the sizing tests were computed independently (Python mirror of the same
  formulas) before writing the MQL5 tests: 5,000 / 0.5% / SL 3.00 -> 0.08 lot (0.48% real risk);
  $25 / strict / SL 3.00 -> rejected (12%); $25 / cap 10% / SL 2.00 -> 0.01 lot (8%).
- **MQL5 unit tests: not run yet** (needs the user's MT5).
- **No backtest yet** (Phase H).

## Remaining issues

- Not compiled yet: compile errors, if any, must be fixed first.
- Positions opened before the current day are excluded from the day's streak and trade count
  (their equity effect still counts toward the daily loss limit).
- No news filter yet (Phase F); the panel does not claim news protection.
- Strategy is still the interim Pullback; the five strategies come in Phase C.

## How to verify

1. `cd ~/scalper && git pull && ./scripts/install.sh`
2. In MetaEditor, open and compile (F7): `Experts/XAUScalper.mq5` and
   `Scripts/XAUScalper/RiskTests.mq5`. Expect **0 errors**.
3. In MT5 Navigator > Scripts > XAUScalper, drag **RiskTests** onto any chart.
   Expect the alert **"RiskTests: 30 passed, 0 failed"**.
4. Remove the old EA from the XAUUSD chart and attach the new one (inputs change in v4).
   The panel shows the risk line, e.g. `Risk 0.5%/trade  Daily loss limit used: 0%` and
   `Losses in a row 0/3  Trades 0/10  Wins 0/0`.
5. Restart MT5 and check that the counters and any lock are unchanged.
