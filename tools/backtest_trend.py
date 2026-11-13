#!/usr/bin/env python3
"""
Daily trend trader for XAUUSD: backtest with plain pandas (same rules as the EA, v11).

Rules
  Direction  Daily EMA 21 > EMA 55: buy only; EMA 21 < EMA 55: sell only.
             No new trade while the daily EMAs are flat or crossing
             (last two COMPLETED daily candles; "flat" = gap below 0.10 x ATR(D1, 14)).
  Trade      One 0.01 position at a time. Nothing is ever added to a losing position.
  Exits      Take profit at +$50, stop loss at -$20 (for 0.01 lot of gold: a $50 / $20 price move).
  Repeat     A new trade opens at the close of the candle where the last one closed, until stopped.
  Daily loss limit: off by default (--daily-loss 4 turns it on).

Price model
  MT5 bid candles. Buys open at the ask (bid + spread) and close at the bid; sells the reverse.
  If a candle touches both the stop and the target, the stop is assumed first (conservative).
  Gaps fill at the candle open.

Usage
  python3 tools/backtest_trend.py --bars XAUUSDm_M1.csv --daily XAUUSDm_D1.csv
  python3 tools/backtest_trend.py --demo        # synthetic prices: only checks the code runs
"""

import argparse
import sys

import numpy as np
import pandas as pd

DEFAULTS = dict(
    balance=500.0,
    ema_fast=21, ema_slow=55, flat_gap_atr=0.10,
    lot=0.01, take_profit=50.0, stop_loss=20.0,
    daily_loss_pct=0.0,
    contract_size=100.0,     # oz per lot
    spread=0.25,
)

# ----------------------------------------------------------------------------
# Data and daily filter
# ----------------------------------------------------------------------------
def load_bars(path):
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    df["time"] = pd.to_datetime(df["time"])
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    return df[["time", "open", "high", "low", "close"]]


def daily_filter(daily, bar_times, p):
    """+1 / -1 / 0 per bar from the two last completed daily candles (no look-ahead)."""
    d = daily.copy().reset_index(drop=True)
    fast = d["close"].ewm(span=p["ema_fast"], adjust=False).mean()
    slow = d["close"].ewm(span=p["ema_slow"], adjust=False).mean()
    prev_close = d["close"].shift(1)
    tr = pd.concat([d["high"] - d["low"], (d["high"] - prev_close).abs(), (d["low"] - prev_close).abs()],
                   axis=1).max(axis=1)
    atr = tr.rolling(14).mean()
    gap, gap_prev = fast - slow, (fast - slow).shift(1)
    state = np.where(gap > 0, 1, -1)
    state = np.where(gap * gap_prev <= 0, 0, state)                 # crossing
    state = np.where(gap.abs() < p["flat_gap_atr"] * atr, 0, state)   # flat
    state = np.where(d.index < p["ema_slow"] + 2, 0, state)          # warm-up
    state = np.where(atr.isna() | gap_prev.isna(), 0, state)
    d["state"] = state.astype(int)
    d["available"] = d["time"].dt.normalize() + pd.Timedelta(days=1)  # known once the day has closed
    m = pd.merge_asof(pd.DataFrame({"time": bar_times}), d[["available", "state"]].sort_values("available"),
                      left_on="time", right_on="available", direction="backward")
    return m["state"].fillna(0).astype(int).values


# ----------------------------------------------------------------------------
# Backtest
# ----------------------------------------------------------------------------
def run_backtest(bars, daily, params=None):
    p = dict(DEFAULTS, **(params or {}))
    usd = p["contract_size"] * p["lot"]                 # USD per $1 move
    tp_dist, sl_dist, sp = p["take_profit"] / usd, p["stop_loss"] / usd, p["spread"]
    filt = daily_filter(daily, bars["time"], p)
    t = bars["time"].values
    o, h, l, c = (bars[k].values for k in ("open", "high", "low", "close"))
    days = bars["time"].dt.normalize().values

    balance, trades, equity = p["balance"], [], np.empty(len(bars))
    pos = None
    day, day_start, locked, locked_days = None, balance, False, 0

    for i in range(len(bars)):
        if days[i] != day:
            day, day_start, locked = days[i], balance, False
        if pos is not None:
            d = pos["dir"]
            # close prices of this candle for the position: bid for buys, ask for sells
            co, chi, clo = (o[i], h[i], l[i]) if d > 0 else (o[i] + sp, h[i] + sp, l[i] + sp)
            worst, best = (clo, chi) if d > 0 else (chi, clo)
            exit_px = reason = None
            if d * (co - pos["sl"]) <= 0:
                exit_px, reason = co, "stop loss"            # gap through the stop
            elif d * (co - pos["tp"]) >= 0:
                exit_px, reason = co, "take profit"          # gap through the target
            elif d * (worst - pos["sl"]) <= 0:
                exit_px, reason = pos["sl"], "stop loss"
            elif d * (best - pos["tp"]) >= 0:
                exit_px, reason = pos["tp"], "take profit"
            if reason:
                pnl = d * (exit_px - pos["entry"]) * usd
                balance += pnl
                trades.append(dict(start=pos["time"], end=t[i], side="BUY" if d > 0 else "SELL",
                                   entry=pos["entry"], exit=exit_px, pnl=round(pnl, 2), reason=reason))
                pos = None

        if pos is None:
            if p["daily_loss_pct"] > 0 and not locked and balance - day_start <= -day_start * p["daily_loss_pct"] / 100:
                locked, locked_days = True, locked_days + 1
            if not locked and filt[i] != 0:
                d = int(filt[i])
                entry = c[i] + sp if d > 0 else c[i]
                pos = dict(dir=d, time=t[i], entry=entry, sl=entry - d * sl_dist, tp=entry + d * tp_dist)

        if pos is None:
            equity[i] = balance
        else:
            mark = c[i] if pos["dir"] > 0 else c[i] + sp
            equity[i] = balance + pos["dir"] * (mark - pos["entry"]) * usd

    if pos is not None:
        mark = c[-1] if pos["dir"] > 0 else c[-1] + sp
        pnl = pos["dir"] * (mark - pos["entry"]) * usd
        trades.append(dict(start=pos["time"], end=t[-1], side="BUY" if pos["dir"] > 0 else "SELL",
                           entry=pos["entry"], exit=mark, pnl=round(pnl, 2), reason="end of data"))
    return pd.DataFrame(trades), pd.Series(equity, index=bars["time"]), locked_days, p


