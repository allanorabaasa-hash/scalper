#!/usr/bin/env python3
"""
Controlled Directional Grid for XAUUSD: backtest with plain pandas (same rules as the EA).

Rules
  Direction  Daily EMA 21 > EMA 55: buy grids only; EMA 21 < EMA 55: sell grids only.
             No new grid while the daily EMAs are flat or crossing.
             (Last two COMPLETED daily candles. "Crossing" = EMA 21 - EMA 55 changed sign between them.
              "Flat" = gap below 0.10 x ATR(D1, 14). Both adjustable.)
  Grid       First position as soon as the filter is valid and no grid is open.
             One more 0.01 position every $4.50 against the grid, 5 levels maximum. Lot never changes.
  Exits      Basket take profit: total floating profit >= +$20  -> close all.
             Basket stop:        total floating loss   >= -$30  -> close all (the user's 5-6% cap).
             Hard stop:          price $18 beyond the last level -> close all.
  Risk       One grid at a time, never opposite grids.
             Daily loss limit: no new grid for the rest of the day once the day is down 4%.
  The bot keeps opening new grids after each close until stopped.

Price model
  Data = MT5 bid candles. Buys open at the ask (bid + spread) and close at the bid; sells the reverse.
  Inside a candle the price is assumed to go open -> worst extreme -> best extreme -> close
  (adverse move first, the conservative choice). Fills happen at the trigger price, or at the
  candle open when the price gapped past it. 0.01 lot of XAUUSD = 1 oz = $1 per $1 move.

Data: export M1 and D1 bars with the ExportBars script in MT5 (Common/Files/<symbol>_M1.csv, _D1.csv).

Usage
  python3 tools/backtest_grid.py --bars XAUUSDm_M1.csv --daily XAUUSDm_D1.csv
  python3 tools/backtest_grid.py --bars XAUUSDm_M1.csv --daily XAUUSDm_D1.csv --from 2026-08-01 --grids-out grids.csv
  python3 tools/backtest_grid.py --demo     # synthetic prices: only checks that the code runs
"""

import argparse
import sys

import numpy as np
import pandas as pd

