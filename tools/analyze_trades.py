#!/usr/bin/env python3
"""Performance report for the XAUScalper trade journal.

Reads XAUScalper_trades.csv (live/demo) or XAUScalper_tester_trades.csv (Strategy
Tester) from the MT5 "Common/Files" folder and reports, overall and per strategy:

  net profit, gross profit, gross loss, win rate, profit factor, max drawdown,
  average win/loss in R, expectancy per trade ($ and R), max consecutive losses,
  total trades, average holding time, spread and commission costs.

Validation helpers:
  --split YYYY-MM-DD   in-sample (before) vs out-of-sample (from that date)
  --folds N            N consecutive time folds (stability across periods)
  --since / --until    date range filter
  --mode demo|real|tester   filter by account mode

Usage:
  python3 tools/analyze_trades.py PATH/TO/XAUScalper_tester_trades.csv --split 2026-08-01
Only the Python standard library is used.
"""
import argparse
import csv
import math
import sys
from collections import OrderedDict
from datetime import datetime


def parse_time(s):
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s.strip(), fmt)
        except ValueError:
            pass
    raise ValueError("unrecognised time: %r" % s)


def fnum(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def load_trades(path):
    """Join OPEN and CLOSE rows by position into one record per closed trade."""
    opens, trades = {}, []
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as fh:
        for row in csv.DictReader(fh):
            key = (row.get("account", ""), row.get("position", ""))
            event = (row.get("event") or "").strip()
            if event == "OPEN":
                opens[key] = row
            elif event == "CLOSE":
                o = opens.get(key, {})
                profit = fnum(row.get("profit"), 0.0)
                risk = fnum(o.get("risk_money"))
                r_mult = fnum(row.get("r_multiple"))
                if r_mult is None and risk:
                    r_mult = profit / risk
                trades.append({
                    "time": parse_time(row["time"]),
                    "open_time": parse_time(o["time"]) if o.get("time") else None,
                    "mode": row.get("mode", ""),
                    "strategy": (row.get("strategy") or o.get("strategy") or "UNKNOWN").strip() or "UNKNOWN",
                    "regime": o.get("regime", ""),
                    "profit": profit,
                    "commission": fnum(row.get("commission"), 0.0),
                    "spread_cost": fnum(o.get("spread_cost"), 0.0),
                    "hold_s": fnum(row.get("hold_s"), 0.0),
                    "r": r_mult,
                    "reason": row.get("reason", ""),
                    "side": o.get("side", ""),
                })
    trades.sort(key=lambda t: t["time"])
    return trades


def stats(trades):
    n = len(trades)
    out = OrderedDict(trades=n)
    if n == 0:
        return out
    profits = [t["profit"] for t in trades]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p < 0]
    gross_win, gross_loss = sum(wins), -sum(losses)
    equity = peak = max_dd = 0.0
    streak = max_streak = 0
    for p in profits:
        equity += p
        peak = max(peak, equity)
        max_dd = max(max_dd, peak - equity)
        streak = streak + 1 if p < 0 else 0
        max_streak = max(max_streak, streak)
    rs = [t["r"] for t in trades if t["r"] is not None]
    r_wins = [r for r in rs if r > 0]
    r_losses = [r for r in rs if r < 0]
    out["net_profit"] = sum(profits)
    out["gross_profit"] = gross_win
    out["gross_loss"] = gross_loss
    out["win_rate_pct"] = 100.0 * len(wins) / n
    out["profit_factor"] = (gross_win / gross_loss) if gross_loss > 0 else (math.inf if gross_win > 0 else 0.0)
    out["max_drawdown"] = max_dd
    out["avg_win"] = gross_win / len(wins) if wins else 0.0
    out["avg_loss"] = -gross_loss / len(losses) if losses else 0.0
    out["avg_win_R"] = sum(r_wins) / len(r_wins) if r_wins else None
    out["avg_loss_R"] = sum(r_losses) / len(r_losses) if r_losses else None
    out["reward_to_risk"] = (out["avg_win"] / -out["avg_loss"]) if wins and losses else None
    out["expectancy"] = sum(profits) / n
    out["expectancy_R"] = sum(rs) / len(rs) if rs else None
    out["max_consecutive_losses"] = max_streak
    out["avg_hold_min"] = sum(t["hold_s"] for t in trades) / n / 60.0
    out["spread_cost"] = sum(t["spread_cost"] for t in trades)
    out["commission"] = sum(t["commission"] for t in trades)
    return out


def fmt(v):
    if v is None:
        return "-"
    if isinstance(v, float):
        if math.isinf(v):
            return "inf"
        return "%.2f" % v
    return str(v)


def print_block(title, trades, out=sys.stdout):
    s = stats(trades)
    out.write("\n== %s ==\n" % title)
    if s["trades"] == 0:
        out.write("  no closed trades\n")
        return s
    for k, v in s.items():
        out.write("  %-24s %s\n" % (k, fmt(v)))
    return s


