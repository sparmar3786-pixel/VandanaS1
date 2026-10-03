"""Read-only ENTRY/EXIT alert event service for QUALIFIED council signals.

Paper/analysis alerts only. No order placement.
Uses the existing council deterministic engine and shared market_core snapshot.
"""
from __future__ import annotations

import asyncio
import time
from collections import deque
from datetime import datetime
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Header, HTTPException
import config as C
from market_core import snapshot

router = APIRouter(tags=["alerts"])
IST = ZoneInfo("Asia/Kolkata")
EVENTS = deque(maxlen=200)
ACTIVE: dict[str, dict] = {}
COOLDOWN: dict[str, float] = {}
COOLDOWN_SEC = 15 * 60
POLL_SEC = 15
SEQ = 0


def _direction(sig: dict) -> str:
    side = str(sig.get("side") or sig.get("direction") or "").upper()
    return "CALL" if "CALL" in side else "PUT" if "PUT" in side else side


def _type(sig: dict) -> str:
    return "CE" if _direction(sig) == "CALL" else "PE"


def sid(sig: dict) -> str:
    return f"{sig.get('index')}|{_direction(sig)}|{int(float(sig.get('strike') or 0))}"


def _normalise(sig: dict) -> dict:
    out = dict(sig)
    out["direction"] = _direction(sig)
    out["type"] = _type(sig)
    out["ai_take"] = int(sig.get("ai_take", sig.get("take", 0)) or 0)
    return out


def emit(kind: str, sig: dict, reason: str, ltp=None):
    global SEQ
    SEQ += 1
    sig = _normalise(sig)
    name = f"{sig['index']} {sig['direction']} {int(float(sig['strike']))}{sig['type']}"
    if kind == "ENTRY":
        title = f"ENTRY {name}"
        body = f"Entry {sig.get('entry')} | SL {sig.get('sl')} | Target {sig.get('target')} | AI {sig['ai_take']}/6"
    else:
        title = f"EXIT {name}"
        body = f"{reason} | LTP {ltp} | Entry {sig.get('entry')}"
    EVENTS.append({
        "seq": SEQ, "kind": kind, "title": title, "body": body, "ts": time.time(),
        "signal": {k: sig.get(k) for k in ("index", "direction", "strike", "type", "entry", "sl", "target")},
    })


def _current_ltp(sig: dict):
    snap = snapshot(sig["index"], True)
    if not snap:
        return None
    strike = float(sig["strike"])
    typ = _type(sig)
    row = next((r for r in snap.get("rows", []) if float(r.get("strike", -1)) == strike and r.get("type") == typ), None)
    if not row or row.get("stale") or row.get("ltp") is None:
        return None
    return float(row["ltp"])


def exit_reason(sig: dict, qualified: dict, now: datetime):
    if (now.hour, now.minute) >= (15, 15):
        return "Time exit 15:15", None

    direction = _direction(sig)
    for q in qualified.values():
        if q.get("index") == sig.get("index") and _direction(q) != direction:
            return "Opposite-side signal", None

    ltp = _current_ltp(sig)
    if ltp is None:
        return None, None

    sl = sig.get("sl")
    target = sig.get("target")
    if sl is not None and ((direction == "CALL" and ltp <= float(sl)) or
                           (direction == "PUT" and ltp >= float(sl))):
        return "Stop-loss hit", ltp
    if target is not None and ((direction == "CALL" and ltp >= float(target)) or
                               (direction == "PUT" and ltp <= float(target))):
        return "Target hit", ltp
    return None, None


def market_open(now: datetime) -> bool:
    return now.weekday() < 5 and (9, 15) <= (now.hour, now.minute) <= (15, 30)


def _qualified_all():
    # Reuse council's 30-second aggregate cache; no fresh AI round every 15 seconds.
    from council import get_all_cached
    return get_all_cached().get("qualified", [])


async def alert_loop():
    while True:
        try:
            now = datetime.now(IST)
            if market_open(now):
                qualified_list = await asyncio.to_thread(_qualified_all)
                qualified = {sid(s): _normalise(s) for s in qualified_list}

                # Exits are evaluated before new entries.
                for k, sig in list(ACTIVE.items()):
                    reason, ltp = exit_reason(sig, qualified, now)
                    if reason:
                        emit("EXIT", sig, reason, ltp)
                        ACTIVE.pop(k, None)
                        COOLDOWN[k] = time.time()

                for k, sig in qualified.items():
                    if k in ACTIVE or time.time() - COOLDOWN.get(k, 0) < COOLDOWN_SEC:
                        continue
                    if any(a.get("index") == sig.get("index") for a in ACTIVE.values()):
                        continue
                    ACTIVE[k] = sig
                    emit("ENTRY", sig, "qualified")
            elif ACTIVE:
                for k, sig in list(ACTIVE.items()):
                    emit("EXIT", sig, "Market closed")
                    ACTIVE.pop(k, None)
        except Exception as exc:
            print("alert_loop error:", repr(exc)[:300])
        await asyncio.sleep(POLL_SEC)


def _auth(x_token: Optional[str]):
    if x_token != C.API_TOKEN:
        raise HTTPException(401, "bad token")


@router.get("/api/alerts")
def alerts(since: Optional[int] = None, x_token: Optional[str] = Header(None)):
    _auth(x_token)
    if since is None:
        return {"seq": SEQ, "events": []}
    return {"seq": SEQ, "events": [e for e in EVENTS if e["seq"] > since]}


@router.get("/api/alerts/active")
def active(x_token: Optional[str] = Header(None)):
    _auth(x_token)
    return list(ACTIVE.values())
