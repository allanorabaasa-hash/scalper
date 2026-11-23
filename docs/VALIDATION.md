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
| 2026-11-19 | BTCUSDm | 09:10 and 09:50 batches | v18.20 | 2 | 10 lost | about -10 | - | - | Both buys stopped by normal M1 noise; second bought the range top. v18.30: stop buffer half an average candle, min move 4 candles, no buys near the 60-candle high / sells near the low. |
| 2026-11-19 | BTCUSDm | 11:44-12:00 batch | v18.20 | 1 | 5 lost | -5.41 | - | - | Price reached TP1 (about 64005 vs TP1 63971) but stops were not moved: the EA missed the spike (connection lost, "Reconnected"). v18.50: TP touches judged on the best price since entry (M1 candles); batch result by position IDs. |
| 2026-11-20 | BTCUSDm | 09:25-10:30 rally | v18.50 | 0 | - | missed | - | - | Shift + ~55% pullback + turn, then +$550 rally; setup was valid only one minute (tick check / reconnect) and the 60-candle-high filter blocks trend continuation. v18.60: setup armed 3 candles, no-chase cap, range filter only for real range tops, pullback 38%. |
| 2026-11-20 | BTCUSDm | 62140 top -> 61290 -> pullback 61850 -> 60060 | v18.60 | 0 | - | missed | - | - | The deep pullback closed above small swing highs inside the drop, so the M1 scan flipped the structure UP and the sell setup vanished. v19.00: major structure (only a close beyond the protected swing changes the trend). |
| 2026-11-23 | BTCUSDm | spike 61300 -> 64100 | v19.10 | 1 | 2 lost | -7.11 | - | - | Bought the first 38% pullback of a vertical spike that was topping (lower highs). v19.20: spike filter (candle > 4x normal in the move or last 30 candles = no trade). |
