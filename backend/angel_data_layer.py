"""
AI-read data layer for Parmar Trading.

Adapted from the supplied Angel One data-layer design:
Angel candles -> normalization -> validation -> shared indicators ->
strategy evidence -> fixed-shape AI model input.

The repository already owns Angel login/session handling in angel_client.py, so this
module deliberately does NOT store or duplicate Angel credentials.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

import numpy as np
import pandas as pd

IST = "Asia/Kolkata"
COLS = ["time", "open", "high", "low", "close", "volume"]
INTERVALS = {
    "ONE_MINUTE": 1, "THREE_MINUTE": 3, "FIVE_MINUTE": 5,
    "TEN_MINUTE": 10, "FIFTEEN_MINUTE": 15, "THIRTY_MINUTE": 30,
    "ONE_HOUR": 60, "ONE_DAY": 1440,
}
INDEX_TOKENS = {
    "NIFTY": ("NSE", "99926000"),
    "BANKNIFTY": ("NSE", "99926009"),
    "FINNIFTY": ("NSE", "99926037"),
    "MIDCPNIFTY": ("NSE", "99926074"),
    "SENSEX": ("BSE", "99919000"),
}


class NotEnoughData(Exception):
    pass


class Normalizer:
    @staticmethod
    def _time(series: pd.Series) -> pd.Series:
        t = pd.to_datetime(series, errors="coerce")
        if getattr(t.dt, "tz", None) is None:
            try:
                return t.dt.tz_localize(IST)
            except Exception:
                return pd.to_datetime(series, errors="coerce", utc=True).dt.tz_convert(IST)
        return t.dt.tz_convert(IST)

    @staticmethod
    def clean(rows, interval: str, now: Optional[pd.Timestamp] = None) -> pd.DataFrame:
        if interval not in INTERVALS:
            raise ValueError("Unsupported interval")
        mins = INTERVALS[interval]
        df = pd.DataFrame(rows, columns=COLS)
        df["time"] = Normalizer._time(df["time"])
        for c in COLS[1:]:
            df[c] = pd.to_numeric(df[c], errors="coerce")
        df = df.dropna(subset=["time", "open", "high", "low", "close"])
        df = df[(df[["open", "high", "low", "close"]] > 0).all(axis=1)]
        df = df.sort_values("time").drop_duplicates("time", keep="last")
        df["high"] = df[["open", "high", "low", "close"]].max(axis=1)
        df["low"] = df[["open", "high", "low", "close"]].min(axis=1)
        df["volume"] = df["volume"].fillna(0).clip(lower=0)
        df = df.set_index("time")
        if mins < 1440:
            df = df.between_time("09:15", "15:29")
        now = now or pd.Timestamp.now(tz=IST)
        end = (
            df.index.normalize() + pd.Timedelta(hours=15, minutes=30)
            if mins == 1440 else df.index + pd.Timedelta(minutes=mins)
        )
        df["closed"] = end <= now
        df.attrs["interval"] = interval
        df.attrs["minutes"] = mins
        return df


def validate(df: pd.DataFrame) -> Dict:
    issues = []
    mins = df.attrs.get("minutes", 5)
    if df.empty:
        return {"ok": False, "issues": ["no candles"], "bars": 0}
    if not df.index.is_monotonic_increasing:
        issues.append("time not increasing")
    if df.index.duplicated().any():
        issues.append("duplicate timestamps")
    if mins < 1440 and len(df) > 1:
        d = df.index.to_series().diff()
        same_day = df.index.to_series().dt.date == df.index.to_series().shift().dt.date
        gaps = int(((d > pd.Timedelta(minutes=mins * 1.5)) & same_day).sum())
        if gaps:
            issues.append(f"{gaps} intraday gaps")
    zero_vol = float((df["volume"] == 0).mean())
    if zero_vol > 0.5:
        issues.append(f"volume missing in {zero_vol:.0%} bars (normal for indices)")
    if (df["high"] < df["low"]).any():
        issues.append("high < low")
    return {
        "ok": not [x for x in issues if "volume" not in x],
        "issues": issues,
        "bars": int(len(df)),
        "closed_bars": int(df["closed"].sum()),
        "zero_volume": zero_vol,
    }


def _rsi(df, n=14):
    d = df.close.diff()
    au = d.clip(lower=0).ewm(alpha=1 / n, adjust=False, min_periods=n).mean()
    ad = (-d.clip(upper=0)).ewm(alpha=1 / n, adjust=False, min_periods=n).mean()
    r = 100 - 100 / (1 + au / ad.replace(0, np.nan))
    r[(ad == 0) & (au > 0)] = 100
    return r


def _atr(df, n=14):
    pc = df.close.shift()
    tr = pd.concat(
        [df.high - df.low, (df.high - pc).abs(), (df.low - pc).abs()], axis=1
    ).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False, min_periods=n).mean()


def _macd(df, f=12, s=26, g=9):
    line = df.close.ewm(span=f, adjust=False, min_periods=s).mean() - df.close.ewm(
        span=s, adjust=False, min_periods=s
    ).mean()
    sig = line.ewm(span=g, adjust=False, min_periods=g).mean()
    return pd.DataFrame({"line": line, "signal": sig, "hist": line - sig})


def _bb(df, n=20, k=2.0):
    mid, sd = df.close.rolling(n).mean(), df.close.rolling(n).std(ddof=0)
    return pd.DataFrame({"mid": mid, "upper": mid + k * sd, "lower": mid - k * sd})


def _supertrend(df, n=10, m=3.0):
    atr = _atr(df, n)
    hl2 = (df.high + df.low) / 2
    c = df.close.values
    ub, lb = (hl2 + m * atr).values, (hl2 - m * atr).values
    fu, fl = ub.copy(), lb.copy()
    direction = np.ones(len(c))
    st = np.full(len(c), np.nan)
    if np.isnan(ub).all():
        return pd.DataFrame({"st": st, "dir": direction}, index=df.index)
    first = int(np.argmax(~np.isnan(ub)))
    st[first] = fl[first]
    for i in range(first + 1, len(c)):
        fu[i] = ub[i] if (ub[i] < fu[i - 1] or c[i - 1] > fu[i - 1]) else fu[i - 1]
        fl[i] = lb[i] if (lb[i] > fl[i - 1] or c[i - 1] < fl[i - 1]) else fl[i - 1]
        direction[i] = 1 if c[i] > fu[i - 1] else (-1 if c[i] < fl[i - 1] else direction[i - 1])
        st[i] = fl[i] if direction[i] == 1 else fu[i]
    return pd.DataFrame({"st": st, "dir": direction}, index=df.index)


FEATURES = {
    "sma": lambda df, n=20: df.close.rolling(n).mean(),
    "ema": lambda df, n=20: df.close.ewm(span=n, adjust=False, min_periods=n).mean(),
    "rsi": _rsi,
    "atr": _atr,
    "macd": _macd,
    "bb": _bb,
    "supertrend": _supertrend,
    "hh": lambda df, n=20: df.high.rolling(n).max(),
    "ll": lambda df, n=20: df.low.rolling(n).min(),
}


class FeatureStore:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self._cache = {}

    def get(self, name, **kwargs):
        key = (name, tuple(sorted(kwargs.items())))
        if key not in self._cache:
            self._cache[key] = FEATURES[name](self.df, **kwargs)
        return self._cache[key]

    @staticmethod
    def ok(*objects, k=2):
        for obj in objects:
            tail = obj.iloc[-k:]
            bad = tail.isna().any().any() if isinstance(tail, pd.DataFrame) else tail.isna().any()
            if len(obj) < k or bad:
                raise NotEnoughData("indicator warm-up")


@dataclass
class StrategySignal:
    name: str
    side: int
    strength: float
    reason: str


def run_strategies(df: pd.DataFrame) -> Dict:
    closed = df[df["closed"]]
    report = {"signals": [], "skipped": {}, "errors": {}, "total": 4}
    if closed.empty:
        report["skipped"]["runner"] = "no closed candles"
        return report
    fs = FeatureStore(closed)

    try:
        a, b = fs.get("ema", n=9), fs.get("ema", n=21)
        fs.ok(a, b)
        if a.iloc[-2] <= b.iloc[-2] and a.iloc[-1] > b.iloc[-1]:
            report["signals"].append(StrategySignal("ema_9_21_cross", 1, .6, "EMA9 crossed above EMA21"))
        elif a.iloc[-2] >= b.iloc[-2] and a.iloc[-1] < b.iloc[-1]:
            report["signals"].append(StrategySignal("ema_9_21_cross", -1, .6, "EMA9 crossed below EMA21"))
    except NotEnoughData as e:
        report["skipped"]["ema_9_21_cross"] = str(e)

    try:
        r = fs.get("rsi", n=14)
        fs.ok(r)
        if r.iloc[-2] < 30 <= r.iloc[-1]:
            report["signals"].append(StrategySignal("rsi_14_reversal", 1, .55, "RSI back above 30"))
        elif r.iloc[-2] > 70 >= r.iloc[-1]:
            report["signals"].append(StrategySignal("rsi_14_reversal", -1, .55, "RSI back below 70"))
    except NotEnoughData as e:
        report["skipped"]["rsi_14_reversal"] = str(e)

    try:
        st = fs.get("supertrend", n=10, m=3.0)
        fs.ok(st["st"])
        if st["dir"].iloc[-1] != st["dir"].iloc[-2]:
            report["signals"].append(
                StrategySignal("supertrend_10_3_flip", int(st["dir"].iloc[-1]), .7, "Supertrend flipped")
            )
    except NotEnoughData as e:
        report["skipped"]["supertrend_10_3_flip"] = str(e)

    report["skipped"]["vwap_reclaim"] = "needs volume (index volume may be unavailable)"
    report["signals"] = [s.__dict__ for s in report["signals"]]
    return report


def model_input(fs: FeatureStore, win=60):
    df, c = fs.df, fs.df.close
    atr, bb = fs.get("atr", n=14), fs.get("bb")
    f = pd.DataFrame({
        "ret": np.log(c).diff(),
        "rsi": fs.get("rsi", n=14) / 100 - .5,
        "macd": fs.get("macd")["hist"] / atr,
        "bbp": (c - bb["lower"]) / (bb["upper"] - bb["lower"]) - .5,
        "ema": (c / fs.get("ema", n=21) - 1) * 10,
        "rng": (df.high - df.low) / atr,
    }).replace([np.inf, -np.inf], np.nan).iloc[-win:]
    if len(f) < win or f.isna().any().any():
        return None
    return f.values.astype("float32")[None]


def _json_number(value):
    try:
        x = float(value)
        return round(x, 6) if np.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def build_ai_read(client, symbol="NIFTY", interval="FIVE_MINUTE", days=5):
    """Fetch clean Angel candles and return a JSON-safe AI-read packet.

    The caller supplies the existing authenticated backend AngelClient. No
    credentials are accepted here and nothing is suitable for APK embedding.
    """
    key = str(symbol or "NIFTY").upper().replace(" ", "")
    if key == "BANKNIFTY":
        key = "BANKNIFTY"
    elif key == "MIDCAPSELECT":
        key = "MIDCPNIFTY"
    exchange, token = INDEX_TOKENS.get(key, INDEX_TOKENS["NIFTY"])
    raw = client.candles(exchange, token, interval, max(1, min(int(days), 30)))
    rows = raw.get("data", []) if isinstance(raw, dict) else (raw or [])
    df = Normalizer.clean(rows, interval)
    validation = validate(df)
    closed = df[df["closed"]]
    fs = FeatureStore(closed)
    indicators = {}
    if not closed.empty:
        for name, kwargs in (("ema", {"n": 8}), ("ema", {"n": 13}), ("ema", {"n": 21}),
                             ("rsi", {"n": 14}), ("atr", {"n": 14})):
            series = fs.get(name, **kwargs)
            key_name = name + "_".join(str(v) for v in kwargs.values())
            indicators[key_name] = _json_number(series.iloc[-1]) if not series.empty else None
        macd = fs.get("macd")
        indicators["macd_hist"] = _json_number(macd["hist"].iloc[-1])
        bb = fs.get("bb")
        indicators["bb_mid"] = _json_number(bb["mid"].iloc[-1])
        indicators["bb_upper"] = _json_number(bb["upper"].iloc[-1])
        indicators["bb_lower"] = _json_number(bb["lower"].iloc[-1])

    strategies = run_strategies(df)
    model = model_input(fs) if len(closed) >= 60 else None
    latest = closed.iloc[-1] if not closed.empty else None
    return {
        "source": "Angel One SmartAPI -> AI Read data layer",
        "symbol": key,
        "exchange": exchange,
        "token": token,
        "interval": interval,
        "validation": validation,
        "latest": None if latest is None else {
            "time": latest.name.isoformat(),
            "open": _json_number(latest["open"]),
            "high": _json_number(latest["high"]),
            "low": _json_number(latest["low"]),
            "close": _json_number(latest["close"]),
            "volume": _json_number(latest["volume"]),
            "closed": bool(latest["closed"]),
        },
        "indicators": indicators,
        "strategies": strategies,
        "model_input": {
            "available": model is not None,
            "shape": list(model.shape) if model is not None else None,
            "features": ["return", "RSI", "MACD/ATR", "Bollinger position", "EMA21 ratio", "range/ATR"],
        },
        "close_series": [_json_number(x) for x in closed["close"].tail(240).tolist()],
        "high_series": [_json_number(x) for x in closed["high"].tail(240).tolist()],
        "low_series": [_json_number(x) for x in closed["low"].tail(240).tolist()],
        "volume_series": [_json_number(x) for x in closed["volume"].tail(240).tolist()],
        "rule": "Only supplied/live evidence is used. Missing or conflicting data must be treated as WAIT; this layer never places orders.",
    }
