#!/usr/bin/env python3
"""
Controlled Grid with early profits and early loss cuts, XAUUSD: backtest with plain pandas
(same rules as the EA, v12).

Rules
  Direction  Daily EMA 21 > EMA 55: buy grids only; EMA 21 < EMA 55: sell grids only.
             No new grid while the daily EMAs are flat or crossing
             (last two COMPLETED daily candles; "flat" = gap below 0.10 x ATR(D1, 14)).
  Grid       First 0.01 position as soon as the filter is valid; one more 0.01 every $3.00 against
             the last level; at most 8 levels per grid. Lot never changes.
  Exits      Each position: +$4 take profit, -$5 early loss cut (that position only).
             Basket: total floating +$12 -> close all; total floating -$18 -> close all.
             A grid ends when it has no open positions; the next grid starts right away.
  Risk       One grid at a time, never opposite. Daily loss limit 4%: no new grid that day.

Price model
  MT5 bid candles. Buys open at the ask (bid + spread) and close at the bid; sells the reverse.
  Inside a candle: open -> worst extreme -> best extreme -> close (adverse move first,
  conservative). Every trigger fires in the order the price reaches it; gaps fill at the open.
  0.01 lot of XAUUSD = 1 oz = $1 per $1 move.

Usage
  python3 tools/backtest_grid.py --bars XAUUSDm_M1.csv --daily XAUUSDm_D1.csv
  python3 tools/backtest_grid.py --demo      # synthetic prices: only checks the code runs
"""

import argparse
import sys

import numpy as np
import pandas as pd

