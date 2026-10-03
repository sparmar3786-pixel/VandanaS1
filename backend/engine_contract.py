"""Stable live-data contract for the NSE Algo terminal.

This module is the single normalization layer used by Dashboard, Strategy Refresh
and AI context. It never fabricates a market value.
"""
from __future__ import annotations
import time
from typing import Any

UNAVAILABLE = "DATA UNAVAILABLE"


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _fresh_snapshot(client, symbol):
    if getattr(client, "api", None) is None:
        return None
    try:
        if str(symbol).upper() == str(getattr(client, "chain_symbol", symbol)).upper():
            cached = getattr(client, "last_snapshot", None)
            cached_ts = float(cached.get("ts", 0)) if isinstance(cached, dict) else 0.0
            if isinstance(cached, dict) and cached_ts > 0 and time.time() - cached_ts <= 8:
                return cached
            return client.snapshot()
        rows = client.option_chain_rows(symbol=symbol, count=15)
        opts = {}
        for r in rows.get("rows", []):
            if r.get("strike") is None or not r.get("type"):
                continue
            key = (float(r["strike"]), str(r["type"]).upper())
            opts[key] = {
                "ltp": r.get("ltp"),
                "oi": r.get("oi"),
                "vol": r.get("volume"),
                "symbol": r.get("symbol"),
                "token": r.get("token"),
                "oi_change": r.get("oiChange"),
                "ltp_change": r.get("priceChange", r.get("netChange")),
            }
        return {
            "ts": time.time(), "symbol": rows.get("symbol", symbol),
            "spot": rows.get("spot"), "atm": rows.get("atm"),
            "expiry": rows.get("expiry"), "opts": opts,
        }
    except Exception:
        return None


def _active_option(snap, last):
    if not isinstance(snap, dict) or not isinstance(last, dict):
        return None, None
    side = str(last.get("type") or "").upper()
    strike = _num(last.get("strike"))
    if side not in {"CE", "PE"} or strike is None:
        return None, None
    opts = snap.get("opts") or {}
    item = opts.get((strike, side))
    return item if isinstance(item, dict) else None, side


def engine_state(client, eng, symbol):
    last = eng.last if isinstance(eng.last, dict) else {}
    nse = eng.nse_view if isinstance(eng.nse_view, dict) else {}
    snap = _fresh_snapshot(client, symbol)
    if snap is None:
        return {
            "available": False,
            "status": "DATA UNAVAILABLE",
            "symbol": str(symbol).upper(),
            "index_ltp": UNAVAILABLE,
            "ce_pe": UNAVAILABLE,
            "strike": UNAVAILABLE,
            "option_ltp": UNAVAILABLE,
            "oi": UNAVAILABLE,
            "oi_change": UNAVAILABLE,
            "volume": UNAVAILABLE,
            "atm": UNAVAILABLE,
            "trend": nse.get("trend", UNAVAILABLE),
            "signal_status": last.get("action", "WAIT"),
            "source": "Angel One SmartAPI",
        }

    opt, side = _active_option(snap, last)
    action = str(last.get("action") or "WAIT")
    active = side is not None and action not in {"WAIT", "NO QUALIFYING TRADE"}
    if not active:
        opt, side = None, None

    def val(key):
        return opt.get(key) if opt and opt.get(key) is not None else UNAVAILABLE

    return {
        "available": True,
        "status": action,
        "symbol": snap.get("symbol") or symbol,
        "index_ltp": snap.get("spot") if snap.get("spot") is not None else UNAVAILABLE,
        "ce_pe": side or UNAVAILABLE,
        "strike": last.get("strike") if active else UNAVAILABLE,
        "option_ltp": val("ltp"),
        "oi": val("oi"),
        "oi_change": val("oi_change"),
        "volume": val("vol"),
        "atm": snap.get("atm") if snap.get("atm") is not None else UNAVAILABLE,
        "trend": nse.get("trend", UNAVAILABLE),
        "signal_status": action,
        "option_symbol": val("symbol"),
        "entry": last.get("entry", UNAVAILABLE),
        "stop_loss": last.get("sl", UNAVAILABLE),
        "target": last.get("target", UNAVAILABLE),
        "score": last.get("score", UNAVAILABLE),
        "timestamp": snap.get("ts", time.time()),
        "source": "Angel One SmartAPI",
    }


