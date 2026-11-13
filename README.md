# scalper

XAUUSD Expert Advisor for MetaTrader 5 with an on-chart control panel.
Runs on Kali Linux through a portable Wine staging build.

> **Status: Phase B (risk management) of the improvement plan.**
> No strategy has proven an edge in testing yet. Use a **demo account** only.
> Reports: [`docs/AUDIT.md`](docs/AUDIT.md) (Phase A) and [`docs/PHASE_B.md`](docs/PHASE_B.md) (Phase B).

## Plan

| Phase | Content | Status |
|---|---|---|
| A | Audit of the existing bot | Done |
| B | Independent risk manager | Code complete, awaiting compile and tests |
| C | Five strategies as separate modules | Next |
| D-E | Market regime detector and strategy coordination | |
| F | Execution, news and volatility filters | |
| G | Dashboard | |
| H | Backtesting, out-of-sample, walk-forward | |
| I-J | Demo forward test, controlled live deployment | |

## Layout

```
src/XAUScalper.mq5                     EA: panel, execution, journal, interim strategy
src/Include/XAUScalper/RiskMath.mqh    pure risk calculations (unit-tested)
src/Include/XAUScalper/RiskManager.mqh risk manager: approves and sizes every trade
tests/RiskTests.mq5                    unit tests (MT5 script)
scripts/install.sh                     copy + compile into every MT5 install
scripts/start.sh, stop.sh              start / stop the MT5 terminals
```

## Panel

- **START**: begin looking for trades. **STOP**: no new trades; open positions keep their SL/TP and are still managed.
- **CLOSE ALL**: close every position this EA opened (asks to confirm).
- **EMERGENCY**: stop, block new trades until the next trading day, and apply the emergency policy.
- Status: `STOPPED`, `RUNNING`, `PAUSED` (after a connection drop), `LOCKED` (risk limit or emergency), `OFFLINE`.
- Risk line: risk per trade, share of the daily loss limit used, losses in a row, trades today.
- Footer: last action, and why the bot is not trading (e.g. `Not trading: cooldown after a loss (12 min left)`).

## Risk rules (inputs)

Risk 0.5% of equity per trade, daily loss limit 2%, max 3 losses in a row, max 10 trades/day,
1 position, 60 s between trades, 15 min after a loss, emergency at 15% drawdown or margin
level < 150%. Details and the small-account consequence: [`docs/PHASE_B.md`](docs/PHASE_B.md).

## Setup (Kali + Wine)

Wine: portable Wine staging 11.21 in `~/wine-staging`, MT5 prefix in `~/.mt5`.

```bash
git clone https://github.com/allanorabaasa-hash/scalper.git ~/scalper
cd ~/scalper
chmod +x scripts/*.sh
./scripts/install.sh
```

Then in MetaEditor (F4 in MT5) compile with F7: `Experts/XAUScalper.mq5` and
`Scripts/XAUScalper/RiskTests.mq5`. Run **RiskTests** on any chart: it must report 0 failed.

Attach **XAUScalper** to an XAUUSD chart (Common tab: *Allow Algo Trading*), turn on the
**Algo Trading** toolbar button, press **START**.

Trades are logged to `MQL5/Files/XAUScalper_trades.csv`.
