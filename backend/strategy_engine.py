"""Deterministic JSON strategy engine.
AI may compose only allow-listed condition blocks; it never supplies executable code.
Paper/backtest only: no order placement.
"""
from __future__ import annotations
import math, statistics
from dataclasses import dataclass
from datetime import datetime
from typing import Any

DECISIONS = {"CALL BUY", "PUT BUY", "WAIT", "NO QUALIFYING TRADE"}
ALLOWED_BLOCKS = {
    "sweep_low", "sweep_high", "long_buildup", "short_buildup",
    "short_covering", "long_unwinding", "price>vwap", "price<vwap",
    "pcr>1", "pcr<1", "prev_high_break", "prev_low_break",
    "price>prev_high", "price<prev_low", "volume_spike",
    "oi_spike", "trend_up", "trend_down", "support_hold", "resistance_reject",
    "data_fresh", "option_liquid", "rr_ok",
}
TIME_FMT = "%H:%M"

class StrategyError(ValueError):
    pass

def _clock(value: Any) -> str:
    if isinstance(value, datetime):
        return value.strftime(TIME_FMT)
    if isinstance(value, (int, float)):
        try:
            # Live API timestamps are Unix seconds; strategy time filters use IST.
            from datetime import timezone, timedelta
            ist = timezone(timedelta(hours=5, minutes=30))
            return datetime.fromtimestamp(float(value), tz=ist).strftime(TIME_FMT)
        except (OverflowError, OSError, ValueError):
            return ""
    text = str(value or "")
    if "T" in text:
        text = text.split("T", 1)[1]
    return text[:5]

def _num(v: Any) -> float | None:
    try:
        if v is None or v == "":
            return None
        return float(v)
    except (TypeError, ValueError):
        return None

def validate_strategy(strategy: dict) -> dict:
    if not isinstance(strategy, dict):
        raise StrategyError("strategy must be an object")
    required = ("id", "index", "tf", "entry_call", "entry_put", "block_if", "sl", "target", "time_filter")
    missing = [x for x in required if x not in strategy]
    if missing:
        raise StrategyError("missing fields: " + ",".join(missing))
    if not str(strategy["id"]).strip():
        raise StrategyError("id is required")
    if str(strategy["tf"]).lower() not in {"1m","2m","3m","5m","10m","15m","30m","1h","2h","4h","1d"}:
        raise StrategyError("unsupported timeframe")
    for field in ("entry_call", "entry_put", "block_if"):
        vals = strategy[field]
        if not isinstance(vals, list):
            raise StrategyError(f"{field} must be a list")
        unknown = [str(x) for x in vals if str(x) not in ALLOWED_BLOCKS]
        if unknown:
            raise StrategyError(f"unknown condition block(s): {','.join(unknown)}")
    if not str(strategy["sl"]).strip() or not str(strategy["target"]).strip():
        raise StrategyError("SL and target are mandatory")
    tf = str(strategy["time_filter"])
    if "-" not in tf:
        raise StrategyError("time_filter must be HH:MM-HH:MM")
    return strategy

def _condition(name: str, s: dict) -> bool:
    if name == "pcr>1": return (_num(s.get("pcr")) or 0) > 1
    if name == "pcr<1": return (_num(s.get("pcr")) or 0) < 1
    if name in {"price>vwap", "price<vwap"}:
        p, v = _num(s.get("price")), _num(s.get("vwap"))
        return p is not None and v is not None and (p > v if name == "price>vwap" else p < v)
    if name in {"price>prev_high","prev_high_break"}:
        p, h = _num(s.get("price")), _num(s.get("prev_high"))
        return p is not None and h is not None and p > h
    if name in {"price<prev_low","prev_low_break"}:
        p, l = _num(s.get("price")), _num(s.get("prev_low"))
        return p is not None and l is not None and p < l
    if name in {"sweep_low","sweep_high","long_buildup","short_buildup","short_covering","long_unwinding",
                "volume_spike","oi_spike","trend_up","trend_down","support_hold","resistance_reject",
                "data_fresh","option_liquid","rr_ok"}:
        return bool(s.get(name))
    return False

def _time_ok(filter_text: str, timestamp: Any) -> bool:
    try:
        start, end = [x.strip() for x in str(filter_text).split("-", 1)]
        cur = _clock(timestamp)
        return start <= cur <= end
    except Exception:
        return False

def evaluate_strategy(strategy: dict, state: dict) -> dict:
    validate_strategy(strategy)
    state = state if isinstance(state, dict) else {}
    if not _time_ok(strategy["time_filter"], state.get("timestamp", state.get("ts"))):
        return {"decision":"WAIT","reason":"TIME_FILTER","matched":[],"blocked":[]}
    if not _condition("data_fresh", state):
        return {"decision":"NO QUALIFYING TRADE","reason":"DATA_STALE_OR_MISSING","matched":[],"blocked":["data_fresh"]}
    blocked = [x for x in strategy["block_if"] if _condition(x, state)]
    if blocked:
        return {"decision":"WAIT","reason":"BLOCKED","matched":[],"blocked":blocked}
    call = [x for x in strategy["entry_call"] if _condition(x, state)]
    put = [x for x in strategy["entry_put"] if _condition(x, state)]
    if call and not put:
        decision = "CALL BUY"
        matched = call
    elif put and not call:
        decision = "PUT BUY"
        matched = put
    else:
        decision = "WAIT" if call or put else "NO QUALIFYING TRADE"
        matched = call + put
    return {"decision":decision,"reason":"RULE_MATCH" if matched else "NO_RULE_MATCH",
            "matched":matched,"blocked":[]}