def strategy_state(client, eng, symbol):
    last = eng.last if isinstance(eng.last, dict) else {}
    nse = eng.nse_view if isinstance(eng.nse_view, dict) else {}
    snap = _fresh_snapshot(client, symbol)
    base = {
        "timestamp": time.time(),
        "index": str(symbol).upper(),
        "action": last.get("action", "WAIT"),
        "current_engine_state": engine_state(client, eng, symbol),
        "trend": nse.get("trend", UNAVAILABLE),
        "support": nse.get("support", UNAVAILABLE),
        "resistance": nse.get("resistance", UNAVAILABLE),
        "pcr": nse.get("pcr", UNAVAILABLE),
        "max_pain": nse.get("max_pain", UNAVAILABLE),
        "highest_ce_oi": [],
        "highest_pe_oi": [],
        "call_writer_pressure": [],
        "put_writer_pressure": [],
        "buildup_counts": {
            "LONG_BUILDUP": 0, "SHORT_BUILDUP": 0,
            "SHORT_COVERING": 0, "LONG_UNWINDING": 0,
        },
        "oi_change": [],
        "premium_change": [],
        "what_is_changing": [],
        "reasons": last.get("reasons", []),
        "sources": {
            "angel_api": bool(getattr(client, "api", None)),
            "nse_engine": bool(nse),
            "official_nse_mcp": "server-side MCP adapter",
            "internet": "AI web-search layer",
        },
    }
    if snap is None:
        base["available"] = False
        base["error"] = UNAVAILABLE
        return base

    rows = []
    for key, value in (snap.get("opts") or {}).items():
        try:
            strike, side = key
        except Exception:
            continue
        if not isinstance(value, dict):
            continue
        row = {
            "strike": strike, "type": side,
            "ltp": value.get("ltp", UNAVAILABLE),
            "oi": value.get("oi", UNAVAILABLE),
            "volume": value.get("vol", UNAVAILABLE),
            "oi_change": value.get("oi_change", UNAVAILABLE),
            "premium_change": value.get("ltp_change", UNAVAILABLE),
            "symbol": value.get("symbol", UNAVAILABLE),
        }
        rows.append(row)

    ce = sorted([r for r in rows if r["type"] == "CE"],
                key=lambda r: float(r["oi"]) if _num(r["oi"]) is not None else -1, reverse=True)
    pe = sorted([r for r in rows if r["type"] == "PE"],
                key=lambda r: float(r["oi"]) if _num(r["oi"]) is not None else -1, reverse=True)
    base["available"] = True
    base["spot"] = snap.get("spot", UNAVAILABLE)
    base["atm"] = snap.get("atm", UNAVAILABLE)
    base["highest_ce_oi"] = ce[:5]
    base["highest_pe_oi"] = pe[:5]

    ce_total = sum(float(r["oi"]) for r in ce if _num(r["oi"]) is not None)
    pe_total = sum(float(r["oi"]) for r in pe if _num(r["oi"]) is not None)
    base["ce_total_oi"] = ce_total
    base["pe_total_oi"] = pe_total
    if ce_total > 0:
        base["pcr"] = round(pe_total / ce_total, 4)

    writer_ce = []
    writer_pe = []
    for r in rows:
        doi, dp = _num(r["oi_change"]), _num(r["premium_change"])
        if doi is None or dp is None:
            continue
        base["oi_change"].append({"strike": r["strike"], "type": r["type"], "change": doi})
        base["premium_change"].append({"strike": r["strike"], "type": r["type"], "change": dp})
        if dp > 0 and doi > 0:
            cls = "LONG_BUILDUP"
        elif dp > 0 and doi < 0:
            cls = "SHORT_COVERING"
        elif dp < 0 and doi > 0:
            cls = "SHORT_BUILDUP"
        elif dp < 0 and doi < 0:
            cls = "LONG_UNWINDING"
        else:
            continue
        base["buildup_counts"][cls] += 1
        base["what_is_changing"].append({
            "strike": r["strike"], "type": r["type"],
            "classification": cls, "premium_change": dp, "oi_change": doi,
        })
        if dp < 0 and doi > 0:
            (writer_ce if r["type"] == "CE" else writer_pe).append(r)

    writer_ce.sort(key=lambda r: abs(float(r["oi_change"])), reverse=True)
    writer_pe.sort(key=lambda r: abs(float(r["oi_change"])), reverse=True)
    base["call_writer_pressure"] = writer_ce[:5]
    base["put_writer_pressure"] = writer_pe[:5]
    if writer_ce:
        base["call_seller_pressure"] = "Potential CE writing pressure from premium↓ + OI↑"
    elif ce:
        base["call_seller_pressure"] = "High CE OI concentration; seller intent not proven"
    else:
        base["call_seller_pressure"] = UNAVAILABLE
    if writer_pe:
        base["put_seller_pressure"] = "Potential PE writing pressure from premium↓ + OI↑"
    elif pe:
        base["put_seller_pressure"] = "High PE OI concentration; seller intent not proven"
    else:
        base["put_seller_pressure"] = UNAVAILABLE

    base["what_is_changing"] = base["what_is_changing"][:20]
    return base