DEFAULTS = dict(
    balance=500.0,
    ema_fast=21, ema_slow=55, flat_gap_atr=0.10,
    lot=0.01, spacing=3.00, max_levels=8,
    pos_tp=4.0, pos_cut=3.0, basket_tp=12.0, basket_stop=18.0,
    daily_loss_pct=4.0,
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
    usd = p["contract_size"] * p["lot"]              # USD per $1 move per position
    sp = p["spread"]
    filt = daily_filter(daily, bars["time"], p)
    t = bars["time"].values
    o, h, l, c = (bars[k].values for k in ("open", "high", "low", "close"))
    days = bars["time"].dt.normalize().values

    balance = p["balance"]
    closed, grids = [], []                           # closed positions, finished grids
    equity = np.empty(len(bars))
    g = None
    day, day_start, locked, locked_days = None, balance, False, 0

    # "y space": the grid profits when y rises (y = bid for buy grids, -bid for sell grids).
    # A position's entry is stored as its y at the fill; it closes at y - spread for sells.
    def open_y(y):   # y at which a level fills (buys pay the spread at entry)
        return y + (sp if g["dir"] > 0 else 0.0)

    def exit_off():  # sells pay the spread at exit
        return sp if g["dir"] < 0 else 0.0

    def pos_pnl(e, y):
        return (y - exit_off() - e) * usd

    def close_pos(k, y, reason, i):
        nonlocal balance
        e = g["open"].pop(k)
        pnl = pos_pnl(e, y)
        balance += pnl
        g["pnl"] += pnl
        closed.append(dict(time=t[i], side="BUY" if g["dir"] > 0 else "SELL", pnl=pnl, reason=reason))

    def end_grid(i, reason):
        nonlocal g
        grids.append(dict(start=g["start"], end=t[i], side="BUY" if g["dir"] > 0 else "SELL",
                          levels=g["levels"], pnl=round(g["pnl"], 2), reason=reason))
        g = None

    def leg(y, y_to, i):
        """Move from y to y_to, firing every trigger in the order the price reaches it."""
        while g is not None:
            n = len(g["open"])
            if n == 0:
                end_grid(i, g["last_exit"])
                return
            s = sum(g["open"])
            if y_to < y:                                   # adverse: levels, loss cuts, basket stop
                trig = [(e - p["pos_cut"] / usd + exit_off(), "loss cut", k) for k, e in enumerate(g["open"])]
                if p["basket_stop"] > 0:
                    trig.append(((s - p["basket_stop"] / usd) / n + exit_off(), "basket stop", -1))
                if g["levels"] < p["max_levels"]:
                    trig.append((g["last"] - p["spacing"] - (sp if g["dir"] > 0 else 0.0), "level", -1))
                lvl, what, k = max(trig)
                if lvl < y_to:
                    return
            else:                                          # favourable: take profits, basket TP
                trig = [(e + p["pos_tp"] / usd + exit_off(), "take profit", k) for k, e in enumerate(g["open"])]
                if p["basket_tp"] > 0:
                    trig.append(((s + p["basket_tp"] / usd) / n + exit_off(), "basket take profit", -1))
                lvl, what, k = min(trig)
                if lvl > y_to:
                    return
            y = min(lvl, y) if y_to < y else max(lvl, y)   # gap: fill at the current price
            if what == "level":
                e = open_y(y)
                g["open"].append(e)
                g["last"] = e
                g["levels"] += 1
            elif k >= 0:
                close_pos(k, y, what, i)
                g["last_exit"] = what
            else:                                          # basket exit
                for j in range(len(g["open"]) - 1, -1, -1):
                    close_pos(j, y, what, i)
                end_grid(i, what)
                return

    for i in range(len(bars)):
        if days[i] != day:
            day, day_start, locked = days[i], balance, False

        if g is not None:
            d = g["dir"]
            yo, yc = d * o[i], d * c[i]
            ylo, yhi = (l[i], h[i]) if d > 0 else (-h[i], -l[i])
            for a, b in ((yo, yo - 1e-9), (yo, ylo), (ylo, yhi), (yhi, yc)):
                if g is None:
                    break
                leg(a, b, i)

        if g is None:
            if p["daily_loss_pct"] > 0 and not locked and balance - day_start <= -day_start * p["daily_loss_pct"] / 100:
                locked, locked_days = True, locked_days + 1
            if not locked and filt[i] != 0:
                d = int(filt[i])
                g = dict(dir=d, start=t[i], open=[], levels=1, pnl=0.0, last_exit="")
                e = open_y(d * c[i])
                g["open"].append(e)
                g["last"] = e

        if g is None:
            equity[i] = balance
        else:
            equity[i] = balance + sum(pos_pnl(e, g["dir"] * c[i]) for e in g["open"])

    if g is not None:
        for j in range(len(g["open"]) - 1, -1, -1):
            close_pos(j, g["dir"] * c[-1], "end of data", len(bars) - 1)
        end_grid(len(bars) - 1, "end of data")
    return pd.DataFrame(grids), pd.DataFrame(closed), pd.Series(equity, index=bars["time"]), locked_days, p


def report(grids, positions, equity, locked_days, p):
    print(f"\nControlled Grid   start {p['balance']:.2f}   lot {p['lot']}   spacing {p['spacing']}   levels {p['max_levels']}   "
          f"pos +{p['pos_tp']}/-{p['pos_cut']}   basket +{p['basket_tp']}/-{p['basket_stop']}")
    if len(equity):
        print(f"Period: {equity.index[0]}  to  {equity.index[-1]}")
    print("-" * 50)
    if len(grids) == 0:
        print("No grids opened.")
        return
    wins, losses = positions[positions.pnl > 0], positions[positions.pnl <= 0]
    peak = equity.cummax()
    rows = [
        ("Grids", len(grids)),
        ("Positions", len(positions)),
        ("Net profit", positions.pnl.sum()),
        ("Final balance", p["balance"] + positions.pnl.sum()),
        ("Return %", positions.pnl.sum() / p["balance"] * 100),
        ("Position win rate %", len(wins) / len(positions) * 100),
        ("Grid win rate %", (grids.pnl > 0).mean() * 100),
        ("Profit factor", wins.pnl.sum() / -losses.pnl.sum() if losses.pnl.sum() < 0 else float("inf")),
        ("Average win", wins.pnl.mean() if len(wins) else 0.0),
        ("Average loss", losses.pnl.mean() if len(losses) else 0.0),
        ("Worst grid", grids.pnl.min()),
        ("Max drawdown $", (peak - equity).max()),
        ("Max drawdown %", ((peak - equity) / peak).max() * 100),
        ("Days stopped by 4% limit", locked_days),
    ]
    for k, v in rows:
        print(f"{k:<28}{v:>14.2f}" if isinstance(v, float) else f"{k:<28}{v:>14}")
    print("\nPosition exits:")
    for r, x in positions.groupby("reason"):
        print(f"  {r:<22}{len(x):>7}   {x.pnl.sum():>10.2f}")
    print("\nLevels used per grid:")
    for n, x in grids.groupby("levels"):
        print(f"  {n} level(s)            {len(x):>7}   {x.pnl.sum():>10.2f}")
    print("\nBy side:")
    for s_, x in grids.groupby("side"):
        print(f"  {s_:<22}{len(x):>7}   {x.pnl.sum():>10.2f}")


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
    ap.add_argument("--bars", help="M1 CSV from ExportBars")
    ap.add_argument("--daily", help="D1 CSV from ExportBars")
    ap.add_argument("--demo", action="store_true", help="synthetic prices (code check only)")
    ap.add_argument("--balance", type=float, default=DEFAULTS["balance"])
    ap.add_argument("--spread", type=float, default=DEFAULTS["spread"])
    ap.add_argument("--daily-loss", type=float, default=DEFAULTS["daily_loss_pct"], help="%% (0 = off)")
    ap.add_argument("--from", dest="date_from")
    ap.add_argument("--to", dest="date_to")
    ap.add_argument("--grids-out", help="write every grid to this CSV")
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

    grids, positions, equity, locked, p = run_backtest(
        bars, daily, dict(balance=a.balance, spread=a.spread, daily_loss_pct=a.daily_loss))
    report(grids, positions, equity, locked, p)
    if a.grids_out and len(grids):
        grids.to_csv(a.grids_out, index=False)
        print(f"\nGrids written to {a.grids_out}")


if __name__ == "__main__":
    sys.exit(main())