def make_trade(decision: str, state: dict, strategy: dict) -> dict | None:
    if decision not in {"CALL BUY","PUT BUY"}:
        return None
    entry = _num(state.get("entry", state.get("price")))
    if entry is None or entry <= 0:
        return None
    sl = _num(state.get("sl"))
    target = _num(state.get("target"))
    if sl is None:
        swing = _num(state.get("swing_low" if decision == "CALL BUY" else "swing_high"))
        sl = swing
    if target is None:
        r = abs(entry - sl) if sl is not None else 0
        target = entry + 2*r if decision == "CALL BUY" else entry - 2*r
    if sl is None or target is None:
        return None
    return {"side":decision, "entry":entry, "sl":sl, "target":target,
            "timestamp":state.get("timestamp",state.get("ts"))}

@dataclass
class BacktestResult:
    trades: list[dict]
    equity_curve: list[float]
    metrics: dict

def _trade_pnl(t: dict, exit_price: float) -> float:
    sign = 1 if t["side"] == "CALL BUY" else -1
    return sign * (exit_price - t["entry"])

def run_backtest(strategy: dict, bars: list[dict], brokerage: float = 0.0,
                 slippage: float = 0.0) -> BacktestResult:
    validate_strategy(strategy)
    trades, equity, open_trade = [], [0.0], None
    for i in range(len(bars) - 1):
        bar = bars[i]
        if open_trade:
            hi, lo = _num(bar.get("high")), _num(bar.get("low"))
            if hi is None or lo is None:
                continue
            side = open_trade["side"]
            hit_sl = lo <= open_trade["sl"] if side == "CALL BUY" else hi >= open_trade["sl"]
            hit_tg = hi >= open_trade["target"] if side == "CALL BUY" else lo <= open_trade["target"]
            if hit_sl or hit_tg:
                # Conservative rule: when both hit in one candle, SL wins.
                exit_price = open_trade["sl"] if hit_sl else open_trade["target"]
                pnl = _trade_pnl(open_trade, exit_price) - brokerage - slippage
                closed = {**open_trade, "exit":exit_price, "pnl":round(pnl,6),
                          "exit_index":i, "exit_reason":"SL" if hit_sl else "TARGET"}
                trades.append(closed); equity.append(equity[-1] + pnl); open_trade = None
            continue
        state = {**bar, "data_fresh":True}
        result = evaluate_strategy(strategy, state)
        if result["decision"] in {"CALL BUY","PUT BUY"}:
            # Entry is next candle open: no look-ahead.
            nxt = bars[i+1]
            entry = _num(nxt.get("open"))
            if entry is None or entry <= 0:
                continue
            trade_state = {**state, "entry":entry}
            trade = make_trade(result["decision"], trade_state, strategy)
            if trade:
                open_trade = {**trade, "entry_index":i+1, "matched":result["matched"]}
    if open_trade:
        last = _num(bars[-1].get("close"))
        if last is not None:
            pnl = _trade_pnl(open_trade,last) - brokerage - slippage
            trades.append({**open_trade,"exit":last,"pnl":round(pnl,6),
                           "exit_index":len(bars)-1,"exit_reason":"END"})
            equity.append(equity[-1] + pnl)
    wins = [t for t in trades if t["pnl"] > 0]
    losses = [t for t in trades if t["pnl"] < 0]
    gross_profit = sum(t["pnl"] for t in wins)
    gross_loss = abs(sum(t["pnl"] for t in losses))
    peak = 0.0; max_dd = 0.0
    for x in equity:
        peak = max(peak, x); max_dd = max(max_dd, peak-x)
    metrics = {
        "trades":len(trades), "wins":len(wins), "losses":len(losses),
        "win_rate":round(len(wins)/len(trades),4) if trades else 0.0,
        "profit_factor":round(gross_profit/gross_loss,4) if gross_loss else (float("inf") if gross_profit else 0.0),
        "max_drawdown":round(max_dd,6),
        "expectancy":round(statistics.mean([t["pnl"] for t in trades]),6) if trades else 0.0,
        "net_pnl":round(sum(t["pnl"] for t in trades),6),
    }
    return BacktestResult(trades=trades,equity_curve=equity,metrics=metrics)

def approve_test(metrics: dict, min_trades: int = 100, min_profit_factor: float = 1.5,
                 max_drawdown: float = 0.0) -> dict:
    trades = int(metrics.get("trades",0))
    pf = float(metrics.get("profit_factor",0) or 0)
    dd = float(metrics.get("max_drawdown",0) or 0)
    ok = trades >= min_trades and pf > min_profit_factor and (max_drawdown <= 0 or dd <= max_drawdown)
    return {"approved":ok,"checks":{"min_trades":trades>=min_trades,
            "profit_factor":pf>min_profit_factor,
            "drawdown":max_drawdown<=0 or dd<=max_drawdown},
            "past_performance_only":True}
