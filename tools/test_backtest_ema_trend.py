"""Unit tests for tools/backtest_ema_trend.py:  python3 -m unittest tools/test_backtest_ema_trend.py"""
import os
import sys
import unittest

import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import backtest_ema_trend as bt  # noqa: E402


class Sizing(unittest.TestCase):
    def test_one_percent_of_500(self):
        p = dict(bt.DEFAULTS)
        # 5 USD risk, stop 2.00 USD -> 200 USD per lot -> 0.025 -> 0.02 lot
        self.assertEqual(bt.position_size(500, 1.0, 2.0, p), (0.02, ""))

    def test_min_lot_too_big_is_skipped(self):
        p = dict(bt.DEFAULTS)
        # stop 6.00 USD: 0.01 lot would risk 6 USD > 5 USD
        self.assertEqual(bt.position_size(500, 1.0, 6.0, p), (0.0, "min lot too big"))

    def test_rounds_down(self):
        p = dict(bt.DEFAULTS)
        lots, _ = bt.position_size(10000, 1.0, 3.0, p)   # 100 / 300 = 0.333 -> 0.33
        self.assertAlmostEqual(lots, 0.33)


class DailyFilter(unittest.TestCase):
    def test_uses_previous_completed_day(self):
        days = pd.date_range("2026-01-01", periods=120, freq="D")
        closes = list(range(100, 160)) + list(range(160, 100, -1))   # up 60 days, then down
        daily = pd.DataFrame({"time": days, "open": closes, "high": closes, "low": closes, "close": closes})
        p = dict(bt.DEFAULTS)
        t = pd.Series([pd.Timestamp("2026-01-01 12:00"), pd.Timestamp("2026-02-27 12:00")])
        trend = bt.daily_trend(daily, t, p)
        self.assertEqual(trend.iloc[0], 0)    # no completed day / EMA55 not warm
        self.assertEqual(trend.iloc[1], 1)    # rising market -> up


class Indicators(unittest.TestCase):
    def test_atr_is_simple_average_of_true_range(self):
        df = pd.DataFrame({"high": [11, 12, 13], "low": [9, 10, 11], "close": [10, 11, 12]})
        self.assertAlmostEqual(bt.atr(df, 2).iloc[2], 2.0)


if __name__ == "__main__":
    unittest.main()
