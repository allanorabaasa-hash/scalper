# Validation log (market-structure bot, v14)

Earlier strategies and their results are in git history (commit 0761de2 and before).

How to test: Strategy Tester, XAUScalper, symbol XAUUSDm (preset `structure_gold.set`) or
BTCUSDm (preset `structure_btc.set`), timeframe M1, custom period, *Every tick based on real
ticks*, deposit 500. The news rules do not run in the tester (no economic calendar there).
Journal: `Common/Files/XAUScalper_tester_trades.csv`, report with
`python3 tools/analyze_trades.py <file> --mode tester`.

A result counts only with enough trades (at least 100) and on months not used for tuning.

| Date | Symbol | Period | Settings | Batches | Positions | Net | Profit factor | Max DD | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-14 | - | - | v15.00 | - | - | - | - | - | Structure moved to M5 (side) / M1 (entry), live-tick trigger with real tick-flow confirmation. Not yet tested. |
| 2026-11-14 | - | - | v16.00 | - | - | - | - | - | All on M1: chart scan for breaks / shifts, fresh-break entries and continuation, tick check only when ticks exist. Not yet tested. |
| 2026-11-14 | BTCUSDm | 12:30-14:02 live demo | v16.00 (ran with M15 by mistake) | 3 | 17 visible | about +40 on visible trades | - | - | Stops at structure, 2R targets, breakeven and batch growth worked. Batch of 10 took 55 s to open (one order every ~5 s): v16.10 sends all orders at once; input renamed so the timeframe resets to M1. |
| 2026-11-18 | - | - | v17.00 | - | - | - | - | - | Modes Slow/Regular/Beast, no size increase on a ~0 batch, strict 1:2 on the real fill, lot size input, multi-account terminals (add-account.sh). |
| 2026-11-19 | BTCUSDm | 18-19 Nov live demo | v18.00 | 22+ | - | day -30.31 | - | - | Batch 22 lost 10 positions at the stop after being in profit; v18.10: 1:3, partials from TP1 (breakeven at TP1, half on a bounce, half of rest at TP2, rest TP3 / TP1). |
