# Phases H to J: validation and deployment

These phases need MT5 market data, the Strategy Tester and time on a demo account, so they are run
on the user's PC. This document gives the procedure, the tools and the pass/fail criteria.
**No result is recorded here until it has actually been produced.** Results are added to the
"Results log" at the end, with the date and the exact settings.

## Tools

| Tool | Purpose |
|---|---|
| `tools/presets/*.set` | Tester presets: `auto.set` (coordinated system), `s1_pullback.set` ... `s5_momentum.set` (each strategy alone), `auto_strict_minlot.set` (min lot never allowed above risk %). Installed to `MQL5/Profiles/Tester`. |
| `OnTester` criterion | Profit factor x (1 - relative drawdown) x sqrt(trades); 0 below 30 trades. The tester log also prints per-strategy trades, win %, net and profit factor. |
| Journal | `.../MetaQuotes/Terminal/Common/Files/XAUScalper_tester_trades.csv` (recreated per test) and `XAUScalper_trades.csv` (demo/live). |
| `tools/analyze_trades.py` | Net, gross profit/loss, win rate, profit factor, max drawdown, average win/loss and R, expectancy ($ and R), max consecutive losses, trades, average holding time, spread and commission costs, overall and per strategy; `--split` (in-sample vs out-of-sample) and `--folds` (stability). |

Find the Common folder on Kali:

```bash
find ~/.mt5/drive_c/users -type d -path '*MetaQuotes/Terminal/Common/Files'
```

## Phase H: backtesting and optimisation

### Tester settings (all runs)

- Symbol: the account's gold symbol (e.g. `XAUUSDm`); timeframe M1 (strategies read their own timeframes)
- Model: **Every tick based on real ticks** (real spreads)
- Delay: **Random delay** or a fixed delay close to your ping (e.g. 200 ms)
- Deposit: 5,000 USD (scales by %), leverage as on the account
- Commission: the account's real commission. On Exness Standard it is in the spread; on Raw/Zero set it in the tester.

### Data periods

| Use | Period |
|---|---|
| In-sample (development) | 2026-01-01 to 2026-07-31 |
| Out-of-sample (never used for tuning) | 2026-08-01 to the latest complete week |

Both periods contain trending, ranging, high- and low-volatility weeks and major USD news
(NFP, CPI, FOMC). The news filter is unavailable in the tester, so backtests **include** news
spikes: treat results as conservative on that point and check them separately.

### Steps

1. **Each strategy alone, in-sample:** run `s1` ... `s5` presets. Analyse:
   `python3 tools/analyze_trades.py <journal> --mode tester`
2. **Parameter sensitivity:** for each strategy, optimise only 2-3 key inputs over a coarse grid
   (e.g. RewardR 1.5/1.8/2.0, MaxSLATR 2.0/2.5/3.0). A strategy is robust only if neighbouring
   values give similar results. A single peak means it is overfitted: reject it.
3. **Walk-forward:** in the tester set *Forward* to 1/3 (or run the optimisation in-sample and
   the chosen values on the out-of-sample period), and use `--folds 4` on the full journal for
   stability over time.
4. **Out-of-sample, each strategy:** run the chosen settings on the out-of-sample period once.
   Do not tune after looking at these results.
5. **Coordinated system:** `auto.set` in-sample and out-of-sample, with only the strategies that
   passed enabled.

### Acceptance criteria, per strategy (out-of-sample, after costs)

| Metric | Required |
|---|---|
| Trades | >= 100 (in- and out-of-sample combined; >= 30 out-of-sample) |
| Profit factor | >= 1.30 |
| Expectancy | > 0 in money **and** in R |
| Max drawdown | <= 10% of the deposit at 0.5% risk |
| Max consecutive losses | consistent with the win rate (no unexplained clusters) |
| Stability | no fold of `--folds 4` with PF < 0.9; neighbouring parameters similar |
| Costs | spread + commission < 30% of gross profit |

A strategy that fails is **disabled** (Enable input = false), not forced through. A high win rate
alone is not acceptance.

## Phase I: demo forward test

1. Settings = the validated backtest settings, enabled strategies only, real Exness demo account,
   risk as planned for live.
2. Run at least **4 weeks** or **50 trades**, whichever is later, including news weeks with the
   news filter active.
3. Each week: `python3 tools/analyze_trades.py <Common>/XAUScalper_trades.csv --mode demo`
4. Compare with the out-of-sample backtest:
   - expectancy (R) within the backtest range, profit factor not below 1.1;
   - average slippage and spread cost not more than 1.5 x the backtest;
   - no execution errors left unexplained in the Experts log;
   - every risk rule observed (no trade above the risk limit, locks held after restarts).
5. Any failure: back to Phase H for that strategy. Nothing is tuned on demo results alone.

## Phase J: controlled live deployment

Only after Phase I passes.

**Account:** for a $25 start, a **Cent** account gives normal 0.5% sizing. A $25 Standard account
can only trade the minimum lot (8-10% risk per trade with the min-lot allowance, otherwise no
trades; see `docs/PHASE_B.md`).

**Checklist**

- [ ] Phase I passed; dates and numbers recorded below
- [ ] Inputs reviewed: risk 0.5%, daily loss 2%, 3 losses in a row, 10 trades/day, 1 position, emergency on
- [ ] Only validated strategies enabled
- [ ] *Allow trading on a REAL account* set to true (otherwise the EA refuses entries on real accounts)
- [ ] UPS / laptop battery, stable internet, sleep disabled (or a VPS near the broker server)
- [ ] First 2 weeks: smallest possible size; review the journal daily
- [ ] Stop rules: pause and return to Phase H if live expectancy is negative after 30 trades, or
      if drawdown exceeds the backtest maximum drawdown

## Results log

| Date | Phase | Strategy / mode | Period | Settings | Trades | PF | Expectancy (R) | Max DD | Pass? |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | |
| 2026-11-13 | H | All 5 strategies, testing mode (in-sample) | ~6 weeks to 2026-11-11, real ticks, deposit 3,000 | v5.20 defaults | 398 | 1.05 (net +120.21, max DD 12.0%) | payoff +0.30/trade | 12.0% | No (system). Per strategy: PULLBACK 203 tr PF 1.21 +219.49; MOMENTUM 19 tr PF 1.25 +15.71; BREAKOUT 80 tr PF 0.85 -78.38; SWEEP 95 tr PF 0.95 -31.08; MEANREV 1 tr -5.53. Breakout and Sweep disabled in v5.30. |
| 2026-11-13 | H | All 7 strategies, testing mode (in-sample) | 2026-10-01 to 2026-11-11, real ticks, deposit 3,000 | v5.40 | 494 | 1.00 (net +4.12, max DD 313.76) | -0.00 | 10.2% | No (system). PULLBACK 189 tr PF 1.27 +253.08 exp 0.08R; MOMENTUM 17 tr PF 1.75 +43.25; FVG 13 tr PF 1.70 +44.27; SRBOUNCE 112 tr PF 0.75 -206.05; BREAKOUT 74 tr PF 0.76 -109.67; SWEEP 88 tr PF 0.97 -18.45; MEANREV 1 tr. Pullback exits: momentum-lost 13 x -0.78R (-113.45), time exit 43 x +0.04R. v5.50 keeps Pullback, Momentum, FVG; exit variants A-D to be compared. |
