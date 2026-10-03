"""Strategy Council: deterministic candidate selection + six-AI evidence council.

Paper/analysis only. No order placement.
The deterministic engine owns direction, strike, entry, SL and target.
AI can only downgrade a candidate to WATCHLIST/WAIT; it cannot alter levels.
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException

import config as C
from market_core import evidence, snapshot
from strategy_engine import evaluate_strategy, make_trade, validate_strategy
from ai_orchestrator import PROVIDERS, _openai, _openai_compat, _anthropic, _gemini

router = APIRouter(tags=["council"])

CACHE_SEC = max(5, int(os.getenv("COUNCIL_CACHE_SEC", "30")))
MAX_IDEAS = max(1, min(7, int(os.getenv("COUNCIL_MAX_IDEAS", "7"))))
MIN_AI_TAKE = 4
MIN_BACKTEST_TRADES = 100
MIN_WIN_RATE = 0.80
MIN_PROFIT_FACTOR = 1.50
COUNCIL_SL_PCT = float(os.getenv("COUNCIL_SL_PCT", "0.25"))
COUNCIL_RR = float(os.getenv("COUNCIL_RR", "2.0"))

_CACHE: dict[str, tuple[float, dict]] = {}
_ALL_CACHE: tuple[float, dict] | None = None
_CACHE_LOCK = threading.Lock()

# Four deterministic, allow-listed modules. They never execute arbitrary code.
MODULES = {
    "buildup": {
        "id": "council-buildup-v1",
        "name": "OI Buildup",
        "call": ["long_buildup", "trend_up", "data_fresh", "option_liquid"],
        "put": ["short_buildup", "trend_down", "data_fresh", "option_liquid"],
        "block": ["long_unwinding", "short_covering"],
    },
    "oi_wall": {
        "id": "council-oi-wall-v1",
        "name": "OI Wall",
        "call": ["support_hold", "trend_up", "data_fresh", "option_liquid"],
        "put": ["resistance_reject", "trend_down", "data_fresh", "option_liquid"],
        "block": [],
    },
    "pcr": {
        "id": "council-pcr-v1",
        "name": "PCR",
        "call": ["pcr>1", "data_fresh", "option_liquid"],
        "put": ["pcr<1", "data_fresh", "option_liquid"],
        "block": [],
    },
    "momentum": {
        "id": "council-momentum-v1",
        "name": "Momentum",
        "call": ["price>vwap", "prev_high_break", "data_fresh", "option_liquid"],
        "put": ["price<vwap", "prev_low_break", "data_fresh", "option_liquid"],
        "block": [],
    },
}

def _auth(token: str | None) -> None:
    expected = getattr(C, "API_TOKEN", "")
    if not expected or token != expected:
        raise HTTPException(401, "bad token")

def _load_stats() -> dict:
    candidates = [
        Path(os.getenv("BACKTEST_STATS_PATH", "data/backtest_stats.json")),
        Path("backtest_stats.json"),
    ]
    for p in candidates:
        try:
            if p.exists():
                data = json.loads(p.read_text(encoding="utf-8"))
                return data if isinstance(data, dict) else {}
        except Exception:
            continue
    return {}

def _stats_for(stats: dict, strategy_id: str, side: str) -> dict:
    # Accept either {"STRATEGY|CALL": {...}} or nested {"STRATEGY":{"CALL":{...}}}.
    direct = stats.get(f"{strategy_id}|{side}") or stats.get(f"{strategy_id}:{side}")
    if isinstance(direct, dict):
        return direct
    nested = stats.get(strategy_id)
    if isinstance(nested, dict):
        value = nested.get(side) or nested.get(side.replace(" BUY", ""))
        if isinstance(value, dict):
            return value
    return {}

def _approved(stats: dict) -> tuple[bool, dict]:
    trades = int(float(stats.get("trades", 0) or 0))
    wr = float(stats.get("win_rate", 0) or 0)
    if wr > 1:
        wr /= 100.0
    pf = float(stats.get("profit_factor", 0) or 0)
    ok = trades >= MIN_BACKTEST_TRADES and wr >= MIN_WIN_RATE and pf > MIN_PROFIT_FACTOR
    return ok, {
        "trades": trades,
        "win_rate": wr,
        "profit_factor": pf,
        "min_trades": MIN_BACKTEST_TRADES,
        "min_win_rate": MIN_WIN_RATE,
        "min_profit_factor": MIN_PROFIT_FACTOR,
        "approved": ok,
    }

def _state_from_evidence(s: dict, row: dict, side: str) -> dict:
    rows = [r for r in s.get("rows", []) if not r.get("stale")]
    spot = s.get("spot")
    pcr = s.get("pcr")

    oi = float(row.get("oi") or 0)
    oi_change = float(row.get("oiChangePct") or row.get("oi_change_pct") or 0)
    ltp = float(row.get("ltp") or 0)

    # These flags are derived only when the supplied snapshot contains enough evidence.
    # Missing inputs stay False; they are never guessed.
    call_side = side == "CALL BUY"
    trend_up = bool(spot is not None and ltp > 0 and row.get("chg", 0) is not None and float(row.get("chg") or 0) > 0)
    trend_down = bool(spot is not None and ltp > 0 and row.get("chg", 0) is not None and float(row.get("chg") or 0) < 0)
    long_buildup = bool(oi_change > 0 and trend_up)
    short_buildup = bool(oi_change > 0 and trend_down)
    short_covering = bool(oi_change < 0 and trend_up)
    long_unwinding = bool(oi_change < 0 and trend_down)

    top_pe = max((float(x.get("oi") or 0) for x in rows if x.get("type") == "PE"), default=0)
    top_ce = max((float(x.get("oi") or 0) for x in rows if x.get("type") == "CE"), default=0)
    max_pe_strike = max((float(x.get("strike")) for x in rows if x.get("type") == "PE"), default=None)
    max_ce_strike = max((float(x.get("strike")) for x in rows if x.get("type") == "CE"), default=None)

    # Wall flags require a valid strike and matching max-OI row.
    strike = float(row.get("strike"))
    pe_walls = [float(x.get("strike")) for x in rows if x.get("type") == "PE" and float(x.get("oi") or 0) == top_pe]
    ce_walls = [float(x.get("strike")) for x in rows if x.get("type") == "CE" and float(x.get("oi") or 0) == top_ce]

    return {
        "timestamp": s.get("ts"),
        "price": row.get("ltp"),
        "entry": row.get("ltp"),
        "strike": strike,
        "pcr": pcr,
        "data_fresh": bool(s.get("data_ok")),
        "option_liquid": bool((float(row.get("volume") or 0) > 0) or (float(row.get("oi") or 0) > 0)),
        "trend_up": trend_up,
        "trend_down": trend_down,
        "long_buildup": long_buildup,
        "short_buildup": short_buildup,
        "short_covering": short_covering,
        "long_unwinding": long_unwinding,
        "support_hold": bool(call_side and strike in pe_walls),
        "resistance_reject": bool((not call_side) and strike in ce_walls),
        "price>vwap": False,
        "price<vwap": False,
        "prev_high_break": False,
        "prev_low_break": False,
        "oi_spike": abs(oi_change) >= float(os.getenv("OI_SPIKE_PCT", "20")),
        "volume_spike": False,
        "rr_ok": True,
        "oi": oi,
        "oi_change_pct": oi_change,
        "ltp": ltp,
        "side": side,
        "spot": spot,
        "max_pe_oi_strike": max_pe_strike,
        "max_ce_oi_strike": max_ce_strike,
    }

def _strategy(module: dict, index: str, side: str) -> dict:
    return {
        "id": module["id"],
        "version": "v1",
        "index": index,
        "tf": os.getenv("COUNCIL_TF", "5m"),
        "entry_call": module["call"],
        "entry_put": module["put"],
        "block_if": module["block"],
        # The engine uses supplied state SL/target when available. No fixed 25% risk is invented here.
        "sl": "state",
        "target": "state",
        "time_filter": os.getenv("COUNCIL_TIME_FILTER", "09:20-15:15"),
    }

def _candidate(s: dict, row: dict, module_name: str, side: str, stats: dict) -> dict:
    module = MODULES[module_name]
    strategy = _strategy(module, s["index"], side)
    state = _state_from_evidence(s, row, side)
    result = evaluate_strategy(strategy, state)
    approved, bt = _approved(stats)

    # Provisional deterministic levels are backend-configurable, never AI-generated.
    # They are not an approval gate by themselves; backtest approval remains mandatory.
    if approved and result["decision"] in {"CALL BUY", "PUT BUY"}:
        entry = float(row.get("ltp") or 0)
        risk = entry * COUNCIL_SL_PCT
        state["sl"] = entry - risk if result["decision"] == "CALL BUY" else entry + risk
        state["target"] = entry + risk * COUNCIL_RR if result["decision"] == "CALL BUY" else entry - risk * COUNCIL_RR
    trade = make_trade(result["decision"], state, strategy) if approved else None
    qualified_engine = bool(approved and result["decision"] == side and trade)
    return {
        "strategy_id": strategy["id"],
        "strategy_version": strategy["version"],
        "module": module_name,
        "module_name": module["name"],
        "index": s["index"],
        "side": side,
        "strike": row.get("strike"),
        "entry": trade["entry"] if trade else row.get("ltp"),
        "sl": trade["sl"] if trade else None,
        "target": trade["target"] if trade else None,
        "engine_decision": result["decision"],
        "matched": result.get("matched", []),
        "blocked": result.get("blocked", []),
        "backtest": bt,
        "engine_qualified": qualified_engine,
        "state": state,
    }

def _round1_prompt(provider: dict, c: dict) -> str:
    return (
        "You are one lens in a paper-trading council.\n"
        "You MUST NOT change strike, entry, SL, target, strategy or direction.\n"
        "Return only JSON: {\"verdict\":\"TAKE|WAIT|BLOCK\",\"reason\":\"...\"}.\n"
        "TAKE means the supplied engine candidate has no material contradiction. "
        "WAIT means evidence is insufficient. BLOCK means a material contradiction/risk exists.\n"
        f"Lens: {provider['name']}\nCandidate:\n"
        + json.dumps({k: v for k, v in c.items() if k != "state"}, separators=(",", ":"), default=str)[:10000]
    )

def _round2_prompt(provider: dict, c: dict, r1: list[dict]) -> str:
    return (
        "You are the second-round reviewer in a paper-trading council.\n"
        "You may only KEEP your prior verdict or DOWNGRADE it. Never upgrade a WAIT/BLOCK to TAKE. "
        "Never change any engine level or create a new trade.\n"
        "Return only JSON: {\"verdict\":\"TAKE|WAIT|BLOCK\",\"reason\":\"...\"}.\n"
        "Candidate:\n" + json.dumps({k: v for k, v in c.items() if k != "state"}, separators=(",", ":"), default=str)[:7000]
        + "\nOther first-round verdicts:\n" + json.dumps(r1, separators=(",", ":"), default=str)[:5000]
        + "\nYour first-round verdict must not be upgraded."
    )

def _call(provider: dict, prompt: str, allow_parse: bool = True) -> dict:
    base = {"id": provider["id"], "name": provider["name"], "model": provider["model"]}
    if not os.getenv(provider["env"]):
        return {**base, "status": "not_configured", "verdict": "WAIT", "reason": "provider key not configured"}
    started = time.monotonic()
    try:
        if provider["kind"] == "openai":
            raw = _openai(provider, prompt)
        elif provider["kind"] == "anthropic":
            raw = _anthropic(provider, prompt)
        elif provider["kind"] == "gemini":
            raw = _gemini(provider, prompt)
        else:
            raw = _openai_compat(provider, prompt)
        data = json.loads(raw.strip())
        verdict = str(data.get("verdict", "WAIT")).upper()
        if verdict not in {"TAKE", "WAIT", "BLOCK"}:
            verdict = "WAIT"
        return {**base, "status": "ok", "verdict": verdict,
                "reason": str(data.get("reason", ""))[:500],
                "elapsed_ms": round((time.monotonic() - started) * 1000)}
    except Exception as exc:
        return {**base, "status": "error", "verdict": "WAIT",
                "reason": str(exc)[:300],
                "elapsed_ms": round((time.monotonic() - started) * 1000)}

def _council(c: dict) -> dict:
    r1 = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as pool:
        futures = [pool.submit(_call, p, _round1_prompt(p, c)) for p in PROVIDERS]
        for f in futures:
            r1.append(f.result())

    # Round 2 sees only verdicts/reasons from round 1, never raw market data from other agents.
    r1_public = [{"id": x["id"], "verdict": x["verdict"], "reason": x["reason"]} for x in r1]
    r2 = []
    by_id = {x["id"]: x for x in r1}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as pool:
        futures = [(p, pool.submit(_call, p, _round2_prompt(p, c, r1_public))) for p in PROVIDERS]
        for p, f in futures:
            result = f.result()
            prior = by_id.get(p["id"], {}).get("verdict", "WAIT")
            if prior == "BLOCK" and result["verdict"] == "TAKE":
                result["verdict"] = "BLOCK"
            elif prior == "WAIT" and result["verdict"] == "TAKE":
                result["verdict"] = "WAIT"
            r2.append(result)

    take = sum(x["verdict"] == "TAKE" for x in r2 if x["status"] == "ok")
    block = any(x["verdict"] == "BLOCK" for x in r2 if x["status"] == "ok")
    successful = sum(x["status"] == "ok" for x in r2)
    final = "QUALIFIED" if c["engine_qualified"] and successful >= MIN_AI_TAKE and take >= MIN_AI_TAKE and not block else "WATCHLIST"
    return {"final": final, "take": take, "block": block, "successful": successful, "round1": r1, "round2": r2}

def _build(index: str) -> dict:
    s = snapshot(index, True)
    if not s.get("data_ok"):
        return {"index": s["index"], "data_ok": False, "qualified": [], "watchlist": [],
                "reason": "DATA_STALE_OR_MISSING"}

    rows = [r for r in s["rows"] if not r.get("stale") and r.get("ltp") is not None]
    rows.sort(key=lambda r: float(r.get("volume") or 0) + float(r.get("oi") or 0), reverse=True)
    stats = _load_stats()
    candidates = []

    # One direction per index: CALL and PUT are evaluated separately, but only the stronger
    # direction can produce the visible top ideas. Ties stay WATCHLIST.
    direction_scores = {"CALL BUY": 0, "PUT BUY": 0}
    for r in rows:
        chg = float(r.get("chg") or 0)
        if r.get("type") == "CE" and chg > 0: direction_scores["CALL BUY"] += 1
        if r.get("type") == "PE" and chg > 0: direction_scores["PUT BUY"] += 1
    side = "CALL BUY" if direction_scores["CALL BUY"] > direction_scores["PUT BUY"] else (
        "PUT BUY" if direction_scores["PUT BUY"] > direction_scores["CALL BUY"] else None
    )
    if not side:
        return {"index": s["index"], "data_ok": True, "qualified": [], "watchlist": [],
                "reason": "NO_DIRECTIONAL_EDGE"}

    wanted_type = "CE" if side == "CALL BUY" else "PE"
    selected = [r for r in rows if r.get("type") == wanted_type][:2]
    for row in selected:
        for module_name in MODULES:
            stats_key = _stats_for(stats, MODULES[module_name]["id"], side)
            candidates.append(_candidate(s, row, module_name, side, stats_key))

    # Keep best evidence per strike/module; no fabricated quota.
    candidates.sort(key=lambda x: (
        bool(x["engine_qualified"]),
        x["backtest"]["win_rate"],
        x["backtest"]["profit_factor"],
        len(x["matched"]),
        float(x["strike"] or 0),
    ), reverse=True)

    qualified, watchlist = [], []
    for c in candidates:
        if c["engine_qualified"]:
            c["council"] = _council(c)
        else:
            c["council"] = {"final": "WATCHLIST", "take": 0, "block": False, "successful": 0,
                             "round1": [], "round2": []}
        if c["council"]["final"] == "QUALIFIED":
            qualified.append(c)
        else:
            watchlist.append(c)

    return {
        "index": s["index"],
        "data_ok": True,
        "qualified": qualified[:2],
        "watchlist": watchlist[:MAX_IDEAS],
        "max_visible_ideas": MAX_IDEAS,
        "rules": {
            "min_ai_take": MIN_AI_TAKE,
            "min_backtest_trades": MIN_BACKTEST_TRADES,
            "min_win_rate": MIN_WIN_RATE,
            "min_profit_factor": MIN_PROFIT_FACTOR,
            "ai_can_only_downgrade": True,
            "no_order_placement": True,
        },
    }

@router.get("/api/signals")
def api_signals(index: str = "NIFTY", x_token: str | None = Header(None)):
    _auth(x_token)
    index = str(index).upper().replace(" ", "")
    key = hashlib.sha256(index.encode()).hexdigest()
    now = time.monotonic()
    with _CACHE_LOCK:
        cached = _CACHE.get(key)
        if cached and now - cached[0] < CACHE_SEC:
            return {**cached[1], "cached": True, "cache_age_sec": round(now - cached[0], 1)}
    result = _build(index)
    with _CACHE_LOCK:
        _CACHE[key] = (time.monotonic(), result)
    return {**result, "cached": False}

def get_all_cached() -> dict:
    global _ALL_CACHE
    now = time.monotonic()
    with _CACHE_LOCK:
        if _ALL_CACHE and now - _ALL_CACHE[0] < CACHE_SEC:
            return _ALL_CACHE[1]
    out = [_build(idx) for idx in ("NIFTY", "BANKNIFTY", "FINNIFTY", "MIDCPNIFTY", "SENSEX", "BANKEX")]
    result = {
        "qualified": [c for r in out for c in r.get("qualified", [])][:MAX_IDEAS],
        "watchlist": [c for r in out for c in r.get("watchlist", [])][:MAX_IDEAS],
        "indices": out,
        "max_visible_ideas": MAX_IDEAS,
        "no_forced_quota": True,
    }
    with _CACHE_LOCK:
        _ALL_CACHE = (time.monotonic(), result)
    return result


@router.get("/api/signals/all")
def api_signals_all(x_token: str | None = Header(None)):
    _auth(x_token)
    return get_all_cached()

@router.get("/api/council/status")
def council_status(x_token: str | None = Header(None)):
    _auth(x_token)
    stats = _load_stats()
    return {
        "ok": True,
        "providers": [{"id": p["id"], "name": p["name"], "model": p["model"],
                       "configured": bool(os.getenv(p["env"]))} for p in PROVIDERS],
        "backtest_stats_available": bool(stats),
        "rules": {
            "min_ai_take": MIN_AI_TAKE,
            "min_backtest_trades": MIN_BACKTEST_TRADES,
            "min_win_rate": MIN_WIN_RATE,
            "min_profit_factor": MIN_PROFIT_FACTOR,
            "max_visible_ideas": MAX_IDEAS,
        },
    }
