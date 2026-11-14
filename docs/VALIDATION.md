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
