# scalper

XAUUSD Expert Advisor for MetaTrader 5: five strategies selected by a market regime detector,
an independent risk manager, and an on-chart control panel. Runs on Kali Linux through a
portable Wine staging build.

> **No strategy has been validated yet.** The code for all phases is written; compiling,
> backtesting and demo testing happen on the user's PC (see the plan below). Use a **demo
> account** until `docs/VALIDATION.md` says otherwise. The EA refuses entries on a real account
> unless *Allow trading on a REAL account* is set.

## Plan and status

| Phase | Content | Status | Report |
|---|---|---|---|
| A | Audit of the old bot | Done | [`docs/AUDIT.md`](docs/AUDIT.md) |
| B | Independent risk manager | Code complete; awaiting compile + unit tests | [`docs/PHASE_B.md`](docs/PHASE_B.md) |
| C | Five strategies as modules | Code complete; awaiting compile + unit tests | [`docs/PHASES_C_TO_G.md`](docs/PHASES_C_TO_G.md) |
| D | Market regime detector | Code complete | same |
| E | Strategy coordination | Code complete | same |
| F | Execution, filters, position management | Code complete | same |
| G | Dashboard | Code complete | same |
| H | Backtests, out-of-sample, walk-forward | Tools and procedure ready; to be run | [`docs/VALIDATION.md`](docs/VALIDATION.md) |
| I | Demo forward test | Procedure ready; to be run | same |
| J | Controlled live deployment | Checklist ready | same |

## Strategies (regime -> strategy)

| Regime | Strategy |
|---|---|
| Trending | 1. EMA trend pullback (M15 trend, M5 setup, M1 confirmation) |
| Breakout | 2. Support/resistance breakout + retest |
| Ranging | 3. RSI + Bollinger mean reversion |
| Reversal | 4. Liquidity sweep + market structure shift |
| Strong momentum | 5. Momentum scalping |
| Unclear / dangerous | wait |

Exact rules: [`docs/PHASES_C_TO_G.md`](docs/PHASES_C_TO_G.md).

## Risk rules (inputs)

Risk 0.5% of equity per trade, daily loss limit 2%, max 3 losses in a row, max 10 trades per day,
1 position, 60 s between trades, 15 min after a loss, emergency at 15% drawdown or margin level
below 150%. Never martingale, grid, doubling or widening stops.

## Layout

```
src/XAUScalper.mq5                 EA: engine, position manager, panel, tester hooks
src/Include/XAUScalper/*.mqh       risk, strategies, regime, filters, execution, journal
tests/RiskTests.mq5                unit tests (MT5 script)
tests/StrategyTests.mq5            unit tests (MT5 script)
tools/analyze_trades.py            performance report from the journal (+ unit tests)
tools/presets/*.set                Strategy Tester presets
scripts/install.sh                 copy + compile into every MT5 install
scripts/start.sh, stop.sh          start / stop the MT5 terminals
docs/                              audit, phase reports, validation procedure
```

## Setup (Kali + Wine)

Wine: portable Wine staging 11.21 in `~/wine-staging`, MT5 prefix in `~/.mt5`.

```bash
git clone https://github.com/allanorabaasa-hash/scalper.git ~/scalper
cd ~/scalper
chmod +x scripts/*.sh
./scripts/install.sh
```

In MetaEditor (F4 in MT5) compile with F7: `Experts/XAUScalper.mq5`,
`Scripts/XAUScalper/RiskTests.mq5`, `Scripts/XAUScalper/StrategyTests.mq5`.
Run both test scripts on any chart: they must report 0 failed.

Attach **XAUScalper** to the gold chart (Common tab: *Allow Algo Trading*), turn on the
**Algo Trading** toolbar button, press **START**.

## Auto-start

- **In the EA** (input *Auto-start*, on by default): the bot starts trading by itself whenever MT5
  is connected to the broker, after MT5 opens, after the internet returns, and on the next trading
  day after a risk lock. Pressing **STOP** or **EMERGENCY** is remembered, even across restarts:
  auto-start stays off until you press **START** again. Risk locks always take priority.
- **On Kali:** `./scripts/install-autostart.sh` registers `scripts/autostart.sh` to run at login.
  It waits for the internet, starts MT5, and restarts MT5 within a minute if it closes.
  Log: `~/scalper/autostart.log`. Remove with `./scripts/install-autostart.sh --remove`.
  `./scripts/stop.sh` stops both the watchdog and MT5.

MT5 reopens the chart with the EA attached as long as the chart and the **Algo Trading**
button were left on when MT5 last closed.

## Panel

START, STOP (no new trades; open trades stay managed), CLOSE ALL, EMERGENCY (stop, lock until
the next trading day, apply the emergency policy). It shows account and risk status, regime and
active strategy, news status, open positions, recent trades, per-strategy performance, and why
the bot is not trading at any moment.

## Journal and analysis

Trades are logged to `.../MetaQuotes/Terminal/Common/Files/XAUScalper_trades.csv`
(Strategy Tester: `XAUScalper_tester_trades.csv`).

```bash
python3 tools/analyze_trades.py "<Common/Files>/XAUScalper_tester_trades.csv" --split 2026-08-01 --folds 4
python3 -m unittest tools/test_analyze_trades.py
```
