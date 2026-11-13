"""Unit tests for analyze_trades.py on a small hand-made journal.

The rows below are a synthetic test fixture written to check the arithmetic.
They are NOT trading results.
Run: python3 -m unittest tools/test_analyze_trades.py
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_trades as at  # noqa: E402

HEADER = ("event,time,account,mode,position,side,strategy,regime,lots,price,spread,sl_dist,tp_dist,atr,"
          "risk_money,risk_pct,spread_cost,profit,commission,hold_s,r_multiple,reason\n")


def open_row(t, pos, strat, risk):
    return "OPEN,%s,1,tester,%d,BUY,%s,TRENDING,0.10,3870.000,0.240,2.000,4.000,2.500,%s,0.500,2.40,,,,,\n" % (
        t, pos, strat, risk)


def close_row(t, pos, strat, profit, comm, hold, r):
    return "CLOSE,%s,1,tester,%d,BUY,%s,,0.10,3872.000,,,,,,,,%s,%s,%s,%s,take profit\n" % (
        t, pos, strat, profit, comm, hold, r)


FIXTURE = (HEADER
           + open_row("2026.01.05 10:00:00", 1, "PULLBACK", "20.00")
           + close_row("2026.01.05 10:30:00", 1, "PULLBACK", "36.00", "-1.00", "1800.0", "1.800")
           + open_row("2026.01.06 10:00:00", 2, "PULLBACK", "20.00")
           + close_row("2026.01.06 10:20:00", 2, "PULLBACK", "-20.00", "-1.00", "1200.0", "-1.000")
           + open_row("2026.02.02 10:00:00", 3, "MOMENTUM", "20.00")
           + close_row("2026.02.02 10:10:00", 3, "MOMENTUM", "-20.00", "-1.00", "600.0", "-1.000")
           + open_row("2026.02.03 10:00:00", 4, "MOMENTUM", "20.00")
           + close_row("2026.02.03 10:05:00", 4, "MOMENTUM", "-20.00", "-1.00", "300.0", "")  # R from risk
           )


class AnalyzeTests(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".csv")
        with os.fdopen(fd, "w") as fh:
            fh.write(FIXTURE)

    def tearDown(self):
        os.remove(self.path)

    def test_join_and_r_fallback(self):
        trades = at.load_trades(self.path)
        self.assertEqual(len(trades), 4)
        self.assertAlmostEqual(trades[3]["r"], -1.0)        # profit / risk_money when r_multiple is empty
        self.assertAlmostEqual(trades[0]["spread_cost"], 2.40)

    def test_overall_stats(self):
        s = at.stats(at.load_trades(self.path))
        self.assertEqual(s["trades"], 4)
        self.assertAlmostEqual(s["net_profit"], -24.0)
        self.assertAlmostEqual(s["gross_profit"], 36.0)
        self.assertAlmostEqual(s["gross_loss"], 60.0)
        self.assertAlmostEqual(s["win_rate_pct"], 25.0)
        self.assertAlmostEqual(s["profit_factor"], 0.6)
        self.assertAlmostEqual(s["max_drawdown"], 60.0)     # +36 peak, then -60 to -24
        self.assertEqual(s["max_consecutive_losses"], 3)
        self.assertAlmostEqual(s["expectancy"], -6.0)
        self.assertAlmostEqual(s["expectancy_R"], (1.8 - 1 - 1 - 1) / 4)
        self.assertAlmostEqual(s["reward_to_risk"], 36.0 / 20.0)
        self.assertAlmostEqual(s["avg_hold_min"], (1800 + 1200 + 600 + 300) / 4 / 60)
        self.assertAlmostEqual(s["commission"], -4.0)
        self.assertAlmostEqual(s["spread_cost"], 9.6)

    def test_per_strategy(self):
        groups = at.by_strategy(at.load_trades(self.path))
        self.assertEqual(list(groups), ["PULLBACK", "MOMENTUM"])
        self.assertAlmostEqual(at.stats(groups["PULLBACK"])["net_profit"], 16.0)
        self.assertAlmostEqual(at.stats(groups["MOMENTUM"])["profit_factor"], 0.0)

    def test_split_and_folds_run(self):
        buf = io.StringIO()
        old = sys.stdout
        sys.stdout = buf
        try:
            at.main([self.path, "--split", "2026-02-01", "--folds", "2"])
        finally:
            sys.stdout = old
        text = buf.getvalue()
        self.assertIn("IN-SAMPLE", text)
        self.assertIn("OUT-OF-SAMPLE", text)
        self.assertIn("fold 2", text)

    def test_empty(self):
        self.assertEqual(at.stats([])["trades"], 0)


if __name__ == "__main__":
    unittest.main()