def report(trades, equity, locked_days, p):
    print(f"\nDaily trend trader   start {p['balance']:.2f}   lot {p['lot']}   TP +{p['take_profit']:.0f}   "
          f"SL -{p['stop_loss']:.0f}   spread {p['spread']}")
    if len(equity):
        print(f"Period: {equity.index[0]}  to  {equity.index[-1]}")
    print("-" * 50)
    if len(trades) == 0:
        print("No trades.")
        return
    wins, losses = trades[trades.pnl > 0], trades[trades.pnl <= 0]
    peak = equity.cummax()
    streak = longest = 0
    for x in trades.pnl:
        streak = streak + 1 if x <= 0 else 0
        longest = max(longest, streak)
    hold = (pd.to_datetime(trades.end) - pd.to_datetime(trades.start)).dt.total_seconds() / 3600
    rows = [
        ("Trades", len(trades)),
        ("Net profit", trades.pnl.sum()),
        ("Final balance", p["balance"] + trades.pnl.sum()),
        ("Return %", trades.pnl.sum() / p["balance"] * 100),
        ("Win rate %", len(wins) / len(trades) * 100),
        ("Profit factor", wins.pnl.sum() / -losses.pnl.sum() if losses.pnl.sum() < 0 else float("inf")),
        ("Average win", wins.pnl.mean() if len(wins) else 0.0),
        ("Average loss", losses.pnl.mean() if len(losses) else 0.0),
        ("Max drawdown $", (peak - equity).max()),
        ("Max drawdown %", ((peak - equity) / peak).max() * 100),
        ("Max losses in a row", longest),
        ("Average hold (hours)", hold.mean()),
        ("Days stopped by limit", locked_days),
    ]
    for k, v in rows:
        print(f"{k:<26}{v:>14.2f}" if isinstance(v, float) else f"{k:<26}{v:>14}")
    print("\nExits:")
    for r, x in trades.groupby("reason"):
        print(f"  {r:<20}{len(x):>6} trades   {x.pnl.sum():>10.2f}")
    print("\nBy side:")
    for s_, x in trades.groupby("side"):
        print(f"  {s_:<20}{len(x):>6} trades   {x.pnl.sum():>10.2f}   win {100 * (x.pnl > 0).mean():.0f}%")


def synthetic(days=120, seed=3):
    rng = np.random.default_rng(seed)
    n = days * 1380                                            # M1 bars, ~23 h a day
    trend = np.repeat(rng.normal(0, 1.2, days // 10 + 1), 10 * 1380)[:n] / 1380
    close = 4000 + np.cumsum(trend + rng.normal(0, 0.45, n))
    open_ = np.concatenate([[close[0]], close[:-1]])
    wick = np.abs(rng.normal(0, 0.25, n))
    tm = pd.date_range("2026-01-01", periods=n, freq="1min")
    bars = pd.DataFrame({"time": tm, "open": open_, "high": np.maximum(open_, close) + wick,
                         "low": np.minimum(open_, close) - wick, "close": close})
    daily = bars.set_index("time").resample("1D").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna().reset_index()
    return bars, daily


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bars", help="M1 (or M5) CSV from ExportBars")
    ap.add_argument("--daily", help="D1 CSV from ExportBars")
    ap.add_argument("--demo", action="store_true", help="synthetic prices (code check only)")
    ap.add_argument("--balance", type=float, default=DEFAULTS["balance"])
    ap.add_argument("--spread", type=float, default=DEFAULTS["spread"])
    ap.add_argument("--tp", type=float, default=DEFAULTS["take_profit"], help="take profit in USD")
    ap.add_argument("--sl", type=float, default=DEFAULTS["stop_loss"], help="stop loss in USD")
    ap.add_argument("--daily-loss", type=float, default=0.0, help="daily loss limit %% (0 = off)")
    ap.add_argument("--from", dest="date_from")
    ap.add_argument("--to", dest="date_to")
    ap.add_argument("--trades-out", help="write every trade to this CSV")
    a = ap.parse_args(argv)

    if a.demo:
        bars, daily = synthetic()
        print("SYNTHETIC DATA: checks the code only, says nothing about gold.")
    elif a.bars and a.daily:
        bars, daily = load_bars(a.bars), load_bars(a.daily)
    else:
        ap.error("give --bars and --daily, or --demo")
    if a.date_from:
        bars = bars[bars.time >= pd.Timestamp(a.date_from)].reset_index(drop=True)
    if a.date_to:
        bars = bars[bars.time < pd.Timestamp(a.date_to)].reset_index(drop=True)

    trades, equity, locked, p = run_backtest(bars, daily, dict(balance=a.balance, spread=a.spread, take_profit=a.tp,
                                                               stop_loss=a.sl, daily_loss_pct=a.daily_loss))
    report(trades, equity, locked, p)
    if a.trades_out and len(trades):
        trades.to_csv(a.trades_out, index=False)
        print(f"\nTrades written to {a.trades_out}")


if __name__ == "__main__":
    sys.exit(main())