def by_strategy(trades):
    groups = OrderedDict()
    for t in trades:
        groups.setdefault(t["strategy"], []).append(t)
    return groups


def summary_table(trades, out=sys.stdout):
    out.write("\n%-10s %6s %8s %7s %10s %9s %8s\n" % ("strategy", "trades", "win%", "PF", "net", "exp(R)", "maxDD"))
    for name, ts in by_strategy(trades).items():
        s = stats(ts)
        out.write("%-10s %6d %8s %7s %10s %9s %8s\n" % (
            name, s["trades"], fmt(s["win_rate_pct"]), fmt(s["profit_factor"]), fmt(s["net_profit"]),
            fmt(s["expectancy_R"]), fmt(s["max_drawdown"])))


def exit_table(trades, out=sys.stdout):
    """How trades ended, per strategy: count, average R and net per exit reason."""
    out.write("\n%-10s %-26s %6s %8s %10s\n" % ("strategy", "exit reason", "count", "avg R", "net"))
    for name, ts in by_strategy(trades).items():
        reasons = OrderedDict()
        for t in ts:
            reasons.setdefault(t["reason"] or "-", []).append(t)
        for reason, rt in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
            rs = [t["r"] for t in rt if t["r"] is not None]
            out.write("%-10s %-26s %6d %8s %10s\n" % (
                name, reason[:26], len(rt), fmt(sum(rs) / len(rs)) if rs else "-",
                fmt(sum(t["profit"] for t in rt))))


def group_table(trades, title, keyfunc, out=sys.stdout):
    """Trades, win %, PF, net and expectancy (R) per group."""
    groups = OrderedDict()
    for t in sorted(trades, key=lambda t: str(keyfunc(t))):
        groups.setdefault(keyfunc(t), []).append(t)
    out.write("\n%-14s %6s %7s %7s %10s %8s\n" % (title, "trades", "win%", "PF", "net", "exp(R)"))
    for k, ts in groups.items():
        s = stats(ts)
        out.write("%-14s %6d %7s %7s %10s %8s\n" % (
            str(k)[:14], s["trades"], fmt(s["win_rate_pct"]), fmt(s["profit_factor"]),
            fmt(s["net_profit"]), fmt(s["expectancy_R"])))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--since")
    ap.add_argument("--until")
    ap.add_argument("--mode", choices=["demo", "real", "tester", "contest"])
    ap.add_argument("--split", help="out-of-sample starts on this date (YYYY-MM-DD)")
    ap.add_argument("--folds", type=int, default=0, help="report N consecutive time folds")
    args = ap.parse_args(argv)

    trades = load_trades(args.csv)
    if args.mode:
        trades = [t for t in trades if t["mode"] == args.mode]
    if args.since:
        trades = [t for t in trades if t["time"] >= parse_time(args.since)]
    if args.until:
        trades = [t for t in trades if t["time"] < parse_time(args.until)]

    print("Trades analysed: %d  (%s)" % (len(trades), args.csv))
    if not trades:
        return 0
    print("Period: %s -> %s" % (trades[0]["time"], trades[-1]["time"]))

    print_block("ALL STRATEGIES", trades)
    summary_table(trades)
    exit_table(trades)
    group_table(trades, "entry hour", lambda t: "%02d:00" % (t["open_time"] or t["time"]).hour)
    group_table(trades, "strategy/side", lambda t: "%s %s" % (t["strategy"], t["side"] or "?"))
    group_table(trades, "weekday", lambda t: (t["open_time"] or t["time"]).strftime("%u %a"))
    for name, ts in by_strategy(trades).items():
        print_block("STRATEGY " + name, ts)

    if args.split:
        cut = parse_time(args.split)
        ins = [t for t in trades if t["time"] < cut]
        oos = [t for t in trades if t["time"] >= cut]
        print("\n######## IN-SAMPLE (before %s) ########" % args.split)
        print_block("in-sample, all", ins)
        summary_table(ins)
        print("\n######## OUT-OF-SAMPLE (from %s) ########" % args.split)
        print_block("out-of-sample, all", oos)
        summary_table(oos)

    if args.folds and args.folds > 1:
        start, end = trades[0]["time"], trades[-1]["time"]
        span = (end - start) / args.folds
        print("\n######## %d TIME FOLDS ########" % args.folds)
        for i in range(args.folds):
            a = start + span * i
            b = start + span * (i + 1)
            fold = [t for t in trades if a <= t["time"] < b or (i == args.folds - 1 and t["time"] == end)]
            s = stats(fold)
            print("fold %d  %s -> %s  trades %3d  net %10s  PF %6s  exp(R) %6s" % (
                i + 1, a.strftime("%Y-%m-%d"), b.strftime("%Y-%m-%d"), s["trades"],
                fmt(s.get("net_profit")), fmt(s.get("profit_factor")), fmt(s.get("expectancy_R"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
