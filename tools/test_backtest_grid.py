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
    close = np.linspace(3000, 4000, n)
    return pd.DataFrame({"time": days, "open": close, "high": close + 5, "low": close - 5, "close": close})


def bars_from(path):
    close = np.array(path, dtype=float)
    open_ = np.concatenate([[close[0]], close[:-1]])
    tm = pd.date_range("2025-12-19 00:00", periods=len(close), freq="1min")
    return pd.DataFrame({"time": tm, "open": open_, "high": np.maximum(open_, close),
                         "low": np.minimum(open_, close), "close": close})


P = dict(spread=0.0, daily_loss_pct=0, pos_cut=5.0)   # tests written for the -$5 cut


class Rules(unittest.TestCase):
    def test_individual_take_profit_4(self):
        grids, pos, *_ = bt.run_backtest(bars_from([4000, 4004.5]), daily_up(), P)
        self.assertEqual((pos.iloc[0].reason, round(pos.iloc[0].pnl, 2)), ("take profit", 4.0))
        self.assertEqual(grids.iloc[0].levels, 1)

    def test_level_every_3_and_loss_cut_5(self):
        # buy 4000; level 2 at 3997; at 3995 level 1 is cut at -5 (level 2 stays open)
        grids, pos, *_ = bt.run_backtest(bars_from([4000, 3995.5]), daily_up(), P)
        self.assertEqual(len(pos[pos.reason != "end of data"]), 0)   # level 1 only at -4.50
        self.assertEqual(grids.iloc[0].levels, 2)                       # level 2 opened at 3997
        grids, pos, *_ = bt.run_backtest(bars_from([4000, 3994.9, 3994.9]), daily_up(), P)
        cut = pos[pos.reason == "loss cut"]
        self.assertEqual(len(cut), 1)
        self.assertAlmostEqual(cut.iloc[0].pnl, -5.0)

    def test_max_8_levels(self):
        grids, pos, *_ = bt.run_backtest(bars_from([4000, 3900]), daily_up(), P)
        self.assertEqual(grids.iloc[0].levels, 8)
        self.assertTrue((pos[pos.reason != "end of data"].pnl >= -5.0001).all())   # cut at -$5

    def test_gap_fills_at_the_open(self):
        # candle opens with a gap from 4000 to 3970: the position is cut at the open, below -$5
        b = bars_from([4000, 4000, 3970])
        b.loc[2, ["open", "high"]] = 3970
        grids, pos, *_ = bt.run_backtest(b, daily_up(), P)
        self.assertAlmostEqual(pos.iloc[0].pnl, -30.0)


if __name__ == "__main__":
    unittest.main()


class Bitcoin(unittest.TestCase):
    def daily(self, n=80):
        days = pd.date_range("2025-10-01", periods=n, freq="D")
        close = np.linspace(60000, 70000, n)
        return pd.DataFrame({"time": days, "open": close, "high": close + 50, "low": close - 50, "close": close})

    def test_btc_take_profit_is_a_200_move(self):
        p = dict(bt.BTC, spread=0.0, daily_loss_pct=0)
        grids, pos, *_ = bt.run_backtest(bars_from([67000, 67150, 67201]), self.daily(), p)
        self.assertEqual(pos.iloc[0].reason, "take profit")
        self.assertAlmostEqual(pos.iloc[0].pnl, 4.0)

    def test_btc_cut_is_a_150_move(self):
        # cut (-$3 = $150) and the next level ($150) fall on the same price: the position is cut,
        # the grid ends, and a new grid starts (the EA does the same)
        p = dict(bt.BTC, spread=0.0, daily_loss_pct=0)
        grids, pos, *_ = bt.run_backtest(bars_from([67000, 66840, 66840]), self.daily(), p)
        cut = pos[pos.reason == "loss cut"]
        self.assertAlmostEqual(cut.iloc[0].pnl, -3.0)
        self.assertGreaterEqual(len(grids), 2)

    def test_btc_level_every_150(self):
        p = dict(bt.BTC, spread=0.0, daily_loss_pct=0, pos_cut=5.0)
        grids, pos, *_ = bt.run_backtest(bars_from([67000, 66860, 66860]), self.daily(), p)
        self.assertEqual(grids.iloc[0].levels, 1)
        grids, pos, *_ = bt.run_backtest(bars_from([67000, 66845, 66845]), self.daily(), p)
        self.assertEqual(grids.iloc[0].levels, 2)
