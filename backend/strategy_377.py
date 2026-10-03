"""Deterministic Strategy 377 adapter for the live Indian-index terminal.
The strategy uses only allow-listed condition blocks from strategy_engine.
No order placement is performed.
"""
from __future__ import annotations

import time

from strategy_engine import evaluate_strategy

STRATEGY_377 = {
    "id": "strategy_377",
    "name": "Strategy 377",
    "index": "NIFTY",
    "tf": "5m",
    "entry_call": [
        "trend_up",
        "pcr>1",
        "long_buildup",
        "support_hold",
        "option_liquid",
    ],
    "entry_put": [
        "trend_down",
        "pcr<1",
        "short_buildup",
        "resistance_reject",
        "option_liquid",
    ],
    "block_if": [
        "short_covering",
        "long_unwinding",
    ],
    "sl": "swing_low",
    "target": "2R",
    "time_filter": "09:30-14:45",
    "version": "377.1",
}

def _num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def build_live_state(strategy_state: dict) -> dict:
    state = strategy_state if isinstance(strategy_state, dict) else {}
    current = state.get("current_engine_state") if isinstance(state.get("current_engine_state"), dict) else {}
    trend = str(state.get("trend") or "").upper()
    spot = _num(state.get("spot") or current.get("index_ltp"))
    support = _num(state.get("support"))
    resistance = _num(state.get("resistance"))
    rows = list(state.get("highest_ce_oi") or []) + list(state.get("highest_pe_oi") or [])
    changing = state.get("what_is_changing") if isinstance(state.get("what_is_changing"), list) else []
    now = time.time()
    ts = _num(state.get("timestamp") or current.get("timestamp"))
    fresh = ts is not None and abs(now - ts) <= 45
    max_volume = max(
        (_num(r.get("volume")) or 0 for r in rows if isinstance(r, dict)),
        default=0,
    )
    classifications = {
        str(item.get("classification") or "").upper()
        for item in changing
        if isinstance(item, dict)
    }

    return {
        "timestamp": ts or now,
        "data_fresh": fresh,
        "price": spot,
        "pcr": state.get("pcr"),
        "trend_up": "UP" in trend,
        "trend_down": "DOWN" in trend,
        "long_buildup": "LONG_BUILDUP" in classifications,
        "short_buildup": "SHORT_BUILDUP" in classifications,
        "short_covering": "SHORT_COVERING" in classifications,
        "long_unwinding": "LONG_UNWINDING" in classifications,
        "support_hold": spot is not None and support is not None and spot >= support and ((spot - support) / max(spot, 1)) <= 0.005,
        "resistance_reject": spot is not None and resistance is not None and resistance >= spot and ((resistance - spot) / max(spot, 1)) <= 0.005,
        "option_liquid": max_volume > 0,
        "swing_low": support,
        "swing_high": resistance,
        "entry": _num(current.get("entry")) or _num(current.get("option_ltp")),
        "sl": _num(current.get("stop_loss")),
    }

def evaluate_live(strategy_state: dict) -> dict:
    live_state = build_live_state(strategy_state)
    evaluated = evaluate_strategy(STRATEGY_377, live_state)
    return {
        "strategy": STRATEGY_377,
        "state": live_state,
        "evaluation": evaluated,
        "paper_only": True,
        "timestamp": time.time(),
    }
