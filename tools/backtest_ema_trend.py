#!/usr/bin/env python3
"""
EMA 21/55 trend strategy for XAUUSD: backtest with plain pandas.

Rules (as specified by the user, not changed):
  Entry   long : EMA21 crosses above EMA55 on a closed candle AND the candle closes above both EMAs.
          short: EMA21 crosses below EMA55 on a closed candle AND the candle closes below both EMAs.
          Enter at the close of that candle.
  Filter  only in the direction of the daily trend (previous completed day: EMA21 vs EMA55).
          Skip the trade if ATR(14) is extremely low (definition below, adjustable).
  Stop    initial stop = 1.5 x ATR(14) from the entry price.
  Trail   once price has moved 1 x ATR in profit, trail the stop 2 x ATR behind the best price.
          The stop only moves in the trade's favour.
  Exit    trailing/initial stop, or an opposite signal. No take profit.
  Size    risk 1% of the account per trade; lots for XAUUSD (100 oz per lot).

Choices this script has to make because the rules leave them open (all are parameters):
  * "ATR extremely low" = ATR(14) below 50% of its own 100-bar average  (--min-atr-ratio).
  * The ATR used for stop, trigger and trail is the ATR of the signal candle (fixed for the trade).
  * "Best price" for the trail = highest high (long) / lowest low (short) since entry.
  * An opposite crossover closes the trade even when the daily filter would block a new entry
    in that direction; a new trade is then opened only if the filter allows it.
  * Lots are rounded DOWN to the lot step. If even the minimum lot risks more than 1%,
    the trade is skipped (counted as "skipped: min lot too big").
  * ATR uses a simple average of the true range, like MT5's ATR indicator.
  * Prices in MT5 exports are bid prices. Longs pay the spread on entry, shorts on exit.

Data: CSV files with columns time,open,high,low,close (export them from MT5 with the
ExportBars script in this repo). You need the trading timeframe and D1 for the filter.

Usage:
  python3 tools/backtest_ema_trend.py --bars XAUUSDm_M5.csv --daily XAUUSDm_D1.csv
  python3 tools/backtest_ema_trend.py --bars XAUUSDm_H4.csv --daily XAUUSDm_D1.csv --balance 500
  python3 tools/backtest_ema_trend.py --demo        # synthetic prices, only to check the code runs
"""

import argparse
import math
import sys

import numpy as np
import pandas as pd


# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
DEFAULTS = dict(
    balance=500.0,        # starting account balance (USD)
    risk_pct=1.0,         # % of balance risked per trade
    ema_fast=21,
    ema_slow=55,
    atr_period=14,
    sl_atr=1.5,           # initial stop distance in ATR
    trail_start_atr=1.0,  # start trailing after this much profit (ATR)
    trail_atr=2.0,        # trailing distance (ATR)
    min_atr_ratio=0.5,    # skip when ATR < ratio x 100-bar average ATR (0 = filter off)
    atr_avg_period=100,
    contract_size=100.0,  # XAUUSD: 1 lot = 100 oz, so a 1.00 USD move = 100 USD per lot
    min_lot=0.01,
    lot_step=0.01,
    max_lot=100.0,
    spread=0.25,          # USD per oz (Exness XAUUSDm is about 0.20-0.30)
    commission_per_lot=0.0,  # round turn, USD per lot (0 on Exness Standard)
)


# ----------------------------------------------------------------------------
# Indicators
# ----------------------------------------------------------------------------
def ema(series: pd.Series, period: int) -> pd.Series:
    """Exponential moving average, alpha = 2 / (period + 1), as MT5's EMA."""
    return series.ewm(span=period, adjust=False).mean()


def atr(df: pd.DataFrame, period: int) -> pd.Series:
    """Average true range: simple average of the true range (MT5's ATR indicator)."""
    prev_close = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"],
                    (df["high"] - prev_close).abs(),
                    (df["low"] - prev_close).abs()], axis=1).max(axis=1)
    return tr.rolling(period).mean()