DEFAULTS = dict(
    balance=500.0,
    ema_fast=21, ema_slow=55, flat_gap_atr=0.10,
    lot=0.01, spacing=4.50, max_levels=5,
    basket_tp=20.0, basket_stop=30.0, hard_stop=18.0,
    daily_loss_pct=4.0,
    contract_size=100.0,     # oz per lot
    spread=0.25,             # USD (Exness XAUUSDm about 0.20-0.30)
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
    usd = p["contract_size"] * p["lot"]          # USD per $1 move per position
    sp = p["spread"]
    filt = daily_filter(daily, bars["time"], p)
    t = bars["time"].values
    o, h, l, c = (bars[k].values for k in ("open", "high", "low", "close"))
    days = bars["time"].dt.normalize().values

    balance = p["balance"]
    grids, equity = [], np.empty(len(bars))
    g = None                                    # active grid
    day, day_start, day_locked, locked_days = None, balance, False, 0

    # In "y space" every grid profits when y rises: y = bid for buy grids, -bid for sell grids.
    def entry_y(y, d):     # y-value at which a level opens (buys pay the spread)
        return y + (sp if d > 0 else 0.0)

    def close_y(y, d):     # y-value at which positions close (sells pay the spread)
        return y - (sp if d < 0 else 0.0)

    def floating(y):
        return sum(close_y(y, g["dir"]) - e for e in g["entries"]) * usd

    def finish(y, reason, i):
        nonlocal balance, g
        pnl = floating(y)
        balance += pnl
        grids.append(dict(start=g["start"], end=t[i], side="BUY" if g["dir"] > 0 else "SELL",
                          levels=len(g["entries"]), pnl=round(pnl, 2), reason=reason))
        g = None

    def leg(y_from, y_to, i):
        """Move the price from y_from to y_to and fire every trigger in the order it is reached."""
        y = y_from
        while g is not None:
            d, n = g["dir"], len(g["entries"])
            avg = sum(g["entries"]) / n
            if y_to < y:                                       # adverse move
                trig = []
                if n < p["max_levels"]:
                    trig.append((g["entries"][-1] - p["spacing"] - (sp if d > 0 else 0.0), "level"))
                if p["basket_stop"] > 0:
                    trig.append((avg - p["basket_stop"] / (n * usd) + (sp if d < 0 else 0.0), "basket stop"))
                trig.append((g["entries"][-1] - p["hard_stop"] + (sp if d < 0 else 0.0), "hard stop"))
                level, what = max(trig)                         # first one reached when falling
                if level < y_to:
                    return
                y = min(level, y)                               # gap: fill at the current price
                if what == "level":
                    g["entries"].append(entry_y(y, d))
                else:
                    finish(y, what, i)
                    return
            else:                                              # favourable move
                level = avg + p["basket_tp"] / (n * usd) + (sp if d < 0 else 0.0)
                if level > y_to:
                    return
                finish(max(level, y), "basket take profit", i)
                return

    for i in range(len(bars)):
        if days[i] != day:                                     # new server day
            day, day_start, day_locked = days[i], balance, False

        if g is not None:
            d = g["dir"]
            yo, yc = d * o[i], d * c[i]
            ylo, yhi = (l[i], h[i]) if d > 0 else (-h[i], -l[i])
            leg(yo, yo, i)                                     # gap at the open
            for a, b in ((yo, ylo), (ylo, yhi), (yhi, yc)):
                if g is None:
                    break
                leg(a, b, i)

        # new grid at the close of this candle (repeats after every close)
        if g is None:
            if not day_locked and balance - day_start <= -day_start * p["daily_loss_pct"] / 100.0:
                day_locked, locked_days = True, locked_days + 1
            if not day_locked and filt[i] != 0:
                d = int(filt[i])
                g = dict(dir=d, start=t[i], entries=[entry_y(d * c[i], d)])

        equity[i] = balance + (floating(g["dir"] * c[i]) if g is not None else 0.0)

    if g is not None:
        finish(g["dir"] * c[-1], "end of data", len(bars) - 1)
    return pd.DataFrame(grids), pd.Series(equity, index=bars["time"]), locked_days, p


# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
def report(grids, equity, locked_days, p):
    print(f"\nControlled Directional Grid   start {p['balance']:.2f}   lot {p['lot']}   spacing {p['spacing']}   "
          f"levels {p['max_levels']}   TP +{p['basket_tp']}   stop -{p['basket_stop']}   hard {p['hard_stop']}")
    if len(equity):
        print(f"Period: {equity.index[0]}  to  {equity.index[-1]}")
    print("-" * 50)
    if len(grids) == 0:
        print("No grids opened.")
        return
    wins, losses = grids[grids.pnl > 0], grids[grids.pnl <= 0]
    peak = equity.cummax()
    streak = longest = 0
    for x in grids.pnl:
        streak = streak + 1 if x <= 0 else 0
        longest = max(longest, streak)
    rows = [
        ("Grids", len(grids)),
        ("Net profit", grids.pnl.sum()),
        ("Final balance", p["balance"] + grids.pnl.sum()),
        ("Return %", grids.pnl.sum() / p["balance"] * 100),
        ("Win rate %", len(wins) / len(grids) * 100),
        ("Profit factor", wins.pnl.sum() / -losses.pnl.sum() if losses.pnl.sum() < 0 else float("inf")),
        ("Average win", wins.pnl.mean() if len(wins) else 0.0),
        ("Average loss", losses.pnl.mean() if len(losses) else 0.0),
        ("Biggest loss", grids.pnl.min()),
        ("Max drawdown $", (peak - equity).max()),
        ("Max drawdown %", ((peak - equity) / peak).max() * 100),
        ("Max losing grids in a row", longest),
        ("Days stopped by 4% limit", locked_days),
    ]
    for k, v in rows:
        print(f"{k:<28}{v:>14.2f}" if isinstance(v, float) else f"{k:<28}{v:>14}")
    print("\nExits:")
    for r, x in grids.groupby("reason"):
        print(f"  {r:<22}{len(x):>6} grids   {x.pnl.sum():>10.2f}")
    print("\nLevels used:")
    for n, x in grids.groupby("levels"):
        print(f"  {n} level(s)            {len(x):>6} grids   {x.pnl.sum():>10.2f}")
    print("\nBy side:")
    for s, x in grids.groupby("side"):
        print(f"  {s:<22}{len(x):>6} grids   {x.pnl.sum():>10.2f}   win {100 * (x.pnl > 0).mean():.0f}%")


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
    ap.add_argument("--basket-stop", type=float, default=DEFAULTS["basket_stop"], help="0 = off (rules as written)")
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

    grids, equity, locked, p = run_backtest(bars, daily, dict(balance=a.balance, spread=a.spread,
                                                              basket_stop=a.basket_stop))
    report(grids, equity, locked, p)
    if a.grids_out and len(grids):
        grids.to_csv(a.grids_out, index=False)
        print(f"\nGrids written to {a.grids_out}")


if __name__ == "__main__":
    sys.exit(main())
