"""Unit tests for tools/backtest_grid.py:  python3 -m unittest tools/test_backtest_grid.py"""
import os
import sys
import unittest

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import backtest_grid as bt  # noqa: E402


def daily_up(n=80):
    days = pd.date_range("2025-10-01", periods=n, freq="D")
    close = np.linspace(3000, 4000, n)                      # strong uptrend -> buy grids
    return pd.DataFrame({"time": days, "open": close, "high": close + 5, "low": close - 5, "close": close})


def bars_from(path, start="2025-12-19 00:00"):
    """One M1 bar per price in path (open = previous close, no wicks)."""
    close = np.array(path, dtype=float)
    open_ = np.concatenate([[close[0]], close[:-1]])
    t = pd.date_range(start, periods=len(close), freq="1min")
    return pd.DataFrame({"time": t, "open": open_, "high": np.maximum(open_, close),
                         "low": np.minimum(open_, close), "close": close})


P = dict(spread=0.0)


class Rules(unittest.TestCase):
    def test_filter_up(self):
        f = bt.daily_filter(daily_up(), pd.Series([pd.Timestamp("2025-12-19 10:00")]), dict(bt.DEFAULTS))
        self.assertEqual(f[0], 1)

    def test_take_profit_single_level(self):
        # buy at 4000, +$20 needs +20.00 with 0.01 lot
        grids, *_ = bt.run_backtest(bars_from([4000, 4010, 4020.5]), daily_up(), P)
        self.assertEqual(grids.iloc[0].reason, "basket take profit")
        self.assertAlmostEqual(grids.iloc[0].pnl, 20.0)
        self.assertEqual(grids.iloc[0].levels, 1)

    def test_levels_every_4_50_and_basket_stop_30(self):
        # buys at 4000, 3995.5, 3991, 3986.5 -> floating -30 at 3984.25 (avg 3993.25 - 30/4)
        grids, *_ = bt.run_backtest(bars_from([4000, 3980]), daily_up(), P)
        g = grids.iloc[0]
        self.assertEqual(g.reason, "basket stop")
        self.assertEqual(g.levels, 4)
        self.assertAlmostEqual(g.pnl, -30.0)

    def test_hard_stop_without_basket_stop(self):
        # rules as written: 5 levels, stop 18 beyond level 5 (3982) -> 3964: loss 135
        grids, *_ = bt.run_backtest(bars_from([4000, 3950]), daily_up(), dict(spread=0.0, basket_stop=0))
        g = grids.iloc[0]
        self.assertEqual((g.reason, g.levels), ("hard stop", 5))
        self.assertAlmostEqual(g.pnl, -135.0)

    def test_new_grid_after_close(self):
        grids, *_ = bt.run_backtest(bars_from([4000, 4021, 4021, 4042]), daily_up(), P)
        self.assertEqual(len(grids[grids.reason == "basket take profit"]), 2)


if __name__ == "__main__":
    unittest.main()