def load_bars(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    df["time"] = pd.to_datetime(df["time"])
    df = df.sort_values("time").drop_duplicates("time").reset_index(drop=True)
    return df[["time", "open", "high", "low", "close"]]


def daily_trend(daily: pd.DataFrame, bar_times: pd.Series, p: dict) -> pd.Series:
    """+1 / -1 / 0 for each bar, from the last COMPLETED daily candle (no look-ahead)."""
    d = daily.copy()
    d["fast"] = ema(d["close"], p["ema_fast"])
    d["slow"] = ema(d["close"], p["ema_slow"])
    d["trend"] = np.sign(d["fast"] - d["slow"])
    d.loc[d.index < p["ema_slow"], "trend"] = 0          # EMA55 not warmed up yet
    # A daily candle opened at day D is complete at D + 1 day.
    d["available"] = d["time"].dt.normalize() + pd.Timedelta(days=1)
    left = pd.DataFrame({"time": bar_times})
    merged = pd.merge_asof(left, d[["available", "trend"]].sort_values("available"),
                           left_on="time", right_on="available", direction="backward")
    return merged["trend"].fillna(0).astype(int)


# ----------------------------------------------------------------------------
# Position sizing for XAUUSD
# ----------------------------------------------------------------------------
def position_size(balance: float, risk_pct: float, stop_dist: float, p: dict):
    """
    Lots so that hitting the stop loses risk_pct % of the balance.

    Loss at the stop = stop_dist (USD per oz) x contract_size (oz per lot) x lots + commission.
    (The spread is already in the entry price: longs buy at the ask, shorts close at the ask.)
    Example: balance 500, risk 1% -> 5 USD. Stop 3.00 USD away:
             loss per lot = 3.00 x 100 = 300 USD -> 5 / 300 = 0.0167 -> 0.01 lot (risk 3.00 USD).
    Returns (lots, reason). lots = 0 when the trade must be skipped.
    """
    risk_money = balance * risk_pct / 100.0
    loss_per_lot = stop_dist * p["contract_size"] + p["commission_per_lot"]
    if loss_per_lot <= 0:
        return 0.0, "bad stop"
    raw = risk_money / loss_per_lot
    lots = math.floor(raw / p["lot_step"] + 1e-9) * p["lot_step"]
    lots = min(round(lots, 2), p["max_lot"])
    if lots < p["min_lot"]:
        return 0.0, "min lot too big"
    return lots, ""


# ----------------------------------------------------------------------------
# Backtest
# ----------------------------------------------------------------------------
def prepare(bars: pd.DataFrame, daily: pd.DataFrame, p: dict) -> pd.DataFrame:
    df = bars.copy()
    df["fast"] = ema(df["close"], p["ema_fast"])
    df["slow"] = ema(df["close"], p["ema_slow"])
    df["atr"] = atr(df, p["atr_period"])
    df["atr_avg"] = df["atr"].rolling(p["atr_avg_period"]).mean()
    up = (df["fast"] > df["slow"]) & (df["fast"].shift(1) <= df["slow"].shift(1))
    dn = (df["fast"] < df["slow"]) & (df["fast"].shift(1) >= df["slow"].shift(1))
    df["long_sig"] = up & (df["close"] > df["fast"]) & (df["close"] > df["slow"])
    df["short_sig"] = dn & (df["close"] < df["fast"]) & (df["close"] < df["slow"])
    df["day_trend"] = daily_trend(daily, df["time"], p).values
    warm = max(p["ema_slow"], p["atr_period"], p["atr_avg_period"])
    df.loc[df.index < warm, ["long_sig", "short_sig"]] = False
    return df


def run_backtest(bars: pd.DataFrame, daily: pd.DataFrame, params: dict = None):
    p = dict(DEFAULTS, **(params or {}))
    df = prepare(bars, daily, p)
    sp = p["spread"]

    balance = p["balance"]
    trades, skipped = [], {}
    pos = None          # open trade
    equity_curve = []

    def close_trade(i, price, reason):
        nonlocal balance, pos
        d = pos["dir"]
        pnl = d * (price - pos["entry"]) * p["contract_size"] * pos["lots"] - p["commission_per_lot"] * pos["lots"]
        balance += pnl
        trades.append(dict(entry_time=pos["time"], exit_time=df.at[i, "time"], side="BUY" if d > 0 else "SELL",
                           lots=pos["lots"], entry=pos["entry"], exit=price, stop_dist=pos["stop_dist"],
                           pnl=pnl, r=pnl / pos["risk_money"], reason=reason, bars=i - pos["i"]))
        pos = None

    for i in range(len(df)):
        o, h, l, c = df.at[i, "open"], df.at[i, "high"], df.at[i, "low"], df.at[i, "close"]

        # 1. stop hit during this bar (stop set from earlier bars only)
        if pos is not None:
            if pos["dir"] > 0 and l <= pos["stop"]:                 # long exits at the bid
                close_trade(i, min(o, pos["stop"]), "trailing stop" if pos["trailing"] else "stop loss")
            elif pos["dir"] < 0 and h + sp >= pos["stop"]:          # short exits at the ask
                close_trade(i, max(o + sp, pos["stop"]), "trailing stop" if pos["trailing"] else "stop loss")

        # 2. update the trailing stop with this bar's extreme (applies from the next bar)
        if pos is not None:
            a = pos["atr"]
            if pos["dir"] > 0:
                pos["best"] = max(pos["best"], h)
                if pos["best"] - pos["entry"] >= p["trail_start_atr"] * a:
                    pos["trailing"] = True
                if pos["trailing"]:
                    pos["stop"] = max(pos["stop"], pos["best"] - p["trail_atr"] * a)
            else:
                pos["best"] = min(pos["best"], l + sp)
                if pos["entry"] - pos["best"] >= p["trail_start_atr"] * a:
                    pos["trailing"] = True
                if pos["trailing"]:
                    pos["stop"] = min(pos["stop"], pos["best"] + p["trail_atr"] * a)

        # 3. signals at the close of this bar
        sig = 1 if df.at[i, "long_sig"] else (-1 if df.at[i, "short_sig"] else 0)
        if sig != 0 and pos is not None and pos["dir"] == -sig:
            close_trade(i, c + (sp if pos["dir"] < 0 else 0.0), "opposite signal")

        if sig != 0 and pos is None:
            a = df.at[i, "atr"]
            if df.at[i, "day_trend"] != sig:
                skipped["against daily trend"] = skipped.get("against daily trend", 0) + 1
            elif p["min_atr_ratio"] > 0 and a < p["min_atr_ratio"] * df.at[i, "atr_avg"]:
                skipped["ATR extremely low"] = skipped.get("ATR extremely low", 0) + 1
            else:
                stop_dist = p["sl_atr"] * a
                lots, why = position_size(balance, p["risk_pct"], stop_dist, p)
                if lots == 0:
                    skipped[why] = skipped.get(why, 0) + 1
                else:
                    entry = c + sp if sig > 0 else c                 # buy at the ask, sell at the bid
                    pos = dict(i=i, time=df.at[i, "time"], dir=sig, lots=lots, entry=entry, atr=a,
                               stop=entry - sig * stop_dist, stop_dist=stop_dist, best=entry, trailing=False,
                               risk_money=balance * p["risk_pct"] / 100.0)

        # equity at the close (bid for longs, ask for shorts)
        float_pnl = 0.0
        if pos is not None:
            mark = c if pos["dir"] > 0 else c + sp
            float_pnl = pos["dir"] * (mark - pos["entry"]) * p["contract_size"] * pos["lots"]
        equity_curve.append((df.at[i, "time"], balance + float_pnl))

    if pos is not None:
        close_trade(len(df) - 1, df.at[len(df) - 1, "close"] + (sp if pos["dir"] < 0 else 0.0), "end of data")

    trades = pd.DataFrame(trades)
    equity = pd.DataFrame(equity_curve, columns=["time", "equity"]).set_index("time")["equity"]
    return trades, equity, skipped, p


# ----------------------------------------------------------------------------
# Metrics
# ----------------------------------------------------------------------------
def metrics(trades: pd.DataFrame, equity: pd.Series, start_balance: float) -> dict:
    m = {"Trades": len(trades)}
    if len(trades) == 0:
        return m
    wins, losses = trades[trades.pnl > 0], trades[trades.pnl <= 0]
    gross_win, gross_loss = wins.pnl.sum(), -losses.pnl.sum()
    peak = equity.cummax()
    dd = equity - peak
    streak = longest = 0
    for x in trades.pnl:
        streak = streak + 1 if x <= 0 else 0
        longest = max(longest, streak)
    m.update({
        "Net profit": trades.pnl.sum(),
        "Return %": (equity.iloc[-1] / start_balance - 1) * 100,
        "Final balance": start_balance + trades.pnl.sum(),
        "Win rate %": len(wins) / len(trades) * 100,
        "Profit factor": gross_win / gross_loss if gross_loss > 0 else float("inf"),
        "Average win": wins.pnl.mean() if len(wins) else 0.0,
        "Average loss": losses.pnl.mean() if len(losses) else 0.0,
        "Expectancy (R)": trades.r.mean(),
        "Expectancy ($)": trades.pnl.mean(),
        "Max drawdown $": -dd.min(),
        "Max drawdown %": -(dd / peak).min() * 100,
        "Max losses in a row": longest,
        "Average bars held": trades.bars.mean(),
    })
    return m


def print_report(trades, equity, skipped, p):
    m = metrics(trades, equity, p["balance"])
    print(f"\nEMA {p['ema_fast']}/{p['ema_slow']} trend strategy   start {p['balance']:.2f}   "
          f"risk {p['risk_pct']}%   spread {p['spread']}")
    if len(equity):
        print(f"Period: {equity.index[0]}  to  {equity.index[-1]}")
    print("-" * 46)
    for k, v in m.items():
        print(f"{k:<24}{v:>14.2f}" if isinstance(v, float) else f"{k:<24}{v:>14}")
    if len(trades):
        print("\nExits:")
        for reason, g in trades.groupby("reason"):
            print(f"  {reason:<20}{len(g):>5} trades   {g.pnl.sum():>10.2f}")
        print("\nBy side:")
        for side, g in trades.groupby("side"):
            print(f"  {side:<20}{len(g):>5} trades   {g.pnl.sum():>10.2f}   win {100 * (g.pnl > 0).mean():.0f}%")
    if skipped:
        print("\nSignals skipped:")
        for k, v in skipped.items():
            print(f"  {k:<26}{v:>5}")


# ----------------------------------------------------------------------------
# Synthetic data (only to check that the code runs; NOT gold prices)
# ----------------------------------------------------------------------------
def synthetic(n_days=400, bars_per_day=288, seed=1):
    rng = np.random.default_rng(seed)
    n = n_days * bars_per_day
    drift = np.repeat(rng.normal(0, 0.0004, n_days // 20 + 1), 20 * bars_per_day)[:n] / bars_per_day * 50
    ret = drift + rng.normal(0, 0.0006, n)
    close = 2600 * np.exp(np.cumsum(ret))
    open_ = np.concatenate([[close[0]], close[:-1]])
    noise = np.abs(rng.normal(0, 0.0004, n)) * close
    t = pd.date_range("2025-01-01", periods=n, freq="5min")
    bars = pd.DataFrame({"time": t, "open": open_, "high": np.maximum(open_, close) + noise,
                         "low": np.minimum(open_, close) - noise, "close": close})
    daily = bars.set_index("time").resample("1D").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna().reset_index()
    return bars, daily


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bars", help="CSV of the trading timeframe (H4, M5, M1...)")
    ap.add_argument("--daily", help="CSV of D1 bars for the trend filter")
    ap.add_argument("--demo", action="store_true", help="run on synthetic prices")
    ap.add_argument("--balance", type=float, default=DEFAULTS["balance"])
    ap.add_argument("--risk", type=float, default=DEFAULTS["risk_pct"])
    ap.add_argument("--spread", type=float, default=DEFAULTS["spread"])
    ap.add_argument("--min-atr-ratio", type=float, default=DEFAULTS["min_atr_ratio"])
    ap.add_argument("--from", dest="date_from", help="start date, e.g. 2026-01-01")
    ap.add_argument("--to", dest="date_to", help="end date")
    ap.add_argument("--trades-out", help="write the trade list to this CSV")
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

    trades, equity, skipped, p = run_backtest(bars, daily, dict(
        balance=a.balance, risk_pct=a.risk, spread=a.spread, min_atr_ratio=a.min_atr_ratio))
    print_report(trades, equity, skipped, p)
    if a.trades_out and len(trades):
        trades.to_csv(a.trades_out, index=False)
        print(f"\nTrades written to {a.trades_out}")


if __name__ == "__main__":
    sys.exit(main())
