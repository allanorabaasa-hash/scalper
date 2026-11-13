"""Unit tests for tools/backtest_trend.py:  python3 -m unittest tools/test_backtest_trend.py"""
import os
import sys
import unittest

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import backtest_trend as bt  # noqa: E402


def daily_up(n=80):
    days = pd.date_range("2025-10-01", periods=n, freq="D")
    close = np.linspace(3000, 4000, n)
    return pd.DataFrame({"time": days, "open": close, "high": close + 5, "low": close - 5, "close": close})


def bars_from(path):
    close = np.array(path, dtype=float)
    open_ = np.concatenate([[close[0]], close[:-1]])
    t = pd.date_range("2025-12-19 00:00", periods=len(close), freq="1min")
    return pd.DataFrame({"time": t, "open": open_, "high": np.maximum(open_, close),
                         "low": np.minimum(open_, close), "close": close})


P = dict(spread=0.0)


class Rules(unittest.TestCase):
    def test_take_profit_50(self):
        tr, *_ = bt.run_backtest(bars_from([4000, 4030, 4060]), daily_up(), P)
        self.assertEqual((tr.iloc[0].reason, tr.iloc[0].pnl), ("take profit", 50.0))

    def test_stop_loss_20_and_no_adding(self):
        tr, *_ = bt.run_backtest(bars_from([4000, 3995, 3990, 3975]), daily_up(), P)
        self.assertEqual((tr.iloc[0].reason, tr.iloc[0].pnl), ("stop loss", -20.0))

    def test_reopens_after_close(self):
        tr, *_ = bt.run_backtest(bars_from([4000, 4051, 4060, 4102]), daily_up(), P)
        self.assertEqual(list(tr.reason[:2]), ["take profit", "take profit"])

    def test_stop_first_when_both_touched(self):
        b = bars_from([4000, 4000])
        b.loc[1, "high"], b.loc[1, "low"] = 4060, 3970
        tr, *_ = bt.run_backtest(b, daily_up(), P)
        self.assertEqual(tr.iloc[0].reason, "stop loss")


if __name__ == "__main__":
    unittest.main()
