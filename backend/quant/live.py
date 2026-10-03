"""Live quant evidence adapter.

Consumes only the existing server-side market/option payload and feeds deterministic
quantitative evidence into the six-AI orchestrator. It never calls an AI provider.
"""
from __future__ import annotations
import math
from datetime import datetime, timezone
from typing import Any
from quant.option_math import (
    atr, bollinger, bs_greeks, ema, implied_vol, macd, probability_of_profit, realized_vol,
    returns_from_prices, rsi, vwap,
)

def _num(v: Any):
    try:
        if v is None or v == "": return None
        x=float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError): return None

def _find_first(obj: Any, names: tuple[str,...]):
    if isinstance(obj,dict):
        for name in names:
            if obj.get(name) is not None: return obj.get(name)
        for value in obj.values():
            found=_find_first(value,names)
            if found is not None:return found
    elif isinstance(obj,list):
        for value in obj:
            found=_find_first(value,names)
            if found is not None:return found
    return None

def _years_to_expiry(value: Any) -> float:
    if not value: return 0.0
    text=str(value).strip()
    for fmt in ("%Y-%m-%d","%d-%b-%Y","%d-%B-%Y","%d/%m/%Y"):
        try:
            d=datetime.strptime(text,fmt).replace(tzinfo=timezone.utc)
            return max((d-datetime.now(timezone.utc)).total_seconds()/31557600.0,0.0)
        except ValueError: pass
    return 0.0

def _rows(payload: dict) -> list[dict]:
    candidates=[
        payload.get("option_chain"),
        (payload.get("terminal") or {}).get("option_chain") if isinstance(payload.get("terminal"),dict) else None,
        ((payload.get("three_sources") or {}).get("angel_api") or {}).get("option_chain")
        if isinstance(payload.get("three_sources"),dict) else None,
    ]
    for value in candidates:
        if isinstance(value,list):
            return [dict(x) for x in value if isinstance(x,dict)]
    return []

def build_quant_evidence(payload: dict) -> dict:
    payload=dict(payload or {})
    terminal=payload.get("terminal") if isinstance(payload.get("terminal"),dict) else {}
    market=payload.get("market_evidence") if isinstance(payload.get("market_evidence"),dict) else {}
    data=payload.get("data_layer") if isinstance(payload.get("data_layer"),dict) else {}
    spot=_num(market.get("spot")) or _num((terminal.get("market") or {}).get("spot"))
    indicators=dict(data.get("indicators") or {})
    latest=data.get("latest") if isinstance(data.get("latest"),dict) else {}
    close=_num(latest.get("close")) or spot

    # Existing AI-read indicators are preserved and supplemented with deterministic primitives.
    closes=[_num(x) for x in (data.get("close_series") or [])]
    closes=[x for x in closes if x is not None]
    highs=[_num(x) for x in (data.get("high_series") or [])]
    lows=[_num(x) for x in (data.get("low_series") or [])]
    vols=[_num(x) for x in (data.get("volume_series") or [])]
    q={
        "available": bool(spot or close or indicators),
        "source":"server-side deterministic quant layer",
        "spot":spot,
        "latest_close":close,
        "indicators":indicators,
        "computed":{},
        "option_math":[],
        "warnings":[],
    }

    if closes:
        q["computed"]["ema_8"]=ema(closes,8)
        q["computed"]["ema_13"]=ema(closes,13)
        q["computed"]["rsi_14"]=rsi(closes,14)
        q["computed"]["macd"]=macd(closes)
        q["computed"]["bollinger"]=bollinger(closes)
        q["computed"]["realized_vol"]=realized_vol(returns_from_prices(closes),20)
        if vols and len(vols)==len(closes): q["computed"]["vwap"]=vwap(closes,vols)
    if highs and lows and closes and len(highs)==len(lows)==len(closes):
        q["computed"]["atr_14"]=atr(highs,lows,closes,14)

    expiry=_find_first(payload,("expiry","expiryDate","expiry_date"))
    T=_years_to_expiry(expiry)
    rate=_num(_find_first(payload,("risk_free_rate","riskFreeRate","r"))) or 0.0
    rows=_rows(payload)
    for row in rows[:24]:
        S=spot; K=_num(row.get("strike")); price=_num(row.get("ltp") or row.get("lastPrice") or row.get("optionLtp"))
        side=str(row.get("type") or row.get("optionType") or "").upper()
        if not (S and K and price and side in {"CE","PE"}): continue
        iv=_num(row.get("iv") or row.get("impliedVolatility"))
        if iv is None and T>0: iv=implied_vol(price,S,K,T,rate,side)
        greeks=bs_greeks(S,K,T,rate,iv,side) if iv is not None and T>0 else None
        item={"strike":K,"type":side,"ltp":price,"iv":iv,"time_to_expiry_years":T,"greeks":greeks}
        if greeks is not None:
            item["pop_proxy"]=round(float(probability_of_profit(S,K,T,rate,iv,side)),6)
        q["option_math"].append(item)

    if not q["computed"] and not q["option_math"]:
        q["warnings"].append("Insufficient live series/option inputs for additional quant calculations.")
    q["timestamp"]=payload.get("ts") or terminal.get("ts")
    return q
